"""Qwen3-VL image/text embedding using local Transformers, last-token pooling.
Reference: https://github.com/QwenLM/Qwen3-VL-Embedding
No remote code or network image loaders are used.
"""
from worker import Engine

class QwenEngine(Engine):
    def __init__(self, model_path, database):
        super().__init__(model_path, database)
        import json
        from pathlib import Path
        revision = json.loads((Path(model_path) / 'photolab-model.json').read_text())['revision']
        self.coreml = None
        self.coreml_failed = False
        self.last_image_backend = None
        self.last_image_seconds = {}
        # Preserve the logical embedding identity: the validated FP16 image
        # implementation is compatible with existing BF16 vectors.
        self.key = 'Qwen/Qwen3-VL-Embedding-2B@' + revision + '/imageio-sdr-srgb-512-rotation-v1/qwen-last-token-default-instruction-512-bf16-v1'

    def load(self):
        if self.model is not None:
            return
        import torch
        from transformers import AutoProcessor
        from transformers.models.qwen3_vl.modeling_qwen3_vl import Qwen3VLModel, Qwen3VLPreTrainedModel
        class EmbeddingModel(Qwen3VLPreTrainedModel):
            _checkpoint_conversion_mapping = {}
            def __init__(self, config):
                super().__init__(config)
                self.model = Qwen3VLModel(config)
                self.post_init()
            def forward(self, **inputs):
                return self.model(**inputs)
        torch.set_num_threads(2)
        device = 'mps' if torch.backends.mps.is_available() else 'cpu'
        dtype = torch.bfloat16 if device == 'mps' else torch.float32
        processor = AutoProcessor.from_pretrained(self.model_path, local_files_only=True, use_fast=False, padding_side='right', min_pixels=4096, max_pixels=512*512)
        model, info = EmbeddingModel.from_pretrained(self.model_path, local_files_only=True, dtype=dtype, attn_implementation='sdpa', output_loading_info=True)
        if info['missing_keys'] or info['mismatched_keys']:
            raise RuntimeError('Incomplete Qwen weights: ' + str(info))
        self.model = model.eval().to(device)
        self.processor, self.torch, self.device = processor, torch, device

    def embed(self, text=None, image=None):
        self.load()
        content = [{'type': 'image', 'image': image}] if image is not None else [{'type': 'text', 'text': text}]
        messages = [
            {'role': 'system', 'content': [{'type': 'text', 'text': "Represent the user's input."}]},
            {'role': 'user', 'content': content},
        ]
        prompt = self.processor.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
        inputs = self.processor(text=[prompt], images=[image] if image is not None else None, padding=True, return_tensors='pt')
        if inputs['input_ids'].shape[1] > 2048:
            raise ValueError('描述过长，请缩短后重试。')
        inputs = inputs.to(self.device)
        with self.torch.inference_mode():
            hidden = self.model(**inputs, use_cache=False).last_hidden_state
            last = inputs['attention_mask'].shape[1] - 1 - inputs['attention_mask'].flip(1).argmax(1)
            features = hidden[self.torch.arange(hidden.shape[0], device=self.device), last].float()
            return self.normalize(features)

    def image_vector(self, path):
        import os, sys
        from pathlib import Path
        from PIL import Image
        directory = os.environ.get('PHOTOLAB_QWEN_COREML')
        with Image.open(path) as source:
            image = source.convert('RGB')
        if directory and not self.coreml_failed and os.environ.get('PHOTOLAB_DISABLE_COREML') != '1':
            try:
                if self.coreml is None:
                    if not (Path(directory) / 'READY').is_file():
                        raise ValueError('Core ML 模型未完整安装')
                    import torch
                    from transformers import AutoProcessor
                    from qwen_coreml import CoreMLQwen
                    torch.set_num_threads(2)
                    processor = AutoProcessor.from_pretrained(self.model_path, local_files_only=True, use_fast=False, padding_side='right', min_pixels=4096, max_pixels=512*512)
                    self.coreml = CoreMLQwen(directory, self.model_path, processor)
                vector = self.coreml.image_vector(image)
                self.last_image_backend = 'Core ML · Neural Engine'
                self.last_image_seconds = self.coreml.last_seconds
                return vector
            except Exception as error:
                # Disable for this process, so a damaged package cannot cause
                # repeated reloads. The original MPS implementation remains usable.
                print('Qwen Core ML fallback: ' + repr(error), file=sys.stderr, flush=True)
                self.coreml_failed = True
                self.coreml = None
        vector = self.embed(image=image)
        self.last_image_backend = self.device + (' · Core ML 回退' if self.coreml_failed else '')
        self.last_image_seconds = {}
        return vector

    def handle(self, request):
        result = super().handle(request)
        if request['command'] == 'index':
            result['device'] = self.last_image_backend
            result['stageSeconds'] = self.last_image_seconds
        return result

    def native_image_vector(self, path):
        from PIL import Image
        with Image.open(path) as image:
            return self.embed(image=image.convert('RGB'))

    def text_vector(self, text):
        return self.embed(text=text)
