#!/usr/bin/env bash
# Smoke test for the container images (macOS and Linux, needs docker + curl).
#
# Usage: scripts/smoke-test.sh [standin|native]      (default: standin)
#
# For each of two phases it starts the server container, waits for
# GET /readyz on the published metrics port, runs the blue-bot image against
# it and requires exit 0, then `docker stop`s the server and requires exit
# code 0 within STOP_LIMIT seconds (the server promises 2 s on SIGTERM).
#   phase 1  bot shares the server's network namespace (--network
#            container:<server>) and dials 127.0.0.1:PORT.
#   phase 2  the documented run command: the game port is published
#            (-p PORT:PORT/udp), BLUE_PUBLIC_ADDR is the address the bot
#            dials (the docker bridge gateway, which reaches the host's
#            published ports from a container on Docker Desktop and Linux).
# `native` needs an image built with assets/ (the default target) and passes
# the server's content_hash from its JSON log to the bot.
#
# Environment (all optional):
#   IMAGE=blue-server  BOT_IMAGE=blue-bot  PLATFORM=linux/amd64 (docker --platform)
#   PORT=27015  METRICS_PORT=9100  BOT_DURATION=5  BOT_COUNT=2
#   READY_TIMEOUT=120 (seconds; emulated platforms start slowly)  STOP_LIMIT=2
set -euo pipefail

mode="${1:-standin}"
case "${mode}" in standin | native) ;; *)
  echo "usage: $0 [standin|native]" >&2
  exit 2
  ;;
esac

IMAGE="${IMAGE:-blue-server}"
BOT_IMAGE="${BOT_IMAGE:-blue-bot}"
PORT="${PORT:-27015}"
METRICS_PORT="${METRICS_PORT:-9100}"
BOT_DURATION="${BOT_DURATION:-5}"
BOT_COUNT="${BOT_COUNT:-2}"
READY_TIMEOUT="${READY_TIMEOUT:-120}"
STOP_LIMIT="${STOP_LIMIT:-2}"
platform_args=()
if [[ -n "${PLATFORM:-}" ]]; then platform_args=(--platform "${PLATFORM}"); fi

name="blue-smoke-$$"
cleanup() { docker rm -f "${name}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  docker logs --tail 40 "${name}" >&2 2>&1 || true
  exit 1
}

now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }

# start_server <public-addr>: starts the container, waits until ready.
start_server() {
  local public_addr="$1"
  docker run -d --name "${name}" ${platform_args[@]+"${platform_args[@]}"} \
    -p "${PORT}:${PORT}/udp" -p "${METRICS_PORT}:9100" \
    -e BLUE_PORT="${PORT}" -e BLUE_PUBLIC_ADDR="${public_addr}" \
    -e BLUE_SIM="${mode}" "${IMAGE}" >/dev/null
  local deadline=$((SECONDS + READY_TIMEOUT))
  until curl -fs "http://127.0.0.1:${METRICS_PORT}/readyz" >/dev/null 2>&1; do
    [[ "$(docker inspect -f '{{.State.Running}}' "${name}")" == true ]] \
      || fail "server container exited before becoming ready"
    ((SECONDS < deadline)) || fail "/readyz not ready after ${READY_TIMEOUT} s"
    sleep 0.5
  done
}

# stop_server: SIGTERM, require a clean and quick exit.
stop_server() {
  local t0 t1 code elapsed
  t0="$(now)"
  docker stop -t 10 "${name}" >/dev/null
  t1="$(now)"
  code="$(docker inspect -f '{{.State.ExitCode}}' "${name}")"
  elapsed="$(perl -e "printf '%.2f', ${t1} - ${t0}")"
  echo "server stopped: exit ${code} in ${elapsed} s"
  [[ "${code}" == 0 ]] || fail "server exit code ${code} after SIGTERM (want 0)"
  perl -e "exit(${elapsed} <= ${STOP_LIMIT} ? 0 : 1)" \
    || fail "stop took ${elapsed} s (limit ${STOP_LIMIT} s)"
  docker rm "${name}" >/dev/null
}

# run_bot <server-addr> [extra docker run args...]
run_bot() {
  local server="$1"
  shift
  local hash_args=()
  if [[ "${mode}" == native ]]; then
    local hash
    hash="$(docker logs "${name}" 2>&1 \
      | sed -n 's/.*"event":"server_started".*"content_hash":"\([0-9a-f]*\)".*/\1/p' | head -n1)"
    [[ -n "${hash}" ]] || fail "no content_hash in the server log"
    hash_args=(--content-hash "${hash}")
  fi
  docker run --rm ${platform_args[@]+"${platform_args[@]}"} ${1+"$@"} "${BOT_IMAGE}" \
    --server "${server}" --count "${BOT_COUNT}" --duration "${BOT_DURATION}" \
    ${hash_args[@]+"${hash_args[@]}"} \
    || fail "blue-bot exited non-zero"
}

echo "== phase 1: bot in the server's network namespace (${mode}) =="
start_server "127.0.0.1:${PORT}"
run_bot "127.0.0.1:${PORT}" --network "container:${name}"
stop_server

echo "== phase 2: bot through the published UDP port (${mode}) =="
gateway="$(docker network inspect bridge --format '{{(index .IPAM.Config 0).Gateway}}')"
[[ -n "${gateway}" ]] || fail "cannot determine the docker bridge gateway"
start_server "${gateway}:${PORT}"
run_bot "${gateway}:${PORT}"
stop_server

echo "PASS (${mode}${PLATFORM:+, ${PLATFORM}})"
