#!/usr/bin/env bash
# Cooks the assets the dedicated server reads into assets/ in the repository
# root (gitignored; the Dockerfile copies it into the image), inside Docker,
# from the project-blue submodule. Same result as scripts/stage-assets.sh
# without a game build; needs Docker with BuildKit and network access.
#
# Usage: scripts/cook-assets.sh [JOBS]
#   JOBS caps the parallel compile jobs (default: all CPUs of the Docker VM).
#   The image platform is the Docker host's; DOCKER_DEFAULT_PLATFORM overrides.
# Only assets/ is modified: it is emptied, then filled.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
jobs="${1:-0}"

if [[ ! -f "${repo_root}/project-blue/CMakeLists.txt" ]]; then
  echo "error: project-blue is empty (git submodule update --init)" >&2
  exit 1
fi

# Export into a fresh directory first, so a failed build leaves assets/ alone.
out="$(mktemp -d "${repo_root}/assets.cook.XXXXXX")"
trap 'rm -rf "${out}"' EXIT
docker build -f "${repo_root}/docker/assets.Dockerfile" \
  --build-arg "JOBS=${jobs}" --output "type=local,dest=${out}" "${repo_root}"

mkdir -p "${repo_root}/assets"
find "${repo_root}/assets" -mindepth 1 -delete
cp -R "${out}/." "${repo_root}/assets/"

count="$(find "${repo_root}/assets" -type f | wc -l | tr -d ' ')"
total="$(du -sh "${repo_root}/assets" | cut -f1)"
echo "cooked ${count} files, ${total}, into ${repo_root}/assets"
