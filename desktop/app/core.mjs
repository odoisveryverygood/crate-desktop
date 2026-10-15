export const slots=['kick','snare','clap','hat','openhat','kick','hat','rim','perc','perc','shaker','cymbal','808','fx','vocal','texture'];
export const banks=['A','B','C','D'];
export const clamp=(v,min,max)=>Math.max(min,Math.min(max,v));
export const copy=v=>JSON.parse(JSON.stringify(v));
export function initialState(){return {id:null,name:'UNTITLED',bpm:90,bars:4,swing:50,bank:'A',selected:0,style:'lofi',key:'Cm',pads:{},events:[],layers:[],playing:false,chopBank:'B'};}
export function plan(prompt,library){
 const lower=prompt.toLowerCase();const styles=Object.keys(library.grooves.styles);
 const requestedStyle=styles.find(s=>lower.includes(s))||styles.find(s=>(library.grooves.styles[s].keywords||[]).some(k=>lower.includes(k)));let style=requestedStyle||'lofi';
 const aliases=[['rhodes',['electric piano','rhodes','wurlitzer']],['piano',['piano']],['flute',['flute']],['sax',['sax']],['strings',['strings','violin','cello']],['guitar',['guitar']],['organ',['organ']],['clav',['clavinet','clav']],['steelpan',['steel pan','steelpan']],['marimba',['marimba']],['vibes',['vibraphone','vibes']],['bell',['bells','bell']],['pluck',['pluck']],['horns',['brass','horns','trumpet']],['pad',['ambient pad','pad']],['vocal',['choir','vocal']],['synth',['synth','lead']]];
 const namedInstrument=aliases.find(([,words])=>words.some(w=>lower.includes(w)));const instrument=namedInstrument?.[0]||'piano';
 const numeric=lower.match(/\b(\d{2,3})(?:\s*bpm)?\b/);const tempo=numeric&&+numeric[1]>=50&&+numeric[1]<=200?+numeric[1]:library.grooves.styles[style].defaultBpm;
 const scope=/\b(flip|remix)\b/.test(lower)?'flip':/^(add|change)\b.*\bbass\b|bass only/.test(lower)?'bass':/sample only|loop only/.test(lower)?'sample':/^(more|less|make it|swing|tighter|looser|simpler|busier).*?(swing|laid.?back|groove|busier|simpler|tight|loose)/.test(lower)?'groove':/^(add|layer)\b/.test(lower)&&aliases.some(([,w])=>w.some(x=>lower.includes(x)))?'layer':/^(more|less|fewer|remove|mute)\b.*(hats|kick|snare|bass)/.test(lower)?'edit':/drums only|drum kit/.test(lower)?'drums':'full';
 return {prompt,style,instrument,bpm:tempo,scope,explicitInstrument:!!namedInstrument,explicitStyle:!!requestedStyle,explicitBpm:!!numeric&&+numeric[1]>=50&&+numeric[1]<=200};
}
export function choose(list,score){return [...list].sort((a,b)=>score(b)-score(a))[Math.floor(Math.random()*Math.min(3,list.length))];}
export function retrieveLoop(library,p,exclude=[]){
 let list=library.loops.filter(l=>l.instrument===p.instrument&&!exclude.includes(l.id));if(!list.length)list=library.loops.filter(l=>!exclude.includes(l.id));
 const exact=list.filter(l=>l.bpm===p.bpm);if(exact.length)list=exact;
 return choose(list,l=>(l.styles?.[p.style]||0)*10-Math.abs(l.bpm-p.bpm)/20);
}
export function shot(library,category,style){return choose(library.shots.filter(s=>s.category===category),s=>s.styles?.[style]||0);}
export function slice(loop,index,count=16){const duration=loop.durationSec;return {...loop,start:duration*index/count,end:duration*(index+1)/count,name:(loop.instrument||'CHOP').toUpperCase()+' '+(index+1),loopBpm:loop.bpm,id:loop.id+'#'+index};}
export function buildBeat(state,library,p){
 const s=copy(state);s.bpm=p.bpm;s.style=p.style;s.name=p.style.toUpperCase()+' '+p.instrument.toUpperCase();s.bars=4;s.events=[];s.layers=[];s.pads={};s.chopBank='B';
 slots.forEach((c,i)=>{const sound=shot(library,c,p.style);if(sound)s.pads['A'+i]=sound;});
 const groove=choose(library.grooves.grooves.filter(g=>g.style===p.style),()=>1);s.swing=groove?.swing||50;
 for(const [lane,hits] of Object.entries(groove?.lanes||{})){const pad='A'+slots.indexOf(lane);if(pad==='A-1')continue;for(let bar=0;bar<4;bar+=groove.bars)for(const [step,velocity,offset=0,ratchet=1] of hits)s.events.push({pad,step:bar*16+step,velocity,length:1,offset,ratchet});}
 if(p.scope!=='drums'){
 const loop=retrieveLoop(library,p);s.loop=loop;s.key=loop.key||'Cm';
 for(let i=0;i<16;i++){s.pads['B'+i]=slice(loop,i);s.events.push({pad:'B'+i,step:i*4,length:4,velocity:105});}
 s.pads.C0=shot(library,'bass',p.style);s.pads.C1=shot(library,'keys',p.style);s.pads.C2=shot(library,'synth',p.style);s.pads.C3=shot(library,'808',p.style);
 for(let bar=0;bar<4;bar++)s.events.push({pad:'C0',step:bar*16,length:8,velocity:88,midi:loop.bassPerBeat?.[bar*4]||36});
 }
 return s;
}
export function addLayer(state,library,p){const s=copy(state),existing=s.layers.find(l=>l.instrument===p.instrument&&!/another|second|extra/.test(p.prompt));let pads=existing?.pads;
 if(!pads){for(const bank of ['D','C']){const start=bank==='C'?4:0;for(let i=start;i<=12;i+=4){const candidate=Array.from({length:4},(_,j)=>bank+(i+j));if(candidate.every(k=>!s.pads[k])){pads=candidate;break;}}if(pads)break;}}
 if(!pads)throw new Error('All layer pads are occupied. Free four pads first.');
 const loop=retrieveLoop(library,{...p,bpm:s.bpm},s.layers.map(l=>l.loop.id));
 s.events=s.events.filter(e=>!pads.includes(e.pad));pads.forEach((pad,i)=>{s.pads[pad]=slice(loop,i,4);s.events.push({pad,step:i*16,length:16,velocity:90});});
 s.layers=s.layers.filter(l=>!existing||l!==existing);s.layers.push({instrument:p.instrument,pads,loop});return s;
}
export function applyArrangement(state,a,{flip=false}={}){
 const s=copy(state),total=s.bars*16;const chopBank=s.chopBank||'B';const keep=s.events.filter(e=>flip?!e.pad.startsWith(chopBank):!e.pad.startsWith('A')&&e.pad!=='C0');const events=[...keep];
 if(!flip){
 for(const d of a.drums||[]){const pad='A'+slots.indexOf(d.lane);if(!s.pads[pad])continue;for(let bar=0;bar<s.bars;bar++){const text=d.bars?.[bar%d.bars.length]||'';[...text.slice(0,16)].forEach((c,i)=>{if('Xxgr'.includes(c))events.push({pad,step:bar*16+i,length:1,velocity:{X:118,x:92,g:44,r:86}[c],offset:clamp(d.late||0,-.3,.4),ratchet:c==='r'?2:1});});}}
 for(const b of a.bass||[])if(b.bar>=0&&b.bar<s.bars&&b.step>=0&&b.step<16)events.push({pad:'C0',step:b.bar*16+b.step,length:clamp(b.len,.5,16),midi:clamp(b.midi,28,52),velocity:clamp(b.vel,1,127)});
 if(a.chords?.length&&s.pads.C1){for(const c of a.chords)for(const midi of c.notes||[])if(c.bar>=0&&c.bar<s.bars&&c.step>=0&&c.step<16)events.push({pad:'C1',step:c.bar*16+c.step,length:clamp(c.len,.5,16),midi:clamp(midi,36,96),velocity:clamp(c.vel,1,127)});}
 if(a.swing)s.swing=clamp(a.swing,50,70);
 }
 if(flip){const valid=(a.chops||[]).filter(c=>c.bar>=0&&c.bar<s.bars&&c.step>=0&&c.step<16&&c.slice>=0&&c.slice<16);if(valid.length<2)throw new Error('AI flip was empty; kept the instant flip');for(const c of valid)events.push({pad:chopBank+c.slice,step:c.bar*16+c.step,length:clamp(c.len,.5,8),pitch:clamp(c.pitch||0,-12,12),velocity:105});}
 s.events=events.filter(e=>e.step>=0&&e.step<total&&s.pads[e.pad]);return s;
}
export function localFlip(state){const s=copy(state);s.events=s.events.filter(e=>!e.pad.startsWith(s.chopBank||'B'));for(let bar=0;bar<s.bars;bar++)for(let n=0;n<4;n++)s.events.push({pad:(s.chopBank||'B')+Math.floor(Math.random()*16),step:bar*16+n*4,length:n===3?2:4,velocity:105});return s;}
export function encodeWav(buffer){
 const channels=buffer.numberOfChannels,frames=buffer.length,bytes=new ArrayBuffer(44+frames*channels*2),v=new DataView(bytes);const text=(o,t)=>[...t].forEach((c,i)=>v.setUint8(o+i,c.charCodeAt(0)));
 text(0,'RIFF');v.setUint32(4,bytes.byteLength-8,true);text(8,'WAVE');text(12,'fmt ');v.setUint32(16,16,true);v.setUint16(20,1,true);v.setUint16(22,channels,true);v.setUint32(24,buffer.sampleRate,true);v.setUint32(28,buffer.sampleRate*channels*2,true);v.setUint16(32,channels*2,true);v.setUint16(34,16,true);text(36,'data');v.setUint32(40,frames*channels*2,true);
 const data=Array.from({length:channels},(_,c)=>buffer.getChannelData(c));let peak=0;for(const channel of data)for(const sample of channel)peak=Math.max(peak,Math.abs(sample));const scale=peak>.98?.98/peak:1;
 for(let i=0;i<frames;i++)for(let c=0;c<channels;c++){const x=clamp(data[c][i]*scale,-1,1);v.setInt16(44+(i*channels+c)*2,x<0?x*32768:x*32767,true);}return new Uint8Array(bytes);
}
function limiter(ctx){const node=ctx.createWaveShaper(),curve=new Float32Array(4096);for(let i=0;i<curve.length;i++)curve[i]=.97*Math.tanh((i*2/(curve.length-1)-1)*2);node.curve=curve;return node;}
export class Sampler {
 constructor(library){this.library=library;this.context=new AudioContext({latencyHint:'interactive'});this.cache=new Map();this.voices=new Set();this.master=this.context.createGain();this.master.gain.value=.65;this.filter=this.context.createBiquadFilter();this.filter.type='lowpass';this.filter.frequency.value=20000;this.master.connect(this.filter);this.limiter=limiter(this.context);this.filter.connect(this.limiter);this.limiter.connect(this.context.destination);this.active=false;}
 async buffer(sound){const url=sound.imported?'crate://imports/'+sound.file:'crate://library/'+sound.file;if(!this.cache.has(url)){const r=await fetch(url);if(!r.ok)throw new Error('Audio file unavailable');this.cache.set(url,await this.context.decodeAudioData(await r.arrayBuffer()));}return this.cache.get(url);}
 async prepare(state){await Promise.all(Object.values(state.pads).map(s=>this.buffer(s)));}
 voice(ctx,destination,sound,buffer,event,time,bpm){
  const node=ctx.createBufferSource(),gain=ctx.createGain();node.buffer=buffer;let start=clamp(sound.start||0,0,buffer.duration),end=clamp(sound.end??buffer.duration,start,buffer.duration);
  if(sound.reversed){const frames=Math.max(1,Math.floor((end-start)*buffer.sampleRate)),reversed=ctx.createBuffer(buffer.numberOfChannels,frames,buffer.sampleRate),offset=Math.floor(start*buffer.sampleRate);for(let c=0;c<buffer.numberOfChannels;c++){const source=buffer.getChannelData(c),out=reversed.getChannelData(c);for(let i=0;i<frames;i++)out[i]=source[offset+frames-1-i]||0;}node.buffer=reversed;start=0;end=reversed.duration;}
  const note=event.midi!=null?(event.midi-(sound.rootNote??(sound.category==='bass'?36:60))):event.pitch||0;
  const rate=(sound.loopBpm?bpm/sound.loopBpm:1)*2**(note/12)*(sound.rate||1);node.playbackRate.value=rate;
  let length=(end-start)/rate;if(event.sequence)length=Math.min(length,event.length*60/bpm/4);length=Math.max(.005,length);
  const level=(event.velocity||100)/127*(sound.level??1);gain.gain.setValueAtTime(0,time);gain.gain.linearRampToValueAtTime(level,time+.003);gain.gain.setValueAtTime(level,Math.max(time+.003,time+length-.012));gain.gain.linearRampToValueAtTime(0,time+length);
  node.connect(gain);gain.connect(destination);node.start(time,start);node.stop(time+length+.002);return node;
 }
 async trigger(sound,event={}){if(!sound)return null;await this.context.resume();const b=await this.buffer(sound);const n=this.voice(this.context,this.master,sound,b,event,this.context.currentTime,this.state?.bpm||90);this.voices.add(n);n.onended=()=>this.voices.delete(n);return n;}
 queue(state,valid,commit){this.pending={state,valid,commit};}
 async start(state,onStep){this.stop();this.state=state;await this.context.resume();await this.prepare(state);this.active=true;let step=0,next=this.context.currentTime+.08;this.timer=setInterval(()=>{while(next<this.context.currentTime+.12){const seconds=60/this.state.bpm/4,index=step%(this.state.bars*16);if(index===0&&this.pending){const pending=this.pending;this.pending=null;if(pending.valid()){this.state=pending.state;pending.commit();}}for(const e of this.state.events.filter(e=>e.step===index)){const snd=this.state.pads[e.pad];if(!snd||snd.muted)continue;const repeats=e.ratchet||1;for(let r=0;r<repeats;r++){const time=Math.max(this.context.currentTime,next+(e.offset||0)*seconds+(index%2?(2*this.state.swing/100-1)*seconds:0)+r*seconds/repeats);const n=this.voice(this.context,this.master,snd,this.cache.get(snd.imported?'crate://imports/'+snd.file:'crate://library/'+snd.file),{...e,sequence:true,length:e.length/repeats},time,this.state.bpm);this.voices.add(n);n.onended=()=>this.voices.delete(n);}}onStep(index);next+=seconds;step++;}},25);}
 stop(){this.pending=null;clearInterval(this.timer);for(const n of this.voices){try{n.stop();}catch{}}this.voices.clear();this.active=false;}
 async render(state){await this.prepare(state);const duration=state.bars*240/state.bpm,ctx=new OfflineAudioContext(2,Math.ceil(duration*48000),48000),master=ctx.createGain();master.gain.value=this.master.gain.value;const filter=ctx.createBiquadFilter();filter.type='lowpass';filter.frequency.value=this.filter.frequency.value;const output=limiter(ctx);master.connect(filter);filter.connect(output);output.connect(ctx.destination);for(const e of state.events){const snd=state.pads[e.pad];if(!snd||snd.muted)continue;for(let r=0;r<(e.ratchet||1);r++)this.voice(ctx,master,snd,this.cache.get(snd.imported?'crate://imports/'+snd.file:'crate://library/'+snd.file),{...e,sequence:true},Math.max(0,(e.step+(e.offset||0)+r/(e.ratchet||1))*60/state.bpm/4),state.bpm);}return ctx.startRendering();}
}
