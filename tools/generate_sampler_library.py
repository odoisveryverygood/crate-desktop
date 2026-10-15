#!/usr/bin/env python3
"""CRATE Studio: original procedural instruments, kits and genre-specific phrases."""
import argparse
import hashlib
import json
import wave
from pathlib import Path
import numpy as np
import generate_original_library as base

SR = base.SR
STYLES = ['dilla','jazzhop','boombap','lofi','vintage','house','trap','drill','rnb','jerseyclub','garage','afrobeats','kpop']
TEMPOS = [86,94,90,78,84,124,140,144,96,140,132,108,120]
INSTRUMENTS = ['piano','rhodes','organ','clav','guitar','pluck','bell','vibes','marimba','steelpan',
               'flute','sax','horns','strings','pad','vocal','synth','bass','808','break']
NAMES = ['HAMMER','TINE','DRAWBAR','CLAVINET','NYLON','GLASS PLUCK','CHIME','VIBRAPHONE','WOOD MALLET','STEEL PAN',
         'AIR FLUTE','REED','BRASS','STRING ENSEMBLE','CLOUD','SYNTH CHOIR','ANALOG','SUB','GLIDE 808','DRUM BREAK']
KEYS = ['C','Db','D','Eb','E','F','Gb','G','Ab','A','Bb','B']
FAMILIES = ['ANALOG','DUST','CLUB','METAL','WOOD','DIGITAL','SOFT','HARD']
FAMILY_STYLES = [['house','vintage','boombap','jazzhop'], ['lofi','dilla','vintage','boombap'],
                 ['house','garage','jerseyclub','kpop'], ['trap','drill','jerseyclub','garage'],
                 ['afrobeats','jazzhop','rnb','dilla'], ['garage','kpop','trap','house'],
                 ['rnb','lofi','jazzhop','vintage'], ['drill','trap','jerseyclub','boombap']]
PATTERNS = {
 'dilla':[0,1.65,2.5,3.35], 'jazzhop':[0,1.5,2.75], 'boombap':[0,.75,2,3.5], 'lofi':[0,2.5],
 'vintage':[0,1.5,3], 'house':[.5,1.5,2.5,3.5], 'trap':[0,.75,1.5,2.75,3.5],
 'drill':[0,.75,1.75,2.5,3.25], 'rnb':[0,1.75,3.25], 'jerseyclub':[0,.75,1.5,2.5,3.25],
 'garage':[0,1.5,2.75,3.5], 'afrobeats':[0,.75,1.5,2.5,3.25], 'kpop':[0,1,2,3.5]}

def envelope(t, seconds, attack=.006, decay=1):
    e=(1-np.exp(-t/attack))*np.exp(-t*decay)
    n=min(len(t),round(SR*.045));e[-n:]*=np.linspace(1,0,n)
    return e

def instrument(note,seconds,kind,patch=0):
    t=base.timeline(seconds);f=440*2**((note-69)/12);phase=2*np.pi*f*t
    y=np.zeros(len(t));p=patch%8
    if kind in ['piano','rhodes','guitar','strings','pad']:
        y=base.tone(note,seconds,kind,p)
        # Distinct felt/bright, round/bell and small/wide patches, not duplicate files.
        spec=np.fft.rfft(y);freq=np.fft.rfftfreq(len(y),1/SR)
        cutoff=[1400,2400,4000,6500,8500,3200,5200,11000][p]
        y=np.fft.irfft(spec/(1+(freq/cutoff)**(2+p%3)),len(y))
        y*=np.exp(-t*(p%3)*.18)
        if p>=4:y+=.04*np.sin(phase*2.003)*np.exp(-t*2)
    elif kind=='organ':
        draws=[[1,.25,.4,.1,.15],[.7,.8,.3,.4,.1],[1,.1,.8,.1,.4]][p%3]
        for h,a in zip([1,2,3,4,6],draws):
            if f*h<SR*.45:y+=a*np.sin(phase*h)
        y*=envelope(t,seconds,.005,.3)*(1+.035*np.sin(2*np.pi*(5+p*.2)*t))
    elif kind in ['bell','vibes','steelpan','marimba','clav','pluck']:
        ratios={'bell':[1,2.71,4.12,5.43,6.8], 'vibes':[1,4,10,16], 'steelpan':[1,2,2.48,3.98,5.1],
                'marimba':[1,3.99,9.95,14], 'clav':[1,2,3,4,5,6], 'pluck':[1,2,3,4,5,7]}[kind]
        decay={'bell':.65,'vibes':1.05,'steelpan':1.5,'marimba':3.2,'clav':5,'pluck':3}[kind]
        for h,r in enumerate(ratios):
            if f*r<SR*.45:y+=np.sin(phase*r)/(1+h)**(1.2+p*.08)*np.exp(-t*decay*(1+h*.7))
        y*=envelope(t,seconds,.0015,.1)
    elif kind in ['flute','sax','horns']:
        vibrato=.004*np.sin(2*np.pi*(4.8+p*.17)*t)*(1-np.exp(-t*3))
        ph=2*np.pi*np.cumsum(f*(1+vibrato))/SR
        for h in range(1,13):
            if f*h>=SR*.45:break
            power=2.8 if kind=='flute' else 1.5 if kind=='sax' else 1.15
            a=1/h**(power+p*.04)
            if kind=='sax':a*=1+.5*np.exp(-((f*h-1300)/450)**2)
            y+=a*np.sin(ph*h)
        y+=base.bright_noise(t)*(.025 if kind=='flute' else .007)
        y*=envelope(t,seconds,.035,.65)
    elif kind=='vocal':
        formants=[(600+p*25,140),(1000+p*70,170),(2400+p*30,250)]
        for h in range(1,60):
            hz=f*h
            if hz>=SR*.45:break
            a=sum(np.exp(-((hz-c)/w)**2) for c,w in formants)
            y+=a*np.sin(phase*h)/h
        y*=envelope(t,seconds,.06,.55)
    elif kind in ['bass','808']:
        pitch=f*(1+(.25 if kind=='808' else .015)*np.exp(-t*45))
        ph=2*np.pi*np.cumsum(pitch)/SR
        y=np.sin(ph)+(.05+p*.045)*np.sin(ph*2)+.04*p*np.sin(ph*3)
        y=np.tanh(y*(1+p*.25))*envelope(t,seconds,.003,.9 if kind=='808' else 2)
    else:
        for h in range(1,18):
            if f*h>=SR*.45:break
            a=1/h**(1.1+p*.10)
            if p%3==0 and h%2==0:a*=.1
            y+=a*np.sin(phase*h+(1+p*.1)*np.sin(phase*.5)*np.exp(-t*4))
        y*=envelope(t,seconds,.004,1.5+p*.2)
    return y/max(float(np.max(np.abs(y))),.001)

def filtered(y,cutoff,high=False):
    freq=np.fft.rfftfreq(len(y),1/SR);s=np.fft.rfft(y)
    gain=1/(1+(freq/cutoff)**4)
    return np.fft.irfft(s*((1-gain) if high else gain),len(y))

def drum(category,family,v):
    # Each family changes synthesis, envelope, spectral shape, and saturation.
    p=family*8+v;rng=np.random.default_rng(730000+p*31+sum(map(ord,category)))
    duration={'kick':.3+v*.045,'snare':.22+v*.035,'clap':.24+v*.025,'hat':.07+v*.012,
              'openhat':.25+v*.075,'rim':.13+v*.012,'perc':.25+v*.035,'shaker':.14+v*.015,
              'cymbal':.9+v*.15,'808':1.4+v*.11,'bass':.7+v*.07,'fx':1+v*.2,
              'vocal':.5+v*.08,'texture':1.5+v*.12,'keys':1.4+v*.1,'synth':1.1+v*.1}[category]
    t=base.timeline(duration);n=rng.normal(size=len(t));hp=np.diff(n,prepend=n[0])*.5
    if category in ['keys','synth','bass','808','vocal']:
        kind={'keys':['piano','rhodes','organ','clav','bell','vibes','marimba','guitar'][family],
              'synth':['synth','pluck','pad','horns','steelpan','strings','flute','synth'][family]}.get(category,category)
        y=instrument(36 if category in ['bass','808'] else 60,duration,kind,v)
        y=filtered(y,900+family*1100) * np.exp(-t*family*.13)
        if family in [3,5,7]:y=np.tanh(y*(1+family*.5))
        return y
    if category=='kick':
        hz=(38+v*3+family)+(70+family*22)*np.exp(-t*(16+v*3+family))
        y=np.sin(2*np.pi*np.cumsum(hz)/SR)*np.exp(-t*(6+family*.9))
        y+=(.025+family*.02)*hp*np.exp(-t*(100+v*10))
    elif category=='snare':
        y=(.45+family*.05)*hp*np.exp(-t*(10+family+v))
        y+=.65*np.sin(2*np.pi*(145+v*16+family*8)*t)*np.exp(-t*(18+v*2))
        if family==4:y+=.4*np.sin(2*np.pi*760*t)*np.exp(-t*65)
    elif category=='clap':
        env=np.zeros(len(t))
        for k in range(2+family%4):
            start=k*(.006+v*.001)
            env+=np.where(t>=start,np.exp(-np.maximum(t-start,0)*(110+v*12)),0)
        env+=.3*np.exp(-t*(12+family*2));y=hp*env
    elif category in ['hat','openhat','cymbal','shaker']:
        y=hp*.45
        for h,hz in enumerate([2131,3271,4319,5711,7193,8911]):
            y+=np.sin(2*np.pi*(hz+family*67+v*29)*t)*(.08 if family!=3 else .2)
        decay={'hat':65,'openhat':7,'cymbal':2.5,'shaker':25}[category]*(.6+v*.10)
        y*=np.exp(-t*decay)
        if category=='shaker':y*=1+.5*np.sin(2*np.pi*(28+v*3)*t)
    elif category in ['perc','rim']:
        hz=130+v*55+family*41
        ratios=[1,1.52,2.16] if family%2 else [1,2.71,4.09]
        y=sum(np.sin(2*np.pi*hz*r*t)/(i+1)*np.exp(-t*(10+v+i*9)) for i,r in enumerate(ratios))
        y+=.12*hp*np.exp(-t*100)
    elif category=='texture':
        y=filtered(n,450+family*650+v*80)*.4
        clicks=rng.random(len(t))>.9995
        if family in [1,4]:y+=clicks*rng.uniform(-.6,.6,len(t))
        y*=np.sin(np.pi*t/duration)**2
    else:
        phase=2*np.pi*np.cumsum((120+v*80)*np.exp(t*(.3+family*.1)))/SR
        y=(np.sin(phase)+.3*hp)*np.sin(np.pi*t/duration)**2
        if family%2:y=y[::-1].copy()
    if family in [1,6]:y=filtered(y,1800 if family==1 else 3500)
    if family in [5,7]:y=np.tanh(y*(2+v*.2))
    if family==1:y=np.round(y*1024)/1024
    nfade=min(len(y)//2,220);y[:nfade]*=np.linspace(0,1,nfade);y[-nfade:]*=np.linspace(1,0,nfade)
    return y

def style_scores(style):
    scores={s:.12 for s in STYLES};scores[style]=.98
    for cluster in [['dilla','jazzhop','boombap','lofi','vintage'],['house','garage','jerseyclub'],['trap','drill'],['rnb','kpop','afrobeats']]:
        if style in cluster:
            for s in cluster:
                if s!=style:scores[s]=.55
    return scores

def make_loop(inst,style,variation,idx):
    si=STYLES.index(style);bpm=TEMPOS[si]+variation*4;beat=60/bpm
    shift=(si*5+variation*3)%12;minor=style in ['trap','drill','lofi','rnb','dilla']
    progressions=([[0,3,7,10],[8,12,15,19],[5,8,12,15],[7,10,14,17]],
                  [[0,4,7,11],[9,12,16,19],[5,9,12,16],[7,11,14,17]])
    chords=progressions[0 if minor else 1]
    y=np.zeros(round(16*beat*SR));onsets=[];cache={}
    patch=(si+variation*3)%8
    def note(n,d):
        k=(n,round(d,4))
        if k not in cache:cache[k]=instrument(n,d,inst,patch)
        return cache[k]
    if inst=='break':
        kit={c:drum(c,si%8,(si+variation)%8) for c in ['kick','snare','hat','openhat','perc']}
        kicks=[0,4,8,12] if style=='house' else [0,6,10] if style in ['garage','afrobeats'] else [0,7,10,14]
        if style=='jerseyclub':kicks=[0,3,6,10,12]
        for b in range(4):
            for lane,steps in [('kick',kicks),('snare',[4,12]),('hat',list(range(0,16,2))),('openhat',[6,14]),('perc',[3,11])]:
                for step in steps:
                    at=(b*4+step/4)*beat
                    if lane=='hat' and style in ['dilla','jazzhop','lofi']:at+=(step%4)*beat*.025
                    base.place(y,kit[lane],at,.6 if lane=='kick' else .35 if lane=='snare' else .14);onsets.append(at)
    else:
        for b,chord in enumerate(chords):
            positions=PATTERNS[style]
            if inst in ['strings','pad','vocal']:positions=[0,2] if variation else [0]
            if inst in ['flute','sax','horns','bell','vibes','marimba','steelpan','pluck']:
                positions=[0,.75,1.5,2.5,3.25] if variation else [.5,1.5,2.5,3.5]
            for k,pos in enumerate(positions):
                at=(b*4+pos)*beat;onsets.append(at)
                if inst in ['bass','808']:
                    ns=[36+shift+chord[0]+(12 if (k+b)%4==3 else 0)];dur=beat*(.7 if inst=='bass' else 1.2)
                elif inst in ['flute','sax','horns','bell','vibes','marimba','steelpan','pluck']:
                    ns=[60+shift+chord[(k+b+variation)%len(chord)]];dur=beat*(.65 if inst in ['flute','sax','horns'] else 1.8)
                else:
                    ns=[48+shift+n for n in chord];dur=beat*(4 if inst in ['strings','pad','vocal'] else 1.3)
                for j,n in enumerate(ns):base.place(y,note(n,dur),at+j*.004,(.19 if len(ns)>1 else .55)*(1-.1*(k%2)))
    if style in ['lofi','vintage']:y=filtered(y,3200);y=np.round(y*4096)/4096
    if inst!='break':y+=np.roll(y,round(beat*.75*SR))*.10
    # Short boundary fades prevent a discontinuity when the exported loop repeats.
    fade=min(len(y)//2,round(.004*SR))
    y[:fade]*=np.linspace(0,1,fade);y[-fade:]*=np.linspace(1,0,fade)
    ident=f'CS_{inst.upper()}_{style.upper()}_{variation+1}';file=f'loops/{inst}/{ident}.wav'
    quality=['m7','maj7'][not minor]
    symbols=[KEYS[(shift+c[0])%12]+('m7' if c[1]-c[0]==3 else 'maj7' if c[3]-c[0]==11 else '7') for c in chords]
    moods=['dark','melancholic'] if minor else ['warm','uplifting','groovy']
    entry=dict(id=ident,file=file,name=f'{style.upper()} {NAMES[INSTRUMENTS.index(inst)]} {variation+1}',instrument=inst,bpm=bpm,bars=4,beatsPerBar=4,
               durationSec=len(y)/SR,key=KEYS[shift]+('m' if minor else ''),keyConfidence=1,beatsSec=[i*beat for i in range(16)],
               onsetsSec=sorted(set(onsets)),slices16Sec=[i*beat for i in range(16)],chordsPerBar=[] if inst=='break' else symbols,
               bassPerBeat=[] if inst=='break' else [36+shift+chords[i//4][0] for i in range(16)],styles=style_scores(style),moods=moods,
               brightness=.35 if style in ['lofi','vintage'] else .65,dust=.7 if style in ['lofi','vintage'] else .1,
               source='CRATE Studio · original procedural synthesis')
    return entry,y

def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('output',type=Path);args=ap.parse_args()
    root=args.output.resolve();root.mkdir(parents=True,exist_ok=True)
    cats=['kick','snare','clap','hat','openhat','rim','perc','shaker','cymbal','808','bass','fx','vocal','texture','keys','synth']
    shots=[];loops=[];metrics={};hashes=set()
    def write(file,y):
        m=base.write_audio(root/file,y,.76 if file.startswith('oneshots') else .68)
        with wave.open(str(root/file)) as w:raw=w.readframes(w.getnframes())
        sha=hashlib.sha256(raw).hexdigest()
        if sha in hashes:raise ValueError('Duplicate audio: '+file)
        hashes.add(sha);m['sha256']=sha;metrics[file]=m
    for cat in cats:
        for family in range(8):
            for v in range(8):
                y=drum(cat,family,v);ident=f'CS_{cat.upper()}_{family+1}_{v+1}';file=f'oneshots/{cat}/{ident}.wav'
                write(file,y);style=FAMILY_STYLES[family][v%4]
                e=dict(id=ident,file=file,name=f'{FAMILIES[family]} {cat.upper()} {v+1}',category=cat,styles=style_scores(style),
                       tags=[FAMILIES[family].lower(),cat,'original','single-note'] if cat in ['keys','synth'] else [FAMILIES[family].lower(),cat,'original'],
                       brightness=.25+family*.07,punch=.5+family*.06,dust=.8 if family==1 else .1,durationSec=len(y)/SR,
                       decaySec=len(y)/SR,source='CRATE Studio · original procedural synthesis')
                if cat in ['keys','synth','bass','808','vocal']:e.update(rootNote=36 if cat in ['bass','808'] else 60,key='C')
                shots.append(e)
        print(f'{cat}: {len(shots)} shots total',flush=True)
    for inst in INSTRUMENTS:
        if inst!='break':
            cat='bass' if inst=='bass' else '808' if inst=='808' else 'vocal' if inst=='vocal' else 'synth' if inst in ['pad','synth','pluck'] else 'keys'
            for v,n in enumerate([36,43,48,55,60,67,72,79]):
                ident=f'CS_NOTE_{inst.upper()}_{n}';file=f'oneshots/{cat}/{ident}.wav';y=instrument(n,2.4,inst,v)
                write(file,y);shots.append(dict(id=ident,file=file,name=f'{NAMES[INSTRUMENTS.index(inst)]} {KEYS[n%12]}{n//12-1}',category=cat,
                    styles={s:.7 for s in STYLES},tags=[inst,'single-note','original'],rootNote=n,key=KEYS[n%12],brightness=.55,punch=.5,dust=.1,
                    durationSec=len(y)/SR,decaySec=len(y)/SR,source='CRATE Studio · original procedural synthesis'))
        for style in STYLES:
            for v in range(2):
                e,y=make_loop(inst,style,v,len(loops));write(e['file'],y);loops.append(e)
        print(f'{inst}: {len(loops)} loops total',flush=True)
    for name,d in [('oneshots.json',dict(version=2,samples=shots)),('loops.json',dict(version=2,loops=loops))]:
        (root/name).write_text(json.dumps(d,indent=2))
    import shutil
    shutil.copy2(Path(__file__).resolve().parents[1]/'library/grooves.json',root/'grooves.json')
    (root/'PROVENANCE.md').write_text('# CRATE Studio original library\n\nAll audio generated from oscillators, filtered noise, additive/FM synthesis and envelopes. No external audio inputs. Instrument names describe synthesized timbres, not acoustic recordings. Style/mood scores are authored from the generation recipes, not measured by CLAP. Existing CRATE groove templates supply sequencing. Deterministic seed 731026; mono PCM16 WAV at 44.1 kHz.\n')
    (root/'audio-validation.json').write_text(json.dumps(dict(one_shots=len(shots),loops=len(loops),unique_audio=len(hashes),files=metrics),indent=2))
    print(json.dumps(dict(output=str(root),one_shots=len(shots),loops=len(loops),unique_audio=len(hashes))),flush=True)

if __name__=='__main__':main()
