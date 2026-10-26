"""Matched workload check: same two images, batch one vs batch two."""
import json,time,statistics
from pathlib import Path
from qwen_engine import QwenEngine
from compare_models import DATA,thumbnail
import sqlite3
engine=QwenEngine('.ai-model-qwen','/private/tmp/photolab-qwen-profile.sqlite');engine.load();t=engine.torch
images=[]
for row in sqlite3.connect(f'file:{DATA}/catalog.sqlite?mode=ro',uri=True).execute('select data from assets'):
 a=json.loads(row[0])
 if not a['video']:
  im=thumbnail(a)
  if im:
   ratio=512/max(im.size);images.append(im.resize((round(im.width*ratio),round(im.height*ratio))))
 if len(images)==2:break
results=[]
for size in [1,2]:
 times=[]
 for rep in range(3):
  t.mps.synchronize();start=time.monotonic()
  for offset in range(0,2,size):
   batch=images[offset:offset+size]
   prompts=[engine.processor.apply_chat_template([{'role':'system','content':[{'type':'text','text':"Represent the user's input."}]},{'role':'user','content':[{'type':'image','image':im}]}],tokenize=False,add_generation_prompt=True) for im in batch]
   inputs=engine.processor(text=prompts,images=batch,padding=True,return_tensors='pt').to('mps')
   with t.inference_mode():
    hidden=engine.model(**inputs,use_cache=False).last_hidden_state
    last=inputs['attention_mask'].shape[1]-1-inputs['attention_mask'].flip(1).argmax(1)
    v=t.nn.functional.normalize(hidden[t.arange(size,device='mps'),last].float(),dim=-1).cpu().numpy()
  t.mps.synchronize()
  if rep: times.append((time.monotonic()-start)/2)
 result={'batch':size,'same_images':2,'seconds_per_image':statistics.median(times)}
 results.append(result);print(json.dumps(result),flush=True)
Path('build/reports/qwen-comparison').mkdir(parents=True, exist_ok=True)
Path('build/reports/qwen-comparison/profile-matched.json').write_text(json.dumps(results,indent=2))
