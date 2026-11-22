#!/bin/bash
# Standalone checkouts (this repository's own CI) lack the files a Lody checkout provides one
# level up: apps/mobile/backend-config.mjs and apps/mobile/shared. Fetch them from Lody.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
parent="$(dirname "$root")"
if [ -f "$parent/backend-config.mjs" ] && [ -d "$parent/shared/markdown-repair" ]; then
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
git clone --quiet --depth 1 --filter=blob:none --sparse --branch "${LODY_REF:-main}" https://github.com/LodyAI/Lody.git "$work/lody"
git -C "$work/lody" sparse-checkout set --no-cone /apps/mobile/backend-config.mjs /apps/mobile/shared/
cp "$work/lody/apps/mobile/backend-config.mjs" "$parent/backend-config.mjs"
rm -rf "$parent/shared"
cp -R "$work/lody/apps/mobile/shared" "$parent/shared"
