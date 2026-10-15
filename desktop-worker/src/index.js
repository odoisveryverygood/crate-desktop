import { prompts, questionSets } from "./contracts.js";
// Dedicated desktop gateway. Provider keys and signing secret exist only as Worker secrets.
const json = (status, body) => new Response(JSON.stringify(body), {status,
  headers: {'content-type':'application/json', 'cache-control':'no-store'}});
const enc = new TextEncoder();
const stable = v => Array.isArray(v) ? v.map(stable) : v && typeof v === 'object' ? Object.fromEntries(Object.keys(v).sort().map(k=>[k,stable(v[k])])) : v;
const b64 = bytes => btoa(String.fromCharCode(...new Uint8Array(bytes))).replaceAll('+','-').replaceAll('/','_').replaceAll('=','');
function unb64(s) { return Uint8Array.from(atob(s.replaceAll('-','+').replaceAll('_','/')), c=>c.charCodeAt(0)); }
async function key(secret) { return crypto.subtle.importKey('raw',enc.encode(secret),{name:'HMAC',hash:'SHA-256'},false,['sign','verify']); }
async function issue(id, secret) {
  const payload=b64(enc.encode(JSON.stringify({id,exp:Math.floor(Date.now()/1000)+30*86400})));
  return payload+'.'+b64(await crypto.subtle.sign('HMAC',await key(secret),enc.encode(payload)));
}
async function authenticate(token, secret) {
  try {
    const [payload,signature,...extra]=token.split('.');
    if(extra.length || !payload || !signature || token.length>1000) return null;
    if(!await crypto.subtle.verify('HMAC',await key(secret),unb64(signature),enc.encode(payload))) return null;
    const data=JSON.parse(new TextDecoder().decode(unb64(payload)));
    return /^[a-f0-9-]{36}$/i.test(data.id) && data.exp>Date.now()/1000 ? data.id : null;
  } catch { return null; }
}
async function body(req, max=40000) {
  if(Number(req.headers.get('content-length'))>max) throw new Error('size');
  const reader=req.body?.getReader();if(!reader) throw new Error('json');
  let size=0;const chunks=[];
  while(true) { const {done,value}=await reader.read();if(done)break;size+=value.length;
    if(size>max){await reader.cancel();throw new Error('size');} chunks.push(value); }
  const bytes=new Uint8Array(size);let offset=0;for(const c of chunks){bytes.set(c,offset);offset+=c.length;}
  return JSON.parse(new TextDecoder().decode(bytes));
}
async function quota(env, action, id, ip) {
  return env.QUOTA.get(env.QUOTA.idFromName('desktop-budget')).fetch('https://quota/', {
    method:'POST',body:JSON.stringify({action,id,ip})});
}
export class Quota {
  constructor(ctx,env) { this.ctx=ctx;this.env=env; }
  async fetch(req) {
    const {action,id,ip}=await req.json();const now=Date.now();
    const day=new Date(now).toISOString().slice(0,10), minute=Math.floor(now/60000);
    // One transaction reserves every request across Worker instances before calling a provider.
    const limits=action==='session' ? [[`register:${ip}`,10,86400]] :
      action==='openai' ? [[`global:openai`,Number(this.env.AI_DAILY_LIMIT)||1000,86400],[`ai:${id}`,50,86400],[`ai-ip:${ip}`,150,86400],[`ai-minute:${id}`,6,60]] :
      [[`global:jev`,Number(this.env.JEV_DAILY_LIMIT)||5000,86400],[`jev:${id}`,200,86400],[`jev-ip:${ip}`,600,86400],[`jev-minute:${id}`,30,60]];
    const result=await this.ctx.storage.transaction(async storage=>{
      const state=await storage.get('counters')||{};
      for(const k of Object.keys(state)) if(state[k].expires<now)delete state[k];
      for(const [name,limit,period] of limits) {
        const k=name+':'+(period===60?minute:day);
        if((state[k]?.count||0)>=limit)return false;
      }
      for(const [name,,period] of limits){const k=name+':'+(period===60?minute:day);
        state[k]={count:(state[k]?.count||0)+1,expires:now+period*1000};}
      await storage.put('counters',state);return true;
    });
    return result?json(200,{ok:true}):json(429,{error:'daily_or_rate_limit',message:'AI limit reached. Your local sampler remains available.'});
  }
}
export default {
  async fetch(req,env) {
    const path=new URL(req.url).pathname;
    if(path==='/health')return json(200,{ok:true,service:'crate-desktop',model:'gpt-4.1-mini',
      configured:!!(env.OPENAI_API_KEY&&env.TYPESAFE_API_KEY&&env.SESSION_SECRET)});
    if(req.method!=='POST')return json(405,{error:'method'});
    if(!env.SESSION_SECRET)return json(503,{error:'not_configured'});
    const ip=b64(await crypto.subtle.digest('SHA-256',enc.encode((req.headers.get('cf-connecting-ip')||'unknown')+env.SESSION_SECRET)));
    try {
      if(path==='/api/session') {
        const b=await body(req,1000);
        if(!/^[a-f0-9-]{36}$/i.test(b.installation_id||''))return json(400,{error:'installation_id'});
        const q=await quota(env,'session',b.installation_id,ip);if(!q.ok)return q;
        return json(200,{token:await issue(b.installation_id,env.SESSION_SECRET),expires_in:30*86400});
      }
      const id=await authenticate(req.headers.get('x-crate-token')||'',env.SESSION_SECRET);
      if(!id)return json(401,{error:'unauthorized'});
      if(!['/api/ai/openai','/api/ai/jev'].includes(path))return json(404,{error:'not_found'});
      const b=await body(req);const isGPT=path.endsWith('openai');
      let payload,endpoint,secret;
      if(isGPT) {
        if(b.model!=='gpt-4.1-mini')return json(400,{error:'model'});
        if(typeof b.input!=='string'||b.input.length>20000||typeof b.instructions!=='string'||b.instructions.length>12000)
          return json(400,{error:'input'});
        if(b.text?.format?.type!=='json_schema'||b.text.format.strict!==true||!['arrangement','flip'].includes(b.text.format.name))
          return json(400,{error:'schema'});
        const contract=prompts[b.text.format.name];
        payload={model:'gpt-4.1-mini',input:b.input,instructions:contract.instructions,text:{format:{type:'json_schema',name:b.text.format.name,strict:true,schema:contract.schema}},store:false,max_output_tokens:3000};
        endpoint='https://api.openai.com/v1/responses';secret=env.OPENAI_API_KEY;
      } else {
        if(typeof b.state!=='string'||!b.state||b.state.length>8000||!b.questions||Array.isArray(b.questions)||typeof b.questions!=='object')
          return json(400,{error:'input'});
        const canonical=v=>JSON.stringify(stable(v));
        const questions=questionSets.find(q=>canonical(q)===canonical(b.questions));
        if(!questions)return json(400,{error:'question_set'});
        payload={model:'jev-latest',state:b.state,questions};
        endpoint='https://api.typesafe.ai/v1/systemone';secret=env.TYPESAFE_API_KEY;
      }
      if(!secret)return json(503,{error:'not_configured'});
      const q=await quota(env,isGPT?'openai':'jev',id,ip);if(!q.ok)return q;
      const upstream=await fetch(endpoint,{method:'POST',headers:{Authorization:`Bearer ${secret}`,'content-type':'application/json'},
        body:JSON.stringify(payload),signal:AbortSignal.timeout(isGPT?14000:5000)});
      if(!upstream.ok)return json(upstream.status===429?429:502,{error:'provider_unavailable'});
      return new Response(upstream.body,{status:200,headers:{'content-type':'application/json','cache-control':'no-store'}});
    } catch(err) {return json(err.message==='size'?413:err instanceof SyntaxError?400:502,{error:'request_failed'});}
  }
};
