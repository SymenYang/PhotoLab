"""Bounded, geometry-independent Core ML image embedding. Text remains in QwenEngine."""
from collections import OrderedDict
from pathlib import Path
import json
import time
import numpy as np

class CoreMLQwen:
    def __init__(self, directory, model_path, processor):
        self.directory = Path(directory)
        self.metadata = json.loads((self.directory / 'metadata.json').read_text())
        revision = json.loads((Path(model_path) / 'photolab-model.json').read_text())['revision']
        if self.metadata['revision'] != revision or self.metadata['format'] != 'qwen-coreml-padded-v1':
            raise ValueError('Core ML 权重或格式与当前 Qwen 不匹配')
        self.processor = processor
        self.manifest = self.metadata['stages']
        self.constants = np.load(self.directory / 'constants.npz')
        self.contexts = OrderedDict()
        self.models = None
        self.last_seconds = {}

    def load(self):
        if self.models is not None:
            return
        import coremltools as ct
        import sys
        started = time.monotonic()
        # Never use Core ML GPU here: the offline multi-package GPU run was unstable.
        models = [ct.models.MLModel(str(self.directory / (s['name'] + '.mlpackage')),
                                   compute_units=ct.ComputeUnit.CPU_AND_NE) for s in self.manifest]
        self.models = models
        print(f"Qwen Core ML ready: CPU_AND_NE, {len(models)} stages, {time.monotonic()-started:.2f}s", file=sys.stderr, flush=True)

    def prepare(self, image):
        messages = [{'role':'system','content':[{'type':'text','text':"Represent the user's input."}]},
                    {'role':'user','content':[{'type':'image','image':image}]}]
        prompt = self.processor.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
        inputs = self.processor(text=[prompt], images=[image], padding=True, return_tensors='pt')
        grid = tuple(int(x) for x in inputs['image_grid_thw'][0])
        count = grid[0] * grid[1] * grid[2]
        maximum = self.metadata['max_patches']
        if grid[0] != 1 or count > maximum or count % 4:
            raise ValueError('此图片尺寸超出 Core ML 输入上限')
        key = (grid, tuple(inputs['input_ids'][0].tolist()))
        if key not in self.contexts:
            self.contexts[key] = self._geometry(inputs, grid)
            while len(self.contexts) > 8:
                self.contexts.popitem(last=False)
        self.contexts.move_to_end(key)
        context = dict(self.contexts[key])
        pixels = np.zeros((maximum, 1536), dtype=np.float32)
        pixels[:count] = inputs['pixel_values'].numpy()
        context['pixels'] = pixels
        return context

    def _geometry(self, inputs, grid):
        import torch
        from types import SimpleNamespace
        from transformers.models.qwen3_vl.configuration_qwen3_vl import Qwen3VLConfig
        from transformers.models.qwen3_vl.modeling_qwen3_vl import Qwen3VLVisionModel, Qwen3VLVisionRotaryEmbedding, Qwen3VLTextRotaryEmbedding, Qwen3VLModel
        config = Qwen3VLConfig.from_dict(self.metadata['config'])
        maximum = self.metadata['max_patches']; length = self.metadata['max_text']
        count = int(np.prod(grid)); visual = count // 4
        grid_tensor = inputs['image_grid_thw']
        holder = SimpleNamespace(pos_embed=torch.nn.Embedding.from_pretrained(torch.from_numpy(self.constants['position'].copy())),
                                 num_grid_per_side=48, config=config.vision_config, spatial_merge_size=2,
                                 rotary_pos_emb=Qwen3VLVisionRotaryEmbedding(32))
        with torch.inference_mode():
            learned = Qwen3VLVisionModel.fast_pos_embed_interpolate(holder, grid_tensor).numpy()
            rotary = Qwen3VLVisionModel.rot_pos_emb(holder, grid_tensor)
            emb = torch.cat((rotary,rotary),-1)
            positions,_ = Qwen3VLModel.get_rope_index(SimpleNamespace(config=config), inputs['input_ids'],grid_tensor,attention_mask=inputs['attention_mask'])
            cos,sin = Qwen3VLTextRotaryEmbedding(config.text_config)(torch.zeros(1,1,2048),positions)
        actual = inputs['input_ids'].shape[1]
        ids = inputs['input_ids'][0].numpy(); starts = np.flatnonzero(ids == config.image_token_id)
        start = int(starts[0]); end = int(starts[-1])+1
        if actual > length or end-start != visual or start != self.metadata['visual_start']:
            raise ValueError('Core ML 输入模板不匹配')
        prefix = self.constants['prefix_ids']; suffix = self.constants['suffix_ids']
        if not np.array_equal(ids[:start],prefix) or not np.array_equal(ids[end:],suffix):
            raise ValueError('Core ML 输入模板发生变化')
        position = np.zeros((maximum,1024),np.float32);position[:count]=learned
        vcos=np.ones((maximum,64),np.float32);vsin=np.zeros_like(vcos)
        vcos[:count]=emb.cos().numpy();vsin[:count]=emb.sin().numpy()
        vmask=np.zeros((1,1,1,maximum),np.float32);vmask[:,:,:,count:]=-10000
        tcos=np.ones((1,length,128),np.float32);tsin=np.zeros_like(tcos)
        tcos[:,:actual]=cos.numpy();tsin[:,:actual]=sin.numpy()
        tmask=np.triu(np.full((1,1,length,length),-10000,np.float32),k=1);tmask[:,:,:,actual:]=-10000
        last=np.zeros((1,length,1),np.float32);last[:,actual-1]=1
        return dict(position=position,vcos=vcos,vsin=vsin,vmask=vmask,tcos=tcos,tsin=tsin,tmask=tmask,last=last,
                    visual_count=visual,actual=actual)

    def text_context(self, context):
        count = context['visual_count']; start = self.metadata['visual_start']; length = self.metadata['max_text']
        hidden = np.zeros((1,length,2048),np.float32)
        hidden[:,:start] = self.constants['prefix']
        hidden[:,start:start+count] = context['visual'][:count]
        suffix=self.constants['suffix'];hidden[:,start+count:start+count+suffix.shape[1]]=suffix
        context['thidden0']=hidden
        for i in range(3):
            value=np.zeros_like(hidden);value[:,start:start+count]=context[f'deep{i}'][:count]
            context[f'inject{i}']=value

    def predict_context(self, context):
        self.load()
        for stage,model in zip(self.manifest,self.models):
            if stage['name']=='text_0': self.text_context(context)
            outputs=model.predict({key:context[key] for key in stage['inputs']})
            context.update(outputs)
        vector=context['embedding'][0].astype(np.float32)
        norm=float(np.linalg.norm(vector))
        if not np.isfinite(vector).all() or not .9 < norm < 1.1:
            raise ValueError('Core ML 返回无效向量')
        return vector / norm

    def image_vector(self, image):
        self.load()
        start=time.monotonic();context=self.prepare(image);prepared=time.monotonic()
        vector=self.predict_context(context)
        self.last_seconds=dict(preprocess=prepared-start,inference=time.monotonic()-prepared)
        return vector
