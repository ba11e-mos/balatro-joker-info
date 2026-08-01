#!/usr/bin/env bash
# Builds dist/<Mod>-<version>.zip for Nexus / GitHub releases.
# The zip contains the mod folder itself, so users can drop it straight into Mods/.
set -euo pipefail

cd "$(dirname "$0")"
# the mod id, not the directory: on a CI runner the checkout is named after the
# repo, which would put the wrong folder name inside the zip
MOD="$(python3 -c 'import json;print(json.load(open("manifest.json"))["id"])')"
VERSION="$(python3 -c 'import json;print(json.load(open("manifest.json"))["version"])')"
OUT="$PWD/dist"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$OUT"
rm -f "$OUT/$MOD.zip"

# copy the mod, dropping development-only files
rsync -a --exclude-from=- ./ "$STAGE/$MOD/" <<'EXCLUDES'
.git/
.github/
dist/
*.zip
package.sh
bmi/
screenshots/
.gitignore
.lovelyignore
config/
*.jkr
.DS_Store
EXCLUDES

# one zip, always the same name: the release tag carries the version, and
# index.meta.json points at releases/latest/download/$MOD.zip
( cd "$STAGE" && zip -qr "$OUT/$MOD.zip" "$MOD" )

echo "built $OUT/$MOD.zip ($MOD $VERSION)"
unzip -l "$OUT/$MOD.zip"
