"""Convert original Qwen weights to a fixed upper-bound, masked image embedding graph."""
import os
os.environ.update(HF_HUB_OFFLINE='1',TRANSFORMERS_OFFLINE='1',TOKENIZERS_PARALLELISM='false')
import argparse,gc,json,sys
from pathlib import Path
import numpy as np
import torch
from torch import nn
import coremltools as ct
from transformers import AutoProcessor
from transformers.models.qwen3_vl.modeling_qwen3_vl import Qwen3VLPreTrainedModel,Qwen3VLModel,apply_rotary_pos_emb_vision
from PIL import Image
from qwen_coreml import CoreMLQwen

class Model(Qwen3VLPreTrainedModel):
    _checkpoint_conversion_mapping={}
    def __init__(self,config):super().__init__(config);self.model=Qwen3VLModel(config);self.post_init()
class Patch(nn.Module):
    def __init__(self,v):
        super().__init__();p=v.patch_embed.proj
        self.projection=nn.Linear(p.weight[0].numel(),p.weight.shape[0],bias=True)
        self.projection.weight=nn.Parameter(p.weight.flatten(1));self.projection.bias=p.bias
    def forward(self,pixels,position):return self.projection(pixels)+position
class VisionGroup(nn.Module):
    def __init__(self,v,start,end):
        super().__init__();self.layers=nn.ModuleList(v.blocks[start:end]);self.merger=v.merger if end==24 else v.deepstack_merger_list[end//6-1]
    def forward(self,hidden,vcos,vsin,vmask):
        for block in self.layers:
            x=block.norm1(hidden);attn=block.attn
            q,k,v=attn.qkv(x).reshape(x.shape[0],3,attn.num_heads,-1).permute(1,0,2,3).unbind(0)
            q,k=apply_rotary_pos_emb_vision(q,k,vcos,vsin)
            q=q.transpose(0,1).unsqueeze(0);k=k.transpose(0,1).unsqueeze(0);v=v.transpose(0,1).unsqueeze(0)
            weights=torch.softmax((q@k.transpose(-1,-2))*attn.scaling+vmask,dim=-1,dtype=torch.float32).to(q.dtype)
            output=(weights@v).transpose(1,2).reshape(hidden.shape[0],-1)
            hidden=hidden+attn.proj(output);hidden=hidden+block.mlp(block.norm2(hidden))
        return hidden,self.merger(hidden)
class TextGroup(nn.Module):
    def __init__(self,t,start,end):
        super().__init__();self.layers=nn.ModuleList(t.layers[start:end]);self.first=start==0;self.last=end==28
        self.norm=t.norm if self.last else nn.Identity()
    def forward(self,hidden,tcos,tsin,tmask,last,*deep):
        for i,layer in enumerate(self.layers):
            hidden=layer(hidden,position_embeddings=(tcos,tsin),attention_mask=tmask,use_cache=False)
            if self.first and i<3:hidden=hidden+deep[i]
        if self.last:
            out=(self.norm(hidden)*last).sum(dim=1).float()
            return out/out.norm(dim=-1,keepdim=True).clamp(min=1e-12)
        # Unused pooling inputs are harmless for intermediate decoder groups.
        return hidden

def main():
    p=argparse.ArgumentParser();p.add_argument('--model',default='.ai-model-qwen');p.add_argument('--output',default='.ai-model-qwen-coreml-staging');a=p.parse_args()
    output=Path(a.output);output.mkdir(parents=True,exist_ok=True)
    torch.set_num_threads(2);torch.set_grad_enabled(False)
    processor=AutoProcessor.from_pretrained(a.model,local_files_only=True,use_fast=False,padding_side='right',min_pixels=4096,max_pixels=512*512)
    revision=json.loads((Path(a.model)/'photolab-model.json').read_text())['revision']
    if (output/'metadata.json').exists():
        previous=json.loads((output/'metadata.json').read_text())
        if previous['revision'] != revision or previous['format'] != 'qwen-coreml-padded-v1':
            raise ValueError('Use an empty output directory for a different model revision')
    (output/'READY').unlink(missing_ok=True)
    wrapper,info=Model.from_pretrained(a.model,local_files_only=True,dtype=torch.float32,attn_implementation='eager',output_loading_info=True)
    if info['missing_keys'] or info['mismatched_keys']: raise RuntimeError('Incomplete Qwen weights: '+str(info))
    net=wrapper.eval().model
    image=Image.new('RGB',(512,512),'gray')
    msgs=[{'role':'system','content':[{'type':'text','text':"Represent the user's input."}]},{'role':'user','content':[{'type':'image','image':image}]}]
    prompt=processor.apply_chat_template(msgs,tokenize=False,add_generation_prompt=True)
    inp=processor(text=[prompt],images=[image],padding=True,return_tensors='pt');ids=inp['input_ids'][0];indices=torch.where(ids==net.config.image_token_id)[0];start=int(indices[0]);end=int(indices[-1])+1
    emb=net.language_model.embed_tokens(inp['input_ids']).detach().numpy()
    np.savez(output/'constants.npz',position=net.visual.pos_embed.weight.detach().numpy(),prefix=emb[:,:start],suffix=emb[:,end:],prefix_ids=ids[:start].numpy(),suffix_ids=ids[end:].numpy())
    stages=[('vision_start',Patch(net.visual),['pixels','position'],['vhidden0'])]
    for i in range(4):stages.append((f'vision_{i}',VisionGroup(net.visual,i*6,(i+1)*6),[f'vhidden{i}','vcos','vsin','vmask'],[f'vhidden{i+1}',f'deep{i}' if i<3 else 'visual']))
    for i in range(7):stages.append((f'text_{i}',TextGroup(net.language_model,i*4,(i+1)*4),[f'thidden{i}','tcos','tsin','tmask','last']+(['inject0','inject1','inject2'] if i==0 else []),['embedding' if i==6 else f'thidden{i+1}']))
    metadata=dict(format='qwen-coreml-padded-v1',revision=json.loads((Path(a.model)/'photolab-model.json').read_text())['revision'],max_patches=1024,max_text=len(ids),visual_start=start,config=net.config.to_dict(),stages=[dict(name=n,inputs=ins,outputs=outs) for n,_,ins,outs in stages])
    (output/'metadata.json').write_text(json.dumps(metadata))
    runtime=CoreMLQwen(output,a.model,processor);context=runtime.prepare(image)
    context={k:torch.from_numpy(v) if isinstance(v,np.ndarray) else v for k,v in context.items()}
    for name,stage,ins,outs in stages:
        if name=='text_0':
            temp={k:v.numpy() if isinstance(v,torch.Tensor) else v for k,v in context.items()};runtime.text_context(temp)
            context.update({k:torch.from_numpy(temp[k]) for k in ['thidden0','inject0','inject1','inject2']})
        stage.eval();values=tuple(context[k] for k in ins);result=stage(*values);result=result if isinstance(result,tuple) else (result,);context.update(zip(outs,result))
        package=output/(name+'.mlpackage')
        if not package.exists():
            traced=torch.jit.trace(stage,values,check_trace=False)
            converted=ct.convert(traced,convert_to='mlprogram',minimum_deployment_target=ct.target.macOS15,compute_precision=ct.precision.FLOAT16,
                                 inputs=[ct.TensorType(name=k,shape=tuple(v.shape),dtype=np.float32) for k,v in zip(ins,values)],outputs=[ct.TensorType(name=k,dtype=np.float32) for k in outs],skip_model_load=True)
            converted.save(str(package));del converted,traced;gc.collect()
        print(json.dumps({'converted':name}),flush=True)
    reference=net(**inp,use_cache=False).last_hidden_state[:,-1];reference=reference/reference.norm(dim=-1,keepdim=True)
    delta=float((reference-context['embedding']).abs().max());cos=float((reference*context['embedding']).sum())
    print(json.dumps({'reference_cosine':cos,'max_delta':delta}),flush=True)
    assert cos>.9999
    (output/'READY').write_text(metadata['revision'])
if __name__=='__main__':main()
