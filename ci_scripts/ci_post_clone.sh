#!/bin/sh

set -eu

repository_root="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/.." && pwd)}"
medtrum_path="${repository_root}/MedtrumKit"
patch_path="${repository_root}/ci_scripts/patches/medtrum-peripheral-manager.patch"

git -C "${repository_root}" submodule update --init --recursive

if git -C "${medtrum_path}" apply --unidiff-zero --check "${patch_path}" 2>/dev/null; then
    git -C "${medtrum_path}" apply --unidiff-zero "${patch_path}"
elif git -C "${medtrum_path}" apply --unidiff-zero --reverse --check "${patch_path}" 2>/dev/null; then
    echo "MedtrumKit connection completion patch is already applied."
else
    echo "error: MedtrumKit connection completion patch does not match the checked-out revision." >&2
    exit 1
fi
