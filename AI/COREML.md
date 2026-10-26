# Qwen image embedding on Apple Neural Engine

The app passes `qwenCoreML` from its bundled AI/config.json as `PHOTOLAB_QWEN_COREML` to the local worker. The installed model directory is `.ai-model-qwen-coreml` (about 3.4 GB). `READY`, model revision and format must match. No downloads happen during inference.

Images use Core ML CPU_AND_NE; text queries keep the original MPS BF16 model. Core ML GPU is deliberately excluded because the earlier multi-package experiment crashed. Missing models, unsupported inputs and Python-level prediction errors disable Core ML for that worker and fall back to the original implementation. Set `PHOTOLAB_DISABLE_COREML=1` to opt out for diagnostics.

The logical embedding key is retained to reuse existing vectors; the FP16 implementation has small numerical differences. It includes the entire Qwen vision encoder, DeepStack and text decoder, not just the vision encoder. Patch inputs are padded to 1024, text to 277; geometry-specific positions, masks and pooling preserve the native aspect ratio and effective token sequence. Up to eight geometry contexts are cached. Requests remain serial.

## Rebuild the converted model

Do conversion in a separate environment; do not downgrade the app's PyTorch runtime:

```sh
/opt/homebrew/bin/python3.13 -m venv .ai-coreml-converter
.ai-coreml-converter/bin/python -m pip install -r AI/coreml-conversion-requirements.lock
.ai-coreml-converter/bin/python AI/convert_qwen_coreml.py --model .ai-model-qwen --output .ai-model-qwen-coreml-staging
```

Conversion can resume an interrupted directory of the same format and revision. `READY` is written only after the complete FP32 graph check. Before replacing the installed directory, validate the converted model against the original model on representative images; use a new empty directory for a different converter implementation or revision. Keep the old package until the replacement has passed runtime checks. Rebuild the app with `PHOTOLAB_DIRECT_BUILD=1 zsh scripts/build-app.sh` after installing it.

## Input pipeline

Two utility-priority decoder operations prepare at most three images ahead of serial inference. Original media are read only. A separate analysis queue avoids occupying the foreground image decode queue. The same 512-pixel, SDR/sRGB, rotated JPEG bytes are cached by the existing full asset fingerprint under `~/Library/Caches/PhotoLab/Analysis` and count toward the 200 GB cache budget with the existing 20 GB free-space reserve. Eviction never removes original media, catalog marks or embeddings. A consumer owns an independent temporary copy, so cache eviction cannot invalidate an in-flight inference.

The cache saves repeat reads across model passes or invalidated model indexes. It does not eliminate the first read of every NAS original. Small prefetch buffers hide short stalls, not network outages or sustained bandwidth limits. File or rotation changes naturally produce another fingerprint.
