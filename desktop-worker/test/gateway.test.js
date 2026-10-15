import {test} from 'node:test';
import assert from 'node:assert/strict';
import {webcrypto} from 'node:crypto';
import worker,{Quota} from '../src/index.js';
import {prompts,questionSets} from '../src/contracts.js';
globalThis.crypto ||= webcrypto;
const id='61ca257f-4431-4c42-a952-67a2aa8bdb11';
function environment() {
 const map=new Map();let queue=Promise.resolve();
 const storage={get:async k=>structuredClone(map.get(k)),put:async(k,v)=>map.set(k,structuredClone(v)),
  transaction:callback=>{const result=queue.then(()=>callback(storage));queue=result.catch(()=>{});return result;}};
 const env={SESSION_SECRET:'test-session-secret-not-a-provider-key',OPENAI_API_KEY:'test-openai',TYPESAFE_API_KEY:'test-jev',AI_DAILY_LIMIT:'4',JEV_DAILY_LIMIT:'12'};
 const quota=new Quota({storage},env);env.QUOTA={idFromName:n=>n,get:()=>({fetch:(url,options)=>quota.fetch(new Request(url,options))})};return env;
}
function request(path,body,token='',ip='127.0.0.1') {return new Request('https://gateway.test'+path,{method:'POST',
 headers:{'content-type':'application/json','x-crate-token':token,'cf-connecting-ip':ip},body:JSON.stringify(body)});}
async function session(env) {const r=await worker.fetch(request('/api/session',{installation_id:id}),env);assert.equal(r.status,200);return(await r.json()).token;}
function arrange() {return {model:'gpt-4.1-mini',input:'house piano at 124 BPM',instructions:'client instructions must not win',
 text:{format:{type:'json_schema',name:'arrangement',strict:true,schema:{malicious:true}}},max_output_tokens:999999,store:true};}
function upstream() {
 const original=globalThis.fetch;const calls=[];
 globalThis.fetch=async(url,options)=>{calls.push({url,options,body:JSON.parse(options.body)});return new Response('{"output":[]}',{status:200});};
 return {calls,restore:()=>globalThis.fetch=original};
}
test('health shows readiness without credentials',async()=>{const env=environment();const r=await worker.fetch(new Request('https://gateway.test/health'),env);const s=JSON.stringify(await r.json());assert(!s.includes(env.SESSION_SECRET));assert(!s.includes('test-openai'));});
test('no session blocks providers',async()=>assert.equal((await worker.fetch(request('/api/ai/openai',arrange()),environment())).status,401));
test('malformed installation is rejected',async()=>assert.equal((await worker.fetch(request('/api/session',{installation_id:'bad'}),environment())).status,400));
test('tampered session rejected',async()=>{const env=environment(),t=await session(env);assert.equal((await worker.fetch(request('/api/ai/openai',arrange(),t+'a'),env)).status,401);});
test('registration flood is limited',async()=>{const env=environment();for(let i=0;i<10;i++)assert.equal((await worker.fetch(request('/api/session',{installation_id:id}),env)).status,200);assert.equal((await worker.fetch(request('/api/session',{installation_id:id}),env)).status,429);});
test('gateway fixes model contract, token cap and storage',async()=>{const env=environment(),t=await session(env),fake=upstream();try{
 assert.equal((await worker.fetch(request('/api/ai/openai',arrange(),t),env)).status,200);
 assert.equal(fake.calls[0].url,'https://api.openai.com/v1/responses');const b=fake.calls[0].body;
 assert.equal(b.max_output_tokens,3000);assert.equal(b.store,false);assert.equal(b.instructions,prompts.arrangement.instructions);
 assert.deepEqual(b.text.format.schema,prompts.arrangement.schema);assert.equal(b.reasoning,undefined);
}finally{fake.restore();}});
test('expensive model rejected without calling provider',async()=>{const env=environment(),t=await session(env),fake=upstream();try{assert.equal((await worker.fetch(request('/api/ai/openai',{...arrange(),model:'gpt-6-sol'},t),env)).status,400);assert.equal(fake.calls.length,0);}finally{fake.restore();}});
test('large input rejected before provider spend',async()=>{const env=environment(),t=await session(env);assert.equal((await worker.fetch(request('/api/ai/openai',{...arrange(),input:'x'.repeat(21000)},t),env)).status,400);});
test('large request body rejected',async()=>{const env=environment(),t=await session(env);assert.equal((await worker.fetch(request('/api/ai/openai',{...arrange(),input:'x'.repeat(45000)},t),env)).status,413);});
test('concurrent gateway calls cannot exceed shared cap',async()=>{const env=environment(),t=await session(env),fake=upstream();try{
 const responses=await Promise.all(Array.from({length:10},()=>worker.fetch(request('/api/ai/openai',arrange(),t),env)));
 assert.equal(responses.filter(r=>r.status===200).length,4);assert.equal(fake.calls.length,4);
}finally{fake.restore();}});
test('unknown Jev question set rejected',async()=>{const env=environment(),t=await session(env);assert.equal((await worker.fetch(request('/api/ai/jev',{state:'house beat',questions:{bad:{}}},t),env)).status,400);});
test('Jev canonical questions proxied with server key',async()=>{const env=environment(),t=await session(env),fake=upstream();try{
 assert.equal((await worker.fetch(request('/api/ai/jev',{state:'house beat',questions:questionSets[0]},t),env)).status,200);
 assert.equal(fake.calls[0].url,'https://api.typesafe.ai/v1/systemone');assert.equal(fake.calls[0].body.model,'jev-latest');
 assert.equal(fake.calls[0].options.headers.Authorization,'Bearer test-jev');
}finally{fake.restore();}});
test('upstream error body is never exposed',async()=>{const env=environment(),t=await session(env),original=globalThis.fetch;globalThis.fetch=async()=>new Response('sensitive upstream diagnostic',{status:401});try{const r=await worker.fetch(request('/api/ai/openai',arrange(),t),env);assert.equal(r.status,502);assert(!(await r.text()).includes('sensitive'));}finally{globalThis.fetch=original;}});
