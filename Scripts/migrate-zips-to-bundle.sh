#!/bin/bash
# Copies species×stage PNG zips from the asset-gen workspace into the iOS app
# bundle's resource folder. Idempotent — re-running overwrites in place.
#
# Source layout (post asset-gen sprint):
#   docs/pet-design/ai-brief/species-zips-stages/
#     <species-id>-baby.zip   e.g. cat-tabby-baby.zip
#     <species-id>-adult.zip
#     <species-id>-elder.zip
#     (plus 5 legacy stage-synonym zips: bear-cub, bird-hen, bird-rooster,
#      dragon-hatchling, frog-tadpole — skipped, not used by the v4.0
#      renderer)
#
# Destination (flat layout per M3.2 SpriteAssetResolver convention):
#   PeerDrop/Resources/Pets/
#     cat-tabby-baby.zip
#     cat-tabby-adult.zip
#     ...
#
# After running:
#   1. xcodegen generate         (picks up Resources/Pets/ as a folder source)
#   2. xcodebuild build -scheme PeerDrop
#   3. The 324 zips are bundled into PeerDrop.app's resource root, where
#      Bundle.url(forResource:withExtension:) finds them.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="docs/pet-design/ai-brief/species-zips-stages"
DST="PeerDrop/Resources/Pets"

# Guard: source directory must exist. Without this, the bash glob below would
# silently expand to no matches and the script would report "Copied 0 zips"
# without explaining why — confusing during fresh checkouts where the asset
# workspace might not be present.
if [ ! -d "$SRC" ]; then
    echo "ERROR: source directory not found: $SRC" >&2
    echo "Hint: this script expects to be run from a clone that includes the" >&2
    echo "      asset-gen workspace under docs/pet-design/ai-brief/." >&2
    exit 1
fi

# Clean obsolete destination zips so renames or removals in the source dir
# don't leave ghost files in the bundle. Only zips are removed; non-.zip files
# (e.g. a hypothetical .gitkeep) are preserved.
mkdir -p "$DST"
rm -f "$DST"/*.zip

count=0
for zip in "$SRC"/*-baby.zip "$SRC"/*-adult.zip "$SRC"/*-elder.zip; do
    [ -f "$zip" ] || continue
    cp "$zip" "$DST/"
    count=$((count + 1))
done

echo "Copied $count zips to $DST/"
echo "Bundle size: $(du -sh "$DST" | awk '{print $1}')"
