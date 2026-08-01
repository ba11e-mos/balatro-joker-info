#!/usr/bin/env bash
# Builds dist/<Mod>-<version>.zip for Nexus / GitHub releases.
# The zip contains the mod folder itself, so users can drop it straight into Mods/.
set -euo pipefail

cd "$(dirname "$0")"
MOD="$(basename "$PWD")"
VERSION="$(python3 -c 'import json;print(json.load(open("manifest.json"))["version"])')"
OUT="$PWD/dist"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$OUT"
rm -f "$OUT/$MOD-$VERSION.zip" "$OUT/$MOD.zip"

# copy the mod, dropping development-only files
rsync -a --exclude-from=- ./ "$STAGE/$MOD/" <<'EXCLUDES'
.git/
.github/
dist/
*.zip
package.sh
index.meta.json
screenshots/
.gitignore
.lovelyignore
config/
*.jkr
.DS_Store
EXCLUDES

( cd "$STAGE" && zip -qr "$OUT/$MOD-$VERSION.zip" "$MOD" )
cp "$OUT/$MOD-$VERSION.zip" "$OUT/$MOD.zip"   # stable name for downloadURL

echo "built $OUT/$MOD-$VERSION.zip"
unzip -l "$OUT/$MOD-$VERSION.zip"
