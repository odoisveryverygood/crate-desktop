#!/usr/bin/env python3
"""Make original procedural CRATE sounds. Requires NumPy; no sample-pack inputs."""
import argparse
import json
import shutil
import wave
from pathlib import Path
import numpy as np

SR = 44100
RNG = np.random.default_rng(731026)
STYLES = ['dilla', 'jazzhop', 'boombap', 'lofi', 'vintage', 'house', 'trap', 'drill', 'rnb']

def timeline(seconds):
    return np.arange(round(seconds * SR)) / SR

def noise(t):
    return RNG.normal(0, 1, len(t))

def bright_noise(t):
    n = noise(t)
    return np.diff(n, prepend=n[0]) * .5

def tone(note, seconds, kind='piano', variant=0):
    t = timeline(seconds)
    f = 440 * 2 ** ((note - 69) / 12)
    attack = 1 - np.exp(-t / (.035 if kind in ['pad', 'strings'] else .002))
    y = np.zeros(len(t))
    if kind == 'piano':
        # Slightly inharmonic strings with faster decay for high partials.
        for h in range(1, 15):
            freq = f * h * np.sqrt(1 + .00012 * h*h)
            if freq > SR * .45: break
            y += (1 / h**1.45) * np.sin(2*np.pi*freq*t + .03*h) * np.exp(-t*(1.0+h*.24))
        y += .025 * bright_noise(t) * np.exp(-t*95)
    elif kind == 'rhodes':
        y = np.sin(2*np.pi*f*t + (1.5 + variant*.08)*np.sin(2*np.pi*f*2*t)*np.exp(-t*3)) * np.exp(-t*1.5)
        y += .2*np.sin(2*np.pi*f*t*3) * np.exp(-t*3.5)
    elif kind == 'guitar':
        for h in range(1, 18):
            if f*h > SR*.45: break
            y += np.sin(2*np.pi*f*h*t) / h**1.25 * np.exp(-t*(2+h*.35))
        y += .04*bright_noise(t)*np.exp(-t*70)
    elif kind in ['pad', 'strings']:
        for h in range(1, 9):
            if f*h > SR*.45: break
            for detune in [-.0018, .0018]:
                y += np.sin(2*np.pi*f*h*(1+detune)*t) / (h**1.7 * 2)
        y *= np.exp(-t*.22)
        if kind == 'strings': y *= 1 + .025*np.sin(2*np.pi*5.2*t)
    elif kind in ['bass', '808']:
        y = np.sin(2*np.pi*f*t) + .2*np.sin(2*np.pi*f*2*t)
        y *= np.exp(-t*(1.1 if kind == '808' else 2.2))
        y = np.tanh(y * (1.4+variant*.05))
    else:
        for h in range(1, 10):
            if f*h > SR*.45: break
            y += np.sin(2*np.pi*f*h*t) / h**1.6 * np.exp(-t*(2+h*.3))
    y *= attack
    fade = min(len(y), round(SR*.04))
    y[-fade:] *= np.linspace(1, 0, fade)
    return y / max(np.max(np.abs(y)), .001)

def shot(category, v):
    duration = {'kick':.6,'snare':.42,'clap':.42,'hat':.13,'openhat':.6,'rim':.22,
                'perc':.4,'shaker':.22,'cymbal':1.8,'808':2,'bass':1.4,
                'fx':1.4,'vocal':.6,'texture':2,'keys':2,'synth':1.6}[category]
    t = timeline(duration)
    if category == 'kick':
        f = 44+v*2 + (100+v*8)*np.exp(-t*(24+v))
        y = np.sin(2*np.pi*np.cumsum(f)/SR)*np.exp(-t*(7+v*.45))
        y += .14*bright_noise(t)*np.exp(-t*180)
    elif category == 'snare':
        y = .7*bright_noise(t)*np.exp(-t*(14+v))
        y += .45*np.sin(2*np.pi*(165+v*11)*t)*np.exp(-t*28)
    elif category == 'clap':
        env = np.zeros(len(t))
        for start in [0,.009,.020]: env += np.where(t >= start, np.exp(-np.maximum(t-start,0)*150),0)
        env += .35*np.where(t>.027,np.exp(-np.maximum(t-.027,0)*(17+v)),0)
        y = bright_noise(t)*env
    elif category in ['hat','openhat','shaker','cymbal']:
        decay = {'hat':70,'openhat':9,'shaker':30,'cymbal':3}[category]
        y = .65*bright_noise(t)
        for f in [3217,4211,5911,7133,8231]: y += .08*np.sin(2*np.pi*(f+v*21)*t)
        y *= np.exp(-t*decay*(.85+v*.04))
    elif category in ['rim','perc']:
        y = (np.sin(2*np.pi*(410+v*40)*t)+.5*np.sin(2*np.pi*(1030+v*57)*t))*np.exp(-t*(38 if category=='rim' else 16))
        y += .15*bright_noise(t)*np.exp(-t*120)
    elif category in ['keys','synth','bass','808']:
        y = tone(60 if category in ['keys','synth'] else 36,duration,'piano' if category=='keys' else category,v)
    elif category == 'vocal':
        # Synthetic vowel, not a recording or imitation of a person.
        f0=130+v*8
        y=np.zeros(len(t))
        for h in range(1,65):
            f=f0*h
            if f > SR*.45:break
            a=sum(np.exp(-((f-c)/w)**2) for c,w in [(650+v*20,130),(1100+v*50,180),(2500,250)])
            y += a*np.sin(2*np.pi*f*t)/h
        y *= (1-np.exp(-t*100))*np.exp(-t*5)
    elif category=='texture':
        n=noise(t); y=np.convolve(n,np.ones(45+v*8)/(45+v*8),mode='same')
        y *= np.sin(np.pi*t/duration)**2
    else:
        f=(240+v*70)*np.exp(t*.7)
        y=(np.sin(2*np.pi*np.cumsum(f)/SR)+.15*bright_noise(t))*np.sin(np.pi*t/duration)**2
    y[:88] *= np.linspace(0,1,min(88,len(y)))
    y[-441:] *= np.linspace(1,0,441)
    return y

def write_audio(path,y,peak=.78):
    path.parent.mkdir(parents=True,exist_ok=True)
    y=y-np.mean(y,axis=0)
    y=y*peak/max(float(np.max(np.abs(y))),.001)
    pcm=np.round(np.clip(y,-1,1)*32767).astype('<i2')
    with wave.open(str(path),'wb') as w:
        w.setnchannels(1 if pcm.ndim==1 else pcm.shape[1]);w.setsampwidth(2);w.setframerate(SR);w.writeframes(pcm.tobytes())
    return {'frames':len(y),'peak':float(np.max(np.abs(pcm))/32767),'rms':float(np.sqrt(np.mean((pcm.astype(float)/32767)**2)))}

def place(out, sound, seconds, gain=1):
    start=round(seconds*SR)
    # Wrap note tails around the loop boundary to preserve cyclic continuity.
    idx=(np.arange(len(sound))+start)%len(out)
    np.add.at(out,idx,sound*gain)

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('output',type=Path);args=p.parse_args()
    root=args.output.resolve();root.mkdir(parents=True,exist_ok=True)
    shots=[];loops=[];measurements={};categories=['kick','snare','clap','hat','openhat','rim','perc','shaker','cymbal','808','bass','fx','vocal','texture','keys','synth']
    for cat in categories:
        for v in range(8):
            ident=f'OR_{cat.upper()}_{v+1:02d}';file=f'oneshots/{cat}/{ident}.wav';y=shot(cat,v)
            measurements[file]=write_audio(root/file,y)
            scores={s:.5 for s in STYLES};scores['house']=.9 if cat not in ['808','texture'] else .35
            entry=dict(id=ident,file=file,name=f'{cat.upper()} {v+1:02d}',category=cat,styles=scores,tags=['original','synthesized'],brightness=.3+v*.07,punch=.9 if cat in ['kick','snare','clap'] else .5,dust=.1,decaySec=len(y)/SR,durationSec=len(y)/SR,source='CRATE Original v1 · procedural synthesis')
            if cat in ['808','bass','keys','synth']:entry.update(rootNote=60 if cat in ['keys','synth'] else 36,key='C')
            shots.append(entry)
    chords=[[0,4,7,11],[9,12,16,19],[5,9,12,16],[7,11,14,17]]
    instruments=['piano','rhodes','guitar','pad','strings','synth','bass']
    for inst in instruments:
        for v in range(8):
            house=v<4;bpm=[120,124,126,128,82,88,92,100][v];shift=[0,2,5,7,0,3,5,9][v]
            key=['C','D','F','G','C','Eb','F','A'][v];beat=60/bpm;seconds=16*beat
            y=np.zeros(round(seconds*SR));onsets=[]
            for bar,c in enumerate(chords):
                notes=[48+shift+n for n in c]
                positions=([0,1.5,2.5,3.5] if house else [0,1.75,3])
                if inst in ['pad','strings']:positions=[0]
                for pos in positions:
                    at=(bar*4+pos)*beat;onsets.append(at)
                    if inst=='bass': selected=[notes[0]-12];duration=beat*.65
                    else:selected=notes;duration=beat*(4.4 if inst in ['pad','strings'] else 1.6)
                    for ni,note in enumerate(selected):place(y,tone(note,duration,inst,v),at+ni*.003,.20 if inst!='bass' else .7)
                if inst in ['piano','rhodes','guitar','synth']:
                    place(y,tone(notes[(bar+v)%4]+12,beat*.6,inst,v),(bar*4+3.25)*beat,.09)
            # Small cyclic stereo reflections, kept quiet enough for chopping.
            left=y+.10*np.roll(y,round(.037*SR));right=y+.10*np.roll(y,round(.053*SR))
            audio=np.stack([left,right],axis=1)
            ident=f'OR_{inst.upper()}_{v+1:02d}';file=f'loops/{inst}/{ident}.wav'
            measurements[file]=write_audio(root/file,audio,.70)
            scores={s:(.25 if house else .75) for s in STYLES};scores['house']=.97 if house else .3
            loops.append(dict(id=ident,file=file,name=f'{"HOUSE" if house else "LATE"} {inst.upper()} {v+1:02d}',instrument=inst,bpm=bpm,bars=4,beatsPerBar=4,durationSec=len(y)/SR,key=key,keyConfidence=1,beatsSec=[i*beat for i in range(16)],onsetsSec=onsets,slices16Sec=[i*beat for i in range(16)],chordsPerBar=[key+'maj7',['Am7','Bm7','Dm7','Em7','Am7','Cm7','Dm7','F#m7'][v],['Fmaj7','Gmaj7','Bbmaj7','Cmaj7','Fmaj7','Abmaj7','Bbmaj7','Dmaj7'][v],['G7','A7','C7','D7','G7','Bb7','C7','E7'][v]],bassPerBeat=[(48+shift+chords[b//4][0])-12 for b in range(16)],styles=scores,moods=['warm','uplifting' if house else 'mellow'],brightness=.65 if house else .4,dust=.1,source='CRATE Original v1 · procedural synthesis'))
    for name,data in [('oneshots.json',dict(version=1,samples=shots)),('loops.json',dict(version=1,loops=loops))]:
        (root/name).write_text(json.dumps(data,indent=2))
    shutil.copy2(Path(__file__).resolve().parents[1]/'library/grooves.json',root/'grooves.json')
    (root/'PROVENANCE.md').write_text('# CRATE Original v1\n\n128 synthesized one-shots and 56 synthesized loops. All audio generated mathematically by generate_original_library.py; no third-party audio, recordings, or pack inputs. Piano/guitar/strings labels describe synthesized timbres. Groove templates come from the existing CRATE codebase. Seed: 731026. PCM16 WAV, 44.1 kHz.\n')
    (root/'audio-validation.json').write_text(json.dumps(dict(one_shots=len(shots),loops=len(loops),files=measurements),indent=2))
    print(json.dumps(dict(output=str(root),one_shots=len(shots),loops=len(loops),audio_files=len(measurements))))

if __name__=='__main__':main()
