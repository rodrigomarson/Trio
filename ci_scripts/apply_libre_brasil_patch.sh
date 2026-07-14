#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPOSITORY_ROOT=${1:-$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)}
SUBMODULE="$REPOSITORY_ROOT/LibreTransmitter"
PATCH="$SCRIPT_DIR/libre_brasil.patch"

if [ ! -e "$SUBMODULE/.git" ]; then
    git -C "$REPOSITORY_ROOT" submodule update --init --recursive LibreTransmitter
fi

if git -C "$SUBMODULE" apply --reverse --check "$PATCH" >/dev/null 2>&1; then
    echo "Libre Brazil patch is already applied."
    exit 0
fi

git -C "$SUBMODULE" apply --check "$PATCH"
git -C "$SUBMODULE" apply "$PATCH"

echo "Applied the Libre Brazil diagnostic patch."
