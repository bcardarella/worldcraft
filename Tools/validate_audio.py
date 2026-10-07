#!/usr/bin/env python3
"""Verify the shipped audio manifest, channel layout, loops, and unclipped audio.
Requires ffprobe/ffmpeg for the compressed soundtrack. No audio playback occurs.
"""
from array import array
from concurrent.futures import ThreadPoolExecutor
import json, math, re, subprocess, wave
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
RES=ROOT/'Resources'
library=json.loads((RES/'AudioLibrary.json').read_text())
tracks=library['tracks']; effects=library['effects']
assert len(tracks)>=39 and len({t['mood'] for t in tracks})==13
assert len({a['file'] for a in tracks+effects})==len(tracks)+len(effects)
max_peak=0; max_seam=0
for asset in effects:
 with wave.open(str(RES/asset['file']),'rb') as wav:
  assert (wav.getnchannels(),wav.getsampwidth(),wav.getframerate())==(1,2,48000),asset['file']
  assert abs(wav.getnframes()/48000-asset['duration'])<0.002,asset['file']
  samples=array('h',wav.readframes(wav.getnframes()))
  peak=max(abs(s) for s in samples)/32768
  assert 0.0001<peak<0.99,(asset['file'],peak)
  max_peak=max(max_peak,peak)
  if asset['loop']:
   seam=abs(samples[-1]-samples[0])/32768
   assert seam<0.02,(asset['file'],seam)
   max_seam=max(max_seam,seam)

def track_check(asset):
 source=str(RES/asset['file'])
 info=json.loads(subprocess.check_output(['ffprobe','-v','error','-show_streams','-of','json',source]))['streams'][0]
 assert int(info['sample_rate'])==48000 and info['channels']==2,asset['file']
 assert abs(float(info['duration'])-asset['duration'])<0.12,asset['file']
 result=subprocess.run(['ffmpeg','-hide_banner','-nostats','-i',source,'-af','astats=metadata=0:reset=0','-f','null','-'],capture_output=True,text=True,check=True)
 peaks=[float(p) for p in re.findall(r'Peak level dB: ([\d.\-]+)',result.stderr)]
 assert peaks and all(math.isfinite(p) and -50<p<0 for p in peaks),(asset['file'],peaks)
 return max(peaks)
with ThreadPoolExecutor(max_workers=2) as pool: peaks=list(pool.map(track_check,tracks))
print(f"PASS: {len(tracks)} stereo tracks, {sum(t['duration'] for t in tracks)/60:.1f} minutes; {len(effects)} mono effects; all 48 kHz.")
print(f"Max decoded music peak {max(peaks):.2f} dBFS; effect peak {max_peak:.3f}; largest loop seam {max_seam:.5f}.")
