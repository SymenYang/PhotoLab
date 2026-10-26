#!/bin/zsh
set -eu
cd "${0:A:h:h}"
# No production app build, venv activation, model downloads or catalog writes.
PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -B Tests/ModelDownloads/run.py "$@"
