#!/bin/zsh
set -eu
cd "${0:A:h:h}"
AI_PYTHON="${PHOTOLAB_AI_PYTHON:-/opt/homebrew/bin/python3.13}"
"$AI_PYTHON" -m venv .ai-runtime
.ai-runtime/bin/python -m pip install -r AI/requirements.lock
.ai-runtime/bin/python AI/download_model.py
print 'AI environment ready. Run scripts/build-app.sh to package the worker.'
