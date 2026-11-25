#!/usr/bin/env bash
# Stages the cooked assets the dedicated server reads into assets/ in the
# repository root (gitignored; the Dockerfile copies it into the image):
#   range.mscn, every *.pbo (scene and weapon prefabs, with their relative
#   paths) and every *.cfg (weapon catalogue).
# Render-only files (env/*.hdr, *.fingerprint, *.generated.mscn) are skipped.
#
# Usage: scripts/stage-assets.sh [GAME_ASSET_DIR]
#   GAME_ASSET_DIR defaults to ../project-blue/out/build/x64-release/bin/assets
#   (a game checkout next to this repository, relative to the repository
#   root). Only assets/ is modified: it is emptied, then filled.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
source_dir="${1:-${repo_root}/../project-blue/out/build/x64-release/bin/assets}"
target_dir="${repo_root}/assets"

if [[ ! -f "${source_dir}/range.mscn" ]]; then
  echo "error: ${source_dir}/range.mscn not found (build the game first)" >&2
  exit 1
fi
source_dir="$(cd "${source_dir}" && pwd)"

mkdir -p "${target_dir}"
# Empty assets/ only (never anything outside it).
find "${target_dir}" -mindepth 1 -delete

count=0
while IFS= read -r -d '' file; do
  relative="${file#"${source_dir}/"}"
  mkdir -p "${target_dir}/$(dirname "${relative}")"
  cp "${file}" "${target_dir}/${relative}"
  printf '  %10d  %s\n' "$(stat -c %s "${file}")" "${relative}"
  count=$((count + 1))
done < <(find "${source_dir}" -type f \
  \( -name 'range.mscn' -o -name '*.pbo' -o -name '*.cfg' \) -print0 | sort -z)

total="$(du -sh "${target_dir}" | cut -f1)"
echo "staged ${count} files, ${total}, into ${target_dir}"
