import {initialState,copy,slots,banks,plan,buildBeat,addLayer,applyArrangement,localFlip,slice,Sampler,encodeWav,clamp} from './core.mjs';
import {prompts,questionSets} from './contracts.mjs';
const $=id=>document.getElementById(id),config=await window.crate.config();
const [shots,loops,grooves]=await Promise.all(['oneshots','loops','grooves'].map(f=>fetch('crate://library/'+f+'.json').then(r=>r.json())));
const library={shots:shots.samples,loops:loops.loops,grooves},sampler=new Sampler(library);
let state=initialState(),history=[],future=[],serial=0,currentStep=0,mode='sample',shiftHeld=false,recording=false,recorder,stream,preview;
const status=t=>$('status').textContent=t;
const selected=()=>state.bank+state.selected;
function checkpoint(){history.push(copy(state));if(history.length>30)history.shift();future=[];}
function update(next){state=next;sampler.state=state;draw();}
async function activate(next){const playing=state.playing;await sampler.prepare(next);update({...next,playing});if(playing&&!sampler.active)await sampler.start(state,onStep);}
function onStep(n){const previousBar=Math.floor(currentStep/16);currentStep=n;if(Math.floor(n/16)!==previousBar)drawSequence();$('position').textContent=(Math.floor(n/16)+1)+'.'+(Math.floor(n%16/4)+1);document.querySelectorAll('.step').forEach(b=>b.classList.toggle('current',+b.dataset.step===n));}
function draw(){
 $('projects').textContent=state.name+' ▾';$('tempo').textContent=Math.round(state.bpm)+' BPM';$('bars').value=state.bars;$('style').textContent=state.style.toUpperCase();$('key').textContent=state.key;
 $('undo').disabled=!history.length;$('redo').disabled=!future.length;$('play').classList.toggle('playing',state.playing);$('play').innerHTML=(state.playing?'Ⅱ':'▶')+'<small>'+(state.playing?'PAUSE':'PLAY')+'</small>';
 $('sound-title').textContent=state.pads[selected()]?.name||'EMPTY PAD';
 $('banks').replaceChildren(...banks.map(b=>{const button=document.createElement('button');button.textContent=b;button.className=b===state.bank?'active':'';button.onclick=()=>{state.bank=b;draw();};return button;}));
 $('pads').replaceChildren(...[12,13,14,15,8,9,10,11,4,5,6,7,0,1,2,3].map(index=>{
  const button=document.createElement('button'),sound=state.pads[state.bank+index];button.className='pad'+(state.selected===index?' selected':'')+(sound?.muted?' muted':'');button.dataset.pad=state.bank+index;
  const number=document.createElement('span'),name=document.createElement('strong');number.textContent=index+1;name.textContent=sound?.name||'PAD '+(index+1);button.append(number,name);
  button.onpointerdown=e=>{if(e.button!==0)return;state.selected=index;if((e.shiftKey||shiftHeld)&&sound){checkpoint();sound.muted=!sound.muted;draw();}else{hit(state.bank+index);draw();}};
  button.ondblclick=()=>{$('pad-editor').hidden=false;drawEditor();};return button;
 }));
 drawSequence();drawWaveform();
}
function drawSequence(){
 const ids=Object.keys(state.pads).filter(p=>p.startsWith(state.bank)&&state.events.some(e=>e.pad===p)).slice(0,16);
 if(!ids.length){$('sequence').replaceChildren();return;}
 const bar=Math.floor(currentStep/16),rows=ids.map(pad=>{const row=document.createElement('div');row.className='lane';const label=document.createElement('span');label.textContent=state.pads[pad].name;label.onclick=()=>hit(pad);row.append(label);
 for(let i=0;i<16;i++){const step=bar*16+i,b=document.createElement('button');b.className='step'+(state.events.some(e=>e.pad===pad&&e.step===step)?' on':'');b.dataset.step=step;b.title=pad+' step '+(step+1);b.onclick=()=>{checkpoint();const found=state.events.find(e=>e.pad===pad&&e.step===step);state.events=state.events.filter(e=>!(e.pad===pad&&e.step===step));if(!found)state.events.push({pad,step,length:1,velocity:100});sampler.state=state;drawSequence();};row.append(b);}return row;});$('sequence').replaceChildren(...rows);
}
async function drawWaveform(){const key=selected(),sound=state.pads[key];if(!sound){$('waveform').replaceChildren();return;}try{const b=await sampler.buffer(sound);if(selected()!==key)return;const channel=b.getChannelData(0),cols=80,parts=[];for(let n=0;n<cols;n++){const lo=Math.floor(n*channel.length/cols),hi=Math.floor((n+1)*channel.length/cols);let peak=0;for(let i=lo;i<hi;i+=8)peak=Math.max(peak,Math.abs(channel[i]));const el=document.createElement('i');el.style.height=(2+peak*45)+'px';parts.push(el);}$('waveform').replaceChildren(...parts);}catch(e){status(e.message);}}
async function hit(pad,event={}){const sound=state.pads[pad];if(!sound||sound.muted)return;const node=await sampler.trigger(sound,event);const el=document.querySelector('[data-pad="'+pad+'"]');el?.classList.add('hit');setTimeout(()=>el?.classList.remove('hit'),130);return node;}
async function play(){if(state.playing){sampler.stop();state.playing=false;}else{state.playing=true;await sampler.start(state,onStep);}draw();}
function arrangementMessage(p){return {prompt:p.prompt,bpm:state.bpm,bars:state.bars,style:state.style,swing:state.swing,key:state.key,sample:state.loop?{name:state.loop.name,instrument:state.loop.instrument,key:state.loop.key,bars:4,chordsPerBar:state.loop.chordsPerBar,bassPerBeat:state.loop.bassPerBeat}:null};}
async function gpt(p,flip,requestSerial){
 if(!config.aiAllowed)return;
 const contract=prompts[flip?'flip':'arrangement'];let input=arrangementMessage(p);
 if(flip){input={...input,chops:Array.from({length:16},(_,i)=>({slice:i,lenSteps:4,energy:.7,attack:.5,tonal:.8,pitch:state.key,srcBar:Math.floor(i/4),role:i===0?'hero':'support'})),allowed:null,local:state.events.filter(e=>e.pad.startsWith(state.chopBank||'B')).map(e=>({bar:Math.floor(e.step/16),step:e.step%16,slice:+e.pad.slice(1),len:e.length,pitch:0}))};}
 status('Playing · GPT is arranging');
 try{const obj=await window.crate.ai('openai',{model:'gpt-4.1-mini',instructions:contract.instructions,input:JSON.stringify(input),text:{format:{type:'json_schema',name:flip?'flip':'arrangement',strict:true,schema:contract.schema}}});
 const text=(obj.output||[]).flatMap(x=>x.content||[]).filter(c=>c.type==='output_text').map(c=>c.text).join('');const result=JSON.parse(text);if(requestSerial!==serial)return;
 const next=applyArrangement(state,result,{flip});if(state.playing){await sampler.prepare(next);sampler.queue(next,()=>requestSerial===serial,()=>update({...next,playing:true}));}else update(next);
 status('GPT ✓ '+(result.comment||result.title||'Pattern applied'));
 }catch(e){if(requestSerial===serial)status(e.message+' Kept the instant version.');}
}
async function dig(){const prompt=$('prompt').value.trim();if(!prompt)return;const mine=++serial;checkpoint();let p=plan(prompt,library);const explicitInstrument=p.explicitInstrument?p.instrument:null,explicitBpm=p.explicitBpm;
 if(config.aiAllowed){try{const q=questionSets.find(q=>q.scope);const result=await Promise.race([window.crate.ai('jev',{state:prompt,questions:q}),new Promise(resolve=>setTimeout(()=>resolve(null),900))]);if(result?.answers){const a=result.answers,choice=k=>a[k]?.choice;if(choice('drum_style')&&choice('drum_style')!=='unspecified')p.style=choice('drum_style');if(!explicitBpm)p.bpm=library.grooves.styles[p.style]?.defaultBpm||p.bpm;if(!explicitInstrument&&choice('instrument')&&choice('instrument')!=='any')p.instrument=choice('instrument');if(p.scope==='full'){const scopes={drums_only:'drums',sample_only:'sample',bass_only:'bass',change_groove:'groove',single_sound:'sound'};p.scope=scopes[choice('scope')]||p.scope;}}}catch{}}
 if(explicitInstrument)p.instrument=explicitInstrument;if(p.scope!=='full'&&!p.explicitStyle)p.style=state.style;
 try{
 if(p.scope==='layer'){await activate(addLayer(state,library,p));status('Added '+p.instrument+' · other parts preserved');}
 else if(p.scope==='flip'){if(!state.loop)throw new Error('Load or import a sample first');await activate(localFlip(state));status('Instant flip · GPT follows');gpt(p,true,mine);}
 else if(p.scope==='drums'){const fresh=buildBeat(initialState(),library,{...p,bpm:explicitBpm?p.bpm:state.bpm});const s=copy(state);s.style=p.style;s.bpm=fresh.bpm;s.events=s.events.filter(e=>!e.pad.startsWith('A')).concat(fresh.events);Object.assign(s.pads,fresh.pads);await activate(s);status('Changed drums · other banks preserved');}
 else if(p.scope==='bass'){const s=copy(state);s.pads.C0=library.shots.find(x=>x.category==='bass');s.events=s.events.filter(e=>e.pad!=='C0');for(let bar=0;bar<s.bars;bar++)s.events.push({pad:'C0',step:bar*16,length:8,velocity:90,midi:s.loop?.bassPerBeat?.[bar*4]||36});await activate(s);status('Changed bass · other parts preserved');}
 else if(p.scope==='sample'){const fresh=buildBeat(initialState(),library,{...p,bpm:explicitBpm?p.bpm:state.bpm});const s=copy(state);for(const [pad,sound] of Object.entries(fresh.pads))if(pad.startsWith('B'))s.pads[pad]=sound;s.events=s.events.filter(e=>!e.pad.startsWith('B')).concat(fresh.events.filter(e=>e.pad.startsWith('B')));s.loop=fresh.loop;s.key=fresh.key;s.chopBank='B';await activate(s);status('Changed sample · drums preserved');}
 else if(p.scope==='sound'){const route=await window.crate.ai('jev',{state:prompt,questions:questionSets.find(q=>q.category)});const category=route.answers?.category?.choice||'fx';const sound=library.shots.find(s=>s.category===category);if(!sound)throw new Error('No matching sound');await loadSound(sound);status('Loaded '+sound.name+' · other pads preserved');}
 else if(p.scope==='groove'){const s=copy(state);s.swing=clamp(s.swing+(/tight|straight/.test(prompt)?-10:5),50,70);if(/simpl|sparse/.test(prompt))s.events=s.events.filter(e=>!e.pad.startsWith('A')||e.step%4===0);if(/busier|energetic/.test(prompt)){const pad='A3';for(let step=1;step<s.bars*16;step+=2)if(!s.events.some(e=>e.pad===pad&&e.step===step))s.events.push({pad,step,length:1,velocity:65});}await activate(s);status('Changed groove · sounds and melodies preserved');}
 else if(p.scope==='edit'){const s=copy(state),category=/hat/.test(prompt)?'hat':/snare/.test(prompt)?'snare':/bass/.test(prompt)?'bass':'kick',pad=category==='bass'?'C0':'A'+slots.indexOf(category);s.events=s.events.filter(e=>e.pad!==pad);if(!/remove|mute/.test(prompt)){const spacing=/less|fewer/.test(prompt)?4:1;for(let step=0;step<s.bars*16;step+=spacing)s.events.push({pad,step,length:1,velocity:category==='hat'?70:100});}await activate(s);status('Changed '+category+' · other parts preserved');}
 else{const next=buildBeat(state,library,p);await activate(next);if(!state.playing)await play();status('Instant '+p.style+' '+p.instrument+' beat');gpt(p,false,mine);}
 $('prompt').value='';draw();
 }catch(e){status(e.message);}
}
$('shift').onclick=()=>{shiftHeld=!shiftHeld;$('shift').classList.toggle('hit',shiftHeld);};$('dig').onclick=dig;$('deck-dig').onclick=()=>{$('prompt').focus();if($('prompt').value)dig();};$('prompt').onkeydown=e=>{if(e.key==='Enter')dig();};$('play').onclick=play;
$('undo').onclick=async()=>{if(!history.length)return;serial++;future.push(copy(state));await activate(history.pop());status('Undo');};$('redo').onclick=async()=>{if(!future.length)return;serial++;history.push(copy(state));await activate(future.pop());status('Redo');};
$('tempo').onclick=()=>{$('tempo-input').value=state.bpm;$('tempo-dialog').showModal();};$('tempo-apply').onclick=()=>{const value=+$('tempo-input').value;if(Number.isFinite(value)){checkpoint();state.bpm=clamp(value,50,200);sampler.state=state;draw();$('tempo-dialog').close();}};
$('bars').onchange=()=>{checkpoint();state.bars=+$('bars').value;sampler.state=state;draw();};$('position').onclick=()=>{if(!state.playing){currentStep=(currentStep+16)%(state.bars*16);onStep(currentStep);drawSequence();}};
$('save').onclick=async()=>{state.id=await window.crate.save(copy({...state,playing:false}));status('Saved '+state.name);};
$('export').onclick=async()=>{try{status('Rendering WAV…');const audio=await sampler.render(state);const saved=await window.crate.exportAudio(encodeWav(audio));status(saved?'WAV exported':'Export cancelled');}catch(e){status(e.message);}};
async function restore(p){serial++;sampler.stop();history=[];future=[];update({...initialState(),...p,playing:false});await sampler.prepare(state);status('Opened '+state.name);}
$('projects').onclick=async()=>{const list=await window.crate.projects();$('project-list').replaceChildren(...list.map(p=>{const row=document.createElement('div');row.className='project-row';const name=document.createElement('span'),button=document.createElement('button');name.textContent=p.name+' · '+p.bpm+' BPM';button.textContent='OPEN';button.onclick=async()=>{await restore(await window.crate.load(p.id));$('projects-dialog').close();};row.append(name,button);return row;}));$('projects-dialog').showModal();};
$('new-project').onclick=async()=>{if(Object.keys(state.pads).length)await window.crate.save(copy({...state,playing:false}));sampler.stop();serial++;history=[];future=[];update(initialState());$('projects-dialog').close();};
$('settings').onclick=()=>{$('ai-consent').checked=config.aiAllowed;$('settings-dialog').showModal();};$('ai-consent').onchange=async()=>{config.aiAllowed=await window.crate.consent($('ai-consent').checked);status(config.aiAllowed?'CRATE AI connected automatically':'AI help off · local sampler ready');};
for(const b of document.querySelectorAll('[data-close]'))b.onclick=()=>b.closest('dialog').close();
async function loadSound(sound){checkpoint();const pad=selected();state.pads[pad]=copy(sound);await sampler.buffer(sound);sampler.state=state;draw();$('library-message').textContent='Loaded '+sound.name+' on '+pad;}
async function chop(loop){checkpoint();const s=copy(state);s.chopBank='D';s.loop=loop;s.bank='D';s.events=s.events.filter(e=>!e.pad.startsWith('D'));for(let i=0;i<16;i++){s.pads['D'+i]=slice(loop,i);s.events.push({pad:'D'+i,step:i*4,length:4,velocity:100});}await activate(s);$('library-message').textContent='16 chops loaded to D · other banks preserved';}
function soundResults(){const query=$('search').value.toLowerCase().split(/\s+/).filter(Boolean),kind=$('kind').value,list=[...(kind==='loops'?[]:library.shots),...(kind==='shots'?[]:library.loops)].filter(s=>query.every(w=>(s.name+' '+s.category+' '+s.instrument+' '+s.bpm+' '+JSON.stringify(s.tags||[])+' '+Object.entries(s.styles||{}).filter(([,v])=>v>.5).map(([k])=>k).join(' ')).toLowerCase().includes(w)));
 $('library-count').textContent=list.length+' matches · '+library.shots.length+' hits · '+library.loops.length+' loops';
 $('library-results').replaceChildren(...list.slice(0,150).map(sound=>{const row=document.createElement('div');row.className='sound-row';const label=document.createElement('div'),name=document.createElement('strong'),meta=document.createElement('small');name.textContent=sound.name;meta.textContent=sound.instrument?(sound.instrument+' · '+sound.bpm+' BPM · '+sound.key):sound.category;label.append(name,meta);row.append(label);for(const [text,action] of [['PREVIEW',async()=>{preview?.stop();preview=await sampler.trigger(sound);}],['LOAD',()=>loadSound(sound)],...(sound.instrument?[['CHOP D',()=>chop(sound)]]:[])]){const b=document.createElement('button');b.textContent=text;b.onclick=()=>action().catch(e=>$('library-message').textContent=e.message);row.append(b);}return row;}));
}
$('library').onclick=()=>{soundResults();$('library-dialog').showModal();};$('search').oninput=soundResults;$('kind').onchange=soundResults;
$('import').onclick=async()=>{try{const file=await window.crate.importAudio();if(!file)return;const sound={...file,imported:true,id:file.file,instrument:'sample',bpm:state.bpm,key:state.key};sound.durationSec=(await sampler.buffer(sound)).duration;await chop(sound);status('Imported audio · 16 chops on D');}catch(e){status(e.message);}};
function drawEditor(){const sound=state.pads[selected()];if(!sound)return;$('trim-start').value=(sound.start||0)/(sound.durationSec||1)*1000;$('trim-end').value=(sound.end??sound.durationSec)/(sound.durationSec||1)*1000;}
$('trim-start').onchange=()=>{const s=state.pads[selected()];if(s){checkpoint();s.start=clamp(+$('trim-start').value/1000*s.durationSec,0,(s.end||s.durationSec)-.01);sampler.state=state;}};
$('trim-end').onchange=()=>{const s=state.pads[selected()];if(s){checkpoint();s.end=clamp(+$('trim-end').value/1000*s.durationSec,(s.start||0)+.01,s.durationSec);sampler.state=state;}};
$('remove-pad').onclick=()=>{checkpoint();delete state.pads[selected()];state.events=state.events.filter(e=>e.pad!==selected());$('pad-editor').hidden=true;draw();};
$('reverse-pad').onclick=()=>{const s=state.pads[selected()];if(!s)return;checkpoint();s.reversed=!s.reversed;status(s.reversed?'Pad reversed':'Pad forward');};
$('filter').oninput=()=>sampler.filter.frequency.value=+$('filter').value;$('volume').oninput=()=>sampler.master.gain.value=+$('volume').value/100;$('punch').oninput=()=>sampler.filter.frequency.value=20000*(1-+$('punch').value/100)+150;
$('halfspeed').onclick=()=>{checkpoint();for(const sound of Object.values(state.pads))sound.rate=sound.rate===.5?1:.5;sampler.state=state;status('Half speed toggled');};$('mute-bank').onclick=()=>{checkpoint();const muted=!Object.values(state.pads).some(s=>s.muted);for(const [pad,sound] of Object.entries(state.pads))if(pad.startsWith(state.bank))sound.muted=muted;draw();};
const keyMap='zsxdcvgbhnjm,',pressed=new Map();
$('keyboard').replaceChildren(...Array.from({length:13},(_,i)=>{const b=document.createElement('button');b.className='key'+([1,3,6,8,10].includes(i)?' black':'');b.textContent=keyMap[i].toUpperCase();b.onpointerdown=()=>hit('C1',{midi:60+i});b.onpointerup=()=>{};return b;}));
for(const button of document.querySelectorAll('[data-mode]'))button.onclick=()=>{mode=button.dataset.mode;document.querySelectorAll('[data-mode]').forEach(b=>b.classList.toggle('active',b===button));$('pads').hidden=mode!=='sample';$('keyboard').hidden=mode!=='keys';$('effects').hidden=mode!=='fx';};
const padKeys='zxcvasdfqwer1234';
document.addEventListener('keydown',async e=>{if(e.target.matches('input,select,textarea')||document.querySelector('dialog[open]'))return;if(e.repeat)return;
 if(e.ctrlKey||e.metaKey){const k=e.key.toLowerCase();if(['s','o','l','z'].includes(k))e.preventDefault();if(k==='s')$('save').click();if(k==='o')$('import').click();if(k==='l')$('library').click();if(k==='z')(e.shiftKey?$('redo'):$('undo')).click();return;}
 if(e.code==='Space'){e.preventDefault();play();return;}
 const index=mode==='keys'?keyMap.indexOf(e.key.toLowerCase()):padKeys.indexOf(e.key.toLowerCase());if(index<0)return;
 const pad=mode==='keys'?'C1':state.bank+index;state.selected=mode==='keys'?1:index;pressed.set(e.key,await hit(pad,mode==='keys'?{midi:60+index}:{}));draw();
});
document.addEventListener('keyup',e=>{if(mode==='keys'){try{pressed.get(e.key)?.stop();}catch{}}pressed.delete(e.key);});window.addEventListener('blur',()=>{for(const n of pressed.values())try{n?.stop();}catch{}pressed.clear();});
$('record').onclick=async()=>{if(recording){recorder.stop();return;}try{stream=await navigator.mediaDevices.getUserMedia({audio:true});const chunks=[];recorder=new MediaRecorder(stream);recorder.ondataavailable=e=>chunks.push(e.data);recorder.onstop=async()=>{stream.getTracks().forEach(t=>t.stop());recording=false;$('record').classList.remove('recording');try{const buffer=await sampler.context.decodeAudioData(await new Blob(chunks).arrayBuffer());const file=await window.crate.recordAudio(encodeWav(buffer));await loadSound({...file,imported:true,id:file.file,durationSec:buffer.duration});status('Recording loaded on '+selected());}catch(e){status(e.message);}};recorder.start();recording=true;$('record').classList.add('recording');status('Recording microphone · click RECORD to finish');}catch(e){status('Microphone unavailable: '+e.message);}};
draw();
if(config.verify){
 if(config.verify)config.aiAllowed=false;
 const checks={library_complete:library.shots.length===1176&&library.loops.length===520};
 let s=buildBeat(initialState(),library,plan('house piano beat at 124 bpm',library));checks.house_piano=s.loop.instrument==='piano'&&s.bpm===124;await sampler.prepare(s);checks.decoded_36_pads=Object.values(s.pads).length===36;
 const before=JSON.stringify(Object.fromEntries(Object.entries(s.pads).filter(([p])=>p.startsWith('A')||p.startsWith('B'))));s=addLayer(s,library,plan('add a flute line',library));s=addLayer(s,library,plan('add strings on top',library));checks.two_independent_layers=s.layers.length===2;checks.layers_preserve_banks=before===JSON.stringify(Object.fromEntries(Object.entries(s.pads).filter(([p])=>p.startsWith('A')||p.startsWith('B'))));
 const rendered=await sampler.render(s),wav=encodeWav(rendered);let peak=0;for(const channel of [rendered.getChannelData(0),rendered.getChannelData(1)])for(const x of channel)peak=Math.max(peak,Math.abs(x));checks.actual_audio_export=peak>.001&&wav.length>100000;checks.export_duration=Math.abs(rendered.duration-4*240/124)<.001;
 update({...s,playing:false});
 const protectedSample=JSON.stringify(Object.fromEntries(Object.entries(state.pads).filter(([p])=>p.startsWith('B'))));
 $('prompt').value='drums only';await dig();checks.renderer_drums_preserve_samples=protectedSample===JSON.stringify(Object.fromEntries(Object.entries(state.pads).filter(([p])=>p.startsWith('B'))));
 const protectedDrums=JSON.stringify(Object.fromEntries(Object.entries(state.pads).filter(([p])=>p.startsWith('A'))));
 $('prompt').value='add a bass line';await dig();checks.renderer_bass_preserves_drums=protectedDrums===JSON.stringify(Object.fromEntries(Object.entries(state.pads).filter(([p])=>p.startsWith('A'))));
 $('prompt').value='more hats';await dig();checks.renderer_lane_edit_preserves_samples=protectedSample===JSON.stringify(Object.fromEntries(Object.entries(state.pads).filter(([p])=>p.startsWith('B'))));
 await $('undo').onclick();checks.renderer_undo_restores_parts=state.layers.length===2;
 const id=await window.crate.save(s),restored=await window.crate.load(id);checks.project_roundtrip=restored.layers.length===2&&restored.events.length===s.events.length;checks.pad_ui_16=$('pads').children.length===16;
 if(config.hostedVerify){
  try{
   const jev=await window.crate.ai('jev',{state:'house piano beat at 124 bpm',questions:questionSets.find(q=>q.scope)});checks.native_hosted_jev=!!jev.answers?.scope;
   const contract=prompts.arrangement,reply=await window.crate.ai('openai',{model:'gpt-4.1-mini',instructions:contract.instructions,input:JSON.stringify({prompt:'house piano beat at 124 bpm',bpm:124,bars:4,style:'house'}),text:{format:{type:'json_schema',name:'arrangement',strict:true,schema:contract.schema}}});
   const text=reply.output.flatMap(x=>x.content||[]).filter(c=>c.type==='output_text').map(c=>c.text).join('');const arranged=applyArrangement(s,JSON.parse(text));checks.native_hosted_gpt=arranged.events.some(e=>e.pad.startsWith('A'))&&arranged.pads.B0.id===s.pads.B0.id;
  }catch(e){checks.native_hosted_ai=false;status(e.message);}
 }
 await window.crate.verifyComplete({platform:config.platform,hostedAI:config.hostedVerify,checks,passed:Object.values(checks).every(Boolean),export:{seconds:rendered.duration,peak,bytes:wav.length}});
}else{const saved=await window.crate.load(null);if(saved)await restore(saved);}
