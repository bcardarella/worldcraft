#!/usr/bin/env python3
"""Author original 48 kHz music/effects offline. Requires Swift and ffmpeg.
No downloaded recordings, soundfonts, API calls, or paid generation services.
The runtime manifest is the single source of truth for files and durations.
"""
import argparse, concurrent.futures, hashlib, json, math, random, shutil, subprocess
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
TMP=ROOT/"tmp/scratch/audio-expansion-2026-10-03"
OUT=ROOT/"Resources"
TMP.mkdir(parents=True,exist_ok=True)
THEMES={
 "meadow": (74,["piano","felt","flute"], ["Little Footpaths","The Afternoon Garden","Where the Light Lands"]),
 "forest": (70,["harp","piano","pad"], ["Between the Branches","Fernlight","Old Woodland Letters"]),
 "coast": (78,["vibes","felt","pluck"], ["Seaglass","The Tidal Almanac","Small Boats at Dawn"]),
 "desert": (72,["pluck","flute","piano"], ["Amber Horizons","A Well in the Sand","The Long Caravan"]),
 "snow": (64,["bell","felt","strings"], ["Snow on the Windowsill","A Blue Quiet","Winter Lanterns"]),
 "town": (86,["piano","pluck","strings"], ["Market Day","Windows Above the Square","Home by Lamplight"]),
 "night": (60,["felt","bell","pad"], ["When the World Sleeps","Paper Constellations","Midnight Orchard"]),
 "cave": (62,["vibes","pad","felt"], ["Stone Remembers","The Hidden Chamber","Below the Roots"]),
 "underwater": (66,["vibes","harp","pad"], ["Aqua Gardens","Pearl Windows","The Slow Blue Waltz"]),
 "space": (58,["pad","bell","felt"], ["A Thousand Distant Homes","Orbiting Quietly","Messages in Starlight"]),
 "lava": (68,["strings","felt","bell"], ["The Ember Court","Gold Beneath the Ash","A Hearth Among Suns"]),
 "race": (112,["piano","bass","pluck"], ["Sunlit Circuit","The Coastal Sprint","Last Lap Home"]),
 "castle": (76,["harp","bell","strings"], ["Hay Hay's Hiding Place","The Winding Stair","A Friend in the Tower"]),
}
SCALES=[[0,2,4,7,9,12,14,16],[0,2,3,5,7,9,10,12],[0,2,4,5,7,9,11,12]]
PROGRESSIONS=[[0,5,3,4,0,2,3,4],[0,3,5,4,1,3,0,4],[0,4,5,2,3,0,1,4]]
MOTIFS=[[0,2,4,2,1,0,3,2],[4,3,1,2,0,2,1,0],[0,1,3,4,2,1,4,3],
        [2,0,1,4,3,2,0,1],[0,3,2,1,4,2,3,0],[4,2,3,1,0,2,4,1]]
renders=[]; tracks=[]; effects=[]

def note(t,length,pitch,gain,pan,voice):
 return dict(t=round(t,5),length=round(length,5),pitch=pitch,gain=gain,pan=pan,voice=voice)

def music():
 for mi,(mood,(tempo,voices,titles)) in enumerate(THEMES.items()):
  for v,title in enumerate(titles):
   seed=8401+mi*991+v*1103; rng=random.Random(seed)
   bpm=tempo+[-4,0,4][v]; beats=3 if v==2 and mood!="race" else 4
   bars=32 if beats==3 or mood=="race" else 24
   beat=60/bpm; duration=bars*beats*beat
   ident=f"music_{mood}_{v+1:02d}"; events=[]
   minor=mood in ("cave","lava","space","night")
   scale=[0,2,3,5,7,8,10] if minor else [0,2,4,5,7,9,11]
   transpose=[0,5,7,2,0,-3,0,2,5,0,-3,0,7][mi] + [0,0,2][v]
   progression=PROGRESSIONS[(v+mi)%3]; motif=MOTIFS[(mi*2+v)%len(MOTIFS)]
   def pitch(degree,octave=4):
    return (octave+1)*12+transpose+scale[degree%7]+12*(degree//7)
   for bar in range(bars):
    root=progression[(bar+(8 if bar>=bars//2 else 0))%8]
    section=bar//8
    down=bar*beats*beat
    # Voiced triads/sevenths, a quiet bass foundation and phrase-dependent density.
    harmony=[pitch(root-7,4),pitch(root+2-7,4),pitch(root+4-7,4)]
    for j,p in enumerate(harmony):
     events.append(note(down+0.02*j,beats*beat+1.3,p,0.035 if mood!="race" else 0.022,
       0.25+j*0.25,"pad" if mood in ("space","night","underwater","cave") else "strings"))
    events.append(note(down+0.04,beats*beat*0.88,pitch(root,2),0.07,0.48,"bass"))
    lead=voices[(v+section//2)%len(voices)]
    steps=beats*(2 if mood in ("race","town") else 1)
    for k in range(steps):
     if mood!="race" and rng.random() < (0.38 if section%3==0 else 0.18): continue
     index=(motif[(k+bar*2+section)%8]+root)%7
     if bar%8==7: index=root%7
     p=pitch(index,4 if mood not in ("snow","castle") else 5)
     if section==1 and k%3==0: p+=12
     on=down+(k+0.25)*beats*beat/steps+rng.uniform(-0.015,0.015)
     length=min(duration-on+3,beat*(1.8 if lead in ("piano","felt","bell","harp","vibes") else 1.1))
     events.append(note(on,length,p,0.09+rng.random()*0.025,0.28+rng.random()*0.44,lead))
    # A contrasting answering voice enters after eight bars, then rests.
    if section%3==1 and bar%2==1:
     for j,degree in enumerate([root+4,root+2,root]):
      events.append(note(down+(j+0.3)*beat,beat*1.6,pitch(degree,4),0.045,0.68,voices[(v+1)%3]))
    if mood=="race":
     for k in range(beats):
      events.append(note(down+k*beat,0.32,36,0.095,0.5,"kick" if k%2==0 else "snare"))
      for sub in (0,0.5): events.append(note(down+(k+sub)*beat,0.1,88,0.021,0.55,"hat"))
     for k in range(beats*2):
      events.append(note(down+k*beat/2,beat*0.45,pitch(root+(4 if k%2 else 0),2),0.06,0.5,"bass"))
    elif mood=="town" and section>0:
     for k in range(beats): events.append(note(down+(k+0.5)*beat,0.12,74,0.009,0.7,"hat"))
   renders.append(dict(id=ident,seconds=duration,stereo=True,loop=True,room=.55 if mood in ("cave","space","castle") else .30,seed=seed,notes=events))
   tracks.append(dict(id=ident,title=title,mood=mood,duration=duration,bpm=bpm,file=ident+".m4a"))

def effect(event,variants=3,duration=.65,loop=False,gain=-5,recipe=None,room=.05):
 for variant in range(1,variants+1):
  ident=f"fx_{event}_{variant:02d}"
  seed=int(hashlib.sha256(ident.encode()).hexdigest()[:12],16); rng=random.Random(seed)
  events=recipe(rng,duration,variant) if recipe else [note(0,duration,48+rng.random()*5,.6,0,"impact")]
  renders.append(dict(id=ident,seconds=duration,stereo=False,loop=loop,room=room,seed=seed,notes=events))
  effects.append(dict(event=event,file=ident+".wav",duration=duration,loop=loop,gain=gain))

def foley(surface,action):
 def recipe(r,d,v):
  pitch={"grass":45,"dirt":43,"sand":51,"snow":46,"wood":55,"stone":64,"glass":93,"foliage":65}[surface]+r.uniform(-2,2)
  noise={"sand":"sand","snow":"snow","foliage":"rustle","grass":"rustle"}.get(surface,"noise")
  many=action=="break"; hits=7 if many else 3 if action=="step" else 2
  result=[]
  for i in range(hits):
   t=i*(.047 if many else .031)+r.uniform(0,.009)
   result.append(note(t,min(d-t,.24 if not many else .4),pitch,0.25/(1+i*.32),0,
    "vibes" if surface=="glass" else "impact"))
   result.append(note(t,min(d-t,.2 if not many else .34),pitch,0.3/(1+i*.23),0,noise))
  return result
 return recipe

def sfx():
 for surface in ["grass","dirt","sand","snow","wood","stone","glass","foliage"]:
  for action in ["step","hit","break","place"]:
   effect(f"{action}_{surface}",4,.8 if action=="break" else .38,gain=-8 if action=="step" else -6,recipe=foley(surface,action))
 animals={
  "sheep":("voice",59,.85),"fox":("voice",79,.45),"deer":("voice",47,1.1),
  "rabbit":("breath",78,.48),"cow":("voice",40,1.6),"pig":("voice",54,.6),
  "horse":("voice",69,1.5),"goat":("voice",64,.9),"wolf":("voice",53,2.3),
  "bear":("growl",38,1.45),"chicken":("voice",78,.6),"duck":("voice",68,.7),
  "frog":("voice",52,.6),"parrot":("chirp",86,.6),"zebra":("voice",65,1.3),
  "camel":("growl",46,1.3),"penguin":("voice",72,1.0),"fish":("bubble",65,.45),
  "panda":("breath",51,.85),"elephant":("voice",49,2.1),"giraffe":("breath",44,1.2),
  "tortoise":("rustle",42,.5),"otter":("chirp",81,.7),"boar":("growl",49,.8),
  "dog_bark":("voice",60,.65),"hay_hay":("bell",81,1.0),
  "rex_roar":("growl",31,3.0),"raptor_call":("voice",62,1.4),
  "triceratops":("voice",38,2.0),"stegosaurus":("voice",45,1.9),
  "ankylosaurus":("growl",39,1.4),"brachiosaurus":("voice",29,3.5),
  "parasaurolophus":("voice",53,2.3),"spinosaurus":("growl",35,2.8),
  "colossal_roar":("growl",22,5.5),"dinosaur_call":("voice",40,2.0)}
 for name,(voice,pitch,duration) in animals.items():
  def recipe(r,d,v,voice=voice,pitch=pitch,name=name):
   result=[]
   pulses=2 if name in ("dog_bark","chicken","duck","pig","frog","raptor_call") else 1
   for i in range(pulses):
    length=d/pulses*.72
    result.append(note(.05+i*d/pulses,length,pitch+r.uniform(-1.7,1.7),.65,0,voice))
    if voice in ("voice","growl"):
     result.append(note(.04+i*d/pulses,length*.8,pitch+12,.12,0,"breath"))
   return result
  effect(name,3,duration+.25,gain=-7 if name in ("rabbit","fish","tortoise","giraffe") else -3,recipe=recipe,room=.10)
 for name,voice,gain in [("wind","wind",-22),("rain","rain",-21),("river","river",-16),("ocean","ocean",-18),
    ("fire","fire",-20),("lake","lake",-23),("lava","lava",-18),("underwater","underwater",-22),("cave","cave",-25),("car_engine","engine",-18),
    ("race_engine","engine",-19),("rocket_engine","engine",-24)]:
  def recipe(r,d,v,voice=voice,name=name):
   notes=[note(0,d,31 if name=="car_engine" else 38 if name=="race_engine" else 22,.5,0,voice)]
   if name in ("river","underwater","lava"):
    for _ in range(18):
     t=r.uniform(0,d-.7); notes.append(note(t,.2+r.random()*.45,50+r.random()*28,.02,0,"bubble"))
   if name=="rocket_engine": notes.append(note(0,d,15,.8,0,"wind"))
   return notes
  effect(name,1,18,True,gain,recipe,0)
 for event,voice in [("birds","chirp"),("crickets","chirp"),("town","voice")]:
  def recipe(r,d,v,event=event,voice=voice):
   n=32 if event=="town" else 23 if event=="crickets" else 16
   return [note(r.uniform(0,d-1),r.uniform(.06,.22) if event!="town" else r.uniform(.2,.7),
    r.uniform(100,110) if event=="crickets" else r.uniform(87,103) if event=="birds" else r.uniform(45,69),
    .08 if event=="town" else .16,0,voice) for _ in range(n)]
  effect(event,2,20,True,-23 if event=="town" else -19,recipe,.13)
 for name in ["splash","swim","water_exit","drink"]:
  def recipe(r,d,v,name=name):
   result=[note(0,d,42,.35,0,"noise")]
   for i in range(12):
    result.append(note(r.uniform(0,d*.65),d*.3,r.uniform(45,85),.12,0,"bubble"))
   return result
  effect(name,4,1.1 if name=="splash" else .7,gain=-8,recipe=recipe)
 for name in ["pickup","inventory_open","inventory_close","inventory_move","inventory_select","hotbar","feed","pet","jump",
    "land","flight_start","flight_stop","car_door","car_start","car_stop","car_skid","car_bump","car_horn","building_door","door_scratch","rex_chomp",
    "npc_talk","npc_work","npc_cheer","rocket_door","rocket_arrival","countdown","lap"]:
  def recipe(r,d,v,name=name):
   if name in ("pickup","inventory_select","lap","rocket_arrival"):
    return [note(i*.09,d-i*.09,p,.12,0,"bell") for i,p in enumerate([76,83,88] if name!="lap" else [72,76,79,84])]
   if name in ("inventory_open","inventory_close","inventory_move","hotbar"):
    return [note(0,.15,65 if name!="inventory_close" else 58,.16,0,"pluck"),note(.02,.2,55,.15,0,"rustle")]
   if name=="countdown": return [note(0,.22,81,.13,0,"vibes")]
   if name in ("npc_talk","npc_cheer"):
    return [note(i*.15,.24,55+(i%3)*4+r.uniform(-3,3),.3,0,"voice") for i in range(5)]
   if name in ("feed","pet"): return [note(0,.2,56,.26,0,"rustle"),note(.12,.45,76,.08,0,"vibes")]
   if name in ("flight_start","flight_stop","jump"):
    return [note(0,d,72,.5,0,"wind"),note(0,d,60 if name!="flight_stop" else 48,.1,0,"vibes")]
   if name in ("car_start","car_stop"): return [note(0,d,30,.4,0,"engine"),note(0,.2,58,.25,0,"impact")]
   if name=="door_scratch": return [note(i*.15,.12,65+i*3,.22,0,"rustle") for i in range(4)]
   if name=="building_door": return [note(0,.5,43,.15,0,"voice"),note(.48,.16,50,.22,0,"impact")]
   if name=="car_horn": return [note(0,.55,67,.28,0,"horn"),note(.006,.55,71,.21,0,"horn")]
   if name=="car_skid": return [note(0,d,88,.18,0,"voice"),note(0,d,60,.55,0,"sand")]
   if name=="rocket_door": return [note(0,d,62,.6,0,"wind"),note(d*.7,.22,59,.28,0,"impact")]
   return [note(0,.25,43,.55,0,"impact"),note(.04,d-.04,55,.45,0,"rustle")]
  effect(name,3,1.4 if name in ("rocket_arrival","npc_talk","npc_cheer","lap","car_start") else .75,
    gain=-12 if name.startswith("inventory") or name in ("hotbar","pickup") else -7,recipe=recipe,room=.08)
 def thunder(r,d,v):
  return [note(0,d,22,.7,0,"growl"),note(0,d,30,1,0,"wind"),note(.03,.5,31,.8,0,"impact")]
 effect("thunder",3,6,gain=-10,recipe=thunder,room=.7)

def run():
 parser=argparse.ArgumentParser()
 parser.add_argument("--effects-only",action="store_true")
 parser.add_argument("--music-only",action="store_true")
 args=parser.parse_args()
 if not args.effects_only: music()
 if not args.music_only: sfx()
 specs=TMP/"renders.json"; specs.write_text(json.dumps(renders))
 renderer=TMP/"render-audio"
 subprocess.run(["swiftc","-O","-parse-as-library","-module-cache-path",str(ROOT/"tmp/swift-module-cache"),str(ROOT/"Tools/RenderAudio.swift"),"-o",str(renderer)],check=True)
 subprocess.run([str(renderer),str(specs),str(TMP/"rendered")],check=True)
 ffmpeg=shutil.which("ffmpeg")
 if not ffmpeg: raise SystemExit("ffmpeg is required for offline AAC mastering.")
 def master(render):
  source=TMP/"rendered"/(render["id"]+".wav")
  destination=OUT/(render["id"]+(".m4a" if render["stereo"] else ".wav"))
  if render["stereo"]:
   subprocess.run([ffmpeg,"-hide_banner","-loglevel","error","-y","-i",str(source),
    "-af","loudnorm=I=-22:TP=-2:LRA=9","-ar","48000","-c:a","aac","-b:a","192k",str(destination)],check=True)
  else:
   shutil.copyfile(source,destination)
 with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool: list(pool.map(master,renders))
 manifest=OUT/"AudioLibrary.json"
 previous=json.loads(manifest.read_text()) if manifest.exists() else {}
 manifest.write_text(json.dumps(dict(version=1,tracks=tracks or previous.get("tracks",[]),
   effects=effects or previous.get("effects",[])),indent=2)+"\n")
 print(f"Authored {len(tracks)} tracks ({sum(t['duration'] for t in tracks)/60:.1f} minutes), {len(effects)} effect takes.")
if __name__=="__main__": run()
