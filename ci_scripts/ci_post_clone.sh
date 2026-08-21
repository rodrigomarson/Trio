#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPOSITORY_ROOT=${CI_PRIMARY_REPOSITORY_PATH:-$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)}

sh "$SCRIPT_DIR/apply_libre_brasil_patch.sh" "$REPOSITORY_ROOT"
sh "$SCRIPT_DIR/validate_libre_brasil_sources.sh" "$REPOSITORY_ROOT"
