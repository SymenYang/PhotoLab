#!/bin/zsh
set -eu
cd "${0:A:h:h}"
# Never overwrite or register the developer's local PhotoLab.app.
PHOTOLAB_DISTRIBUTION_BUILD=1 zsh scripts/build-app.sh
