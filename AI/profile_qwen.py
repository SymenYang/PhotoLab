"""Short local MPS microbenchmark; pause app indexing first."""
import json,time,statistics
from pathlib import Path
from PIL import Image
from qwen_engine import QwenEngine
from compare_models import thumbnail,DATA
import sqlite3
engine=QwenEngine(str(Path(__file__).resolve().parent.parent/'.ai-model-qwen'),'/private/tmp/photolab-qwen-profile.sqlite')
engine.load();torch=engine.torch
assets=[json.loads(r[0]) for r in sqlite3.connect(f'file:{DATA}/catalog.sqlite?mode=ro',uri=True).execute('select data from assets')]
images=[]
for a in assets:
 if not a['video']:
  im=thumbnail(a)
  if im:
   scale=512/max(im.size);images.append(im.resize((round(im.width*scale),round(im.height*scale))))
 if len(images)==8:break
results=[]
for size in [1,2,4,8]:
 prompts=[engine.processor.apply_chat_template([{'role':'system','content':[{'type':'text','text':"Represent the user's input."}]},{'role':'user','content':[{'type':'image','image':im}]}],tokenize=False,add_generation_prompt=True) for im in images[:size]]
 measurements=[]
 for rep in range(4):
  start=time.monotonic()
  inputs=engine.processor(text=prompts,images=images[:size],padding=True,return_tensors='pt').to(engine.device)
  torch.mps.synchronize(); prepared=time.monotonic()
  with torch.inference_mode():
   h=engine.model(**inputs,use_cache=False).last_hidden_state
   last=inputs['attention_mask'].shape[1]-1-inputs['attention_mask'].flip(1).argmax(1)
   v=torch.nn.functional.normalize(h[torch.arange(size,device=engine.device),last].float(),dim=-1).cpu().numpy()
  torch.mps.synchronize();done=time.monotonic()
  if rep:measurements.append({'preprocess':prepared-start,'model':done-prepared,'total':done-start})
 result={'batch':size,**{key:statistics.median(x[key] for x in measurements) for key in ['preprocess','model','total']}}
 result['seconds_per_image']=result['total']/size
 result['driver_allocated_GiB']=torch.mps.driver_allocated_memory()/1024**3
 results.append(result);print(json.dumps(result),flush=True)
Path('build/reports/qwen-comparison').mkdir(parents=True, exist_ok=True)
Path('build/reports/qwen-comparison/profile.json').write_text(json.dumps(results,indent=2))
