#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPOSITORY_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

exec "$REPOSITORY_ROOT/ci_scripts/apply_libre_brasil_patch.sh" "$REPOSITORY_ROOT"
