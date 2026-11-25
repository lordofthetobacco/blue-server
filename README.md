# Project Blue dedicated server

`blue-server` is the authoritative multiplayer server for Project Blue. It
runs the same C++ simulation as the game client (movement, collision,
ballistics, damage) at 60 Hz, receives each player's tick-stamped commands
over encrypted UDP (netcode.io), and sends every client a snapshot per tick.
Clients predict their own player and reconcile; shots are lag-compensated on
the server. The wire format is specified in `docs/netcode/protocol.md` of the
[game repository](https://github.com/lordofthetobacco/project-blue) (protocol
version 3); it is available here as `project-blue/docs/netcode/protocol.md`.

## Getting the sources

```sh
git clone --recurse-submodules https://github.com/lordofthetobacco/blue-server
# or, in an existing clone:
git submodule update --init
```

The `project-blue` submodule is the game repository, pinned to a commit. It
provides the C++ simulation (`blue_sim_c`) and `netcode` sources that
`crates/blue-native` builds and links, and the protocol specification
`project-blue/docs/netcode/protocol.md`. To move the pin to a newer game
commit:

```sh
git -C project-blue fetch
git -C project-blue checkout <commit>
git add project-blue && git commit -m "Update project-blue to <commit>"
```

To build against another game checkout instead of the submodule, set
`BLUE_NATIVE_SOURCE=<dir>` (the directory with the game's `CMakeLists.txt`).

The golden vectors in `crates/blue-protocol/tests/vectors/` are generated
here (`BLUE_BLESS=1 cargo test -p blue-protocol`). The game repository holds a
copy in `docs/netcode/vectors/` for its C++ codec tests, and CI fails when the
two differ. After a protocol change, copy the regenerated vectors to the game
repository and move the submodule pin to that commit.

## What was verified where

| Part | Status |
|---|---|
| Native build in WSL (Ubuntu 26.04, cargo 1.99), both `build.rs` paths in this layout: CMake through the `project-blue` submodule, and `BLUE_NATIVE_PREBUILT`; `BLUE_NATIVE_SOURCE` accepted and rejected as documented | verified (WSL) |
| `cargo fmt --check`, `clippy -D warnings`, `cargo test --workspace` | verified (WSL, this layout) |
| 4-bot, 10 s run of `blue-bot` against `blue-server --sim native` (release build) | verified (WSL, this layout) |
| 16-bot soak, 60 s, 80 ms latency, 20 ms jitter, 5% loss | verified in the previous in-repository layout; not repeated here |
| Every `RUN` step of `Dockerfile`, rehearsed by hand in a clean WSL directory (in the previous in-repository layout) | verified there; not repeated in this layout |
| `docker build` / `docker run` of the image | **NOT verified**: Docker is not installed on the development machine |
| GitHub Actions `ci.yml` job (format, clippy, tests, golden vector comparison) | verified (runs on every push to `main`) |

## Architecture

```
crates/blue-protocol  wire codecs: bit packing, quantisation, messages, snapshots,
                      acks, reliable-ordered channel (pure Rust, no IO, golden vectors)
crates/blue-native    the only unsafe code: netcode.io and blue_sim C API bindings,
                      SIGTERM/SIGINT handling; build.rs builds the C/C++ with CMake
crates/blue-server    the binary: 60 Hz tick thread (deadline scheduled, never spirals),
                      sessions + handshake, command jitter buffers and validation,
                      snapshots (delta players, prioritised objects, 1200 B cap),
                      lag compensation (64-tick capsule history), metrics/health HTTP
crates/blue-bot       headless clients with a network conditioner, for soak tests
```

Per tick: receive and validate packets, take one command per player (repeat
the last held buttons if it is missing), step the simulation, test projectile
segments against capsules rewound to each shooter's view time, forward
simulation events (shots, damage, deaths, ...) as reliable messages, send
one snapshot per client. The steady-state tick does not allocate.

## Building and running natively (Linux / WSL)

Requirements: Rust 1.99 (rustup reads `rust-toolchain.toml`), CMake >= 3.25,
make, GCC >= 13 (`<format>`), git and network access (CMake fetches glm,
SDL3, JoltPhysics and netcode on the first build). CPU: x86-64-v3 (AVX2, BMI1,
F16C, LZCNT, POPCNT; Intel Haswell / AMD Excavator or newer) for the native
simulation; the server refuses to start it on an older CPU.

```sh
git submodule update --init
export CARGO_TARGET_DIR=$HOME/.cache/blue-server/target     # keep build output off /mnt/c
cargo build --release -p blue-server -p blue-bot             # runs CMake once (minutes)
cargo test --workspace
```

`build.rs` runs CMake on the `project-blue` submodule (or on
`BLUE_NATIVE_SOURCE`; `BLUE_SIM_ONLY=ON`, `BLUE_BUILD_TESTS=OFF`,
`RelWithDebInfo`) inside the cargo target directory and links
`blue_sim_c` + `netcode` from the link manifest CMake writes. To link an
existing sim-only build instead (faster iteration, the Docker build; the
submodule need not be checked out then):

```sh
cmake -S project-blue -B $HOME/.cache/blue-server/sim-only -DBLUE_SIM_ONLY=ON -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build $HOME/.cache/blue-server/sim-only --target blue_sim_c netcode
BLUE_NATIVE_PREBUILT=$HOME/.cache/blue-server/sim-only cargo build --release -p blue-server
```

Run:

```sh
# Stand-in simulation (pure Rust, flat plane, no weapons; no assets needed):
target/release/blue-server --sim standin
# The real simulation:
target/release/blue-server --sim native --asset-dir assets --scene range.mscn
```

## Staging assets

The native simulation needs the cooked scene and prefabs (collision and
weapon data). Copy them from a game build:

```sh
scripts/stage-assets.sh  [GAME_ASSET_DIR]     # Linux / WSL
scripts\stage-assets.ps1 [-SourceDir DIR]     # Windows
```

`GAME_ASSET_DIR` defaults to `../project-blue/out/build/x64-release/bin/assets`,
a game checkout next to this repository. The scripts
empty `assets/` (gitignored) and copy `range.mscn`, every `*.pbo` and
every `*.cfg` (weapon catalogue), keeping relative paths, then print the
list and total size (currently 25 files, about 414 MB). The sky HDR,
fingerprints and generated scene files are skipped. Nothing outside
`assets/` is touched.

## Configuration

Every setting has a flag and an environment variable; the flag wins.

| Variable | Flag | Default | Meaning |
|---|---|---|---|
| `BLUE_PORT` | `--port` | `27015` | UDP port |
| `BLUE_BIND` | `--bind` | `0.0.0.0` | accepted for compatibility; netcode always binds the wildcard address on the port (another value only logs a warning) |
| `BLUE_PUBLIC_ADDR` | `--public-addr` | `127.0.0.1:<port>` | the address clients dial; see below |
| `BLUE_MAX_PLAYERS` | `--max-players` | `16` | 1..=64 |
| `BLUE_SCENE` | `--scene` | `range.mscn` | scene, relative to the asset dir or absolute |
| `BLUE_ASSET_DIR` | `--asset-dir` | `assets` | cooked asset root |
| `BLUE_PRIVATE_KEY` | `--private-key` | development key | 64 hex digits shared with the token issuer |
| `BLUE_MAX_REWIND_MS` | `--max-rewind-ms` | `200` | lag-compensation cap, 0..=1000 |
| `BLUE_SNAPSHOT_RATE` | `--snapshot-rate` | `60` | snapshots per second per client, 1..=60 |
| `BLUE_METRICS_ADDR` | `--metrics-addr` | `0.0.0.0:9100` | HTTP listener; `off` disables it |
| `BLUE_LOG_FORMAT` | `--log-format` | `json` | `json` or `text`, to stdout |
| `BLUE_SIM` | `--sim` | `standin` | `standin` or `native` (the image sets `native`) |
| `BLUE_ENV` | `--env` | `development` | `production` refuses the development key |
| `BLUE_NETCODE_LOG` | `--netcode-log` | `0` | netcode library log level 0..=3 (unstructured printf output) |

**`BLUE_PUBLIC_ADDR` must be the address clients dial** (`host:port`, as
seen from the clients, e.g. the node or load-balancer IP). netcode.io bakes
the server address into every connect token and the server only accepts
tokens naming its own public address, so a wrong value means every client
times out during the connection handshake. The default `127.0.0.1` only
works for local clients and is logged as a warning.

## Container

```sh
git submodule update --init
scripts/stage-assets.sh
docker build -t blue-server .                           # context = this repository's root
docker run --rm -p 27015:27015/udp -p 9100:9100 \
  -e BLUE_PUBLIC_ADDR=<host-ip>:27015 -e BLUE_PRIVATE_KEY=<64 hex> blue-server
```

- Multi-stage build: `rust:1.99.0-slim-trixie` builder (pinned by digest)
  builds `blue_sim_c` + `netcode` in their own layer (only the submodule's
  `CMakeLists.txt`, `CMakePresets.json`, `cmake/` and `src/` are copied first,
  so Rust-only changes reuse it), then the Rust workspace against it via
  `BLUE_NATIVE_PREBUILT`. The build needs network access (FetchContent).
- Runtime: `gcr.io/distroless/cc-debian13:nonroot` (glibc + libstdc++, no
  shell), same Debian release as the builder. The binary needs only
  `libstdc++.so.6`, `libm.so.6`, `libgcc_s.so.1` and `libc.so.6`.
  Runs as `nonroot`, `EXPOSE 27015/udp 9100/tcp`, `STOPSIGNAL SIGTERM`.
- Debian 13, not 12: the C++ code uses `<format>` (GCC >= 13).
- Publish the game port as **UDP** (`-p 27015:27015/udp`); the TCP mapping
  is only for metrics.
- No `HEALTHCHECK` (there is no shell); probe `GET /healthz` instead.
- Image size is dominated by the assets (about 414 MB).

### Kubernetes notes

- One match per pod; the server holds all match state in memory.
- Expose the game port with a UDP `Service` (`protocol: UDP`) or
  `hostPort`/`hostNetwork`; set `BLUE_PUBLIC_ADDR` to the address the
  clients actually reach (node IP + node port, or the load balancer).
- `terminationGracePeriodSeconds: 5` or more: on SIGTERM the server stops
  ticking, disconnects every client and exits 0, measured at about 50 ms.
- Readiness: `httpGet /readyz` on 9100 (ready once the scene is loaded and
  the socket bound). Liveness: `httpGet /healthz`.
- Later: Agones (`GameServer` lifecycle, allocation, port management) instead
  of hand-written Services.

## Endpoints and metrics

`GET /healthz` (always `ok`), `GET /readyz` (`200` when ready, `503`
before/while stopping), `GET /metrics` (Prometheus text format):

| Metric | Type | Meaning |
|---|---|---|
| `blue_tick_duration_seconds` | histogram | time spent processing one tick |
| `blue_tick_duration_recent_seconds{quantile}` | gauge | p50, p90, p99, max over the last 10 s |
| `blue_snapshot_bytes` | histogram | snapshot payload sizes |
| `blue_ticks_total` | counter | simulated ticks |
| `blue_tick_overruns_total` | counter | ticks that took longer than 16.7 ms |
| `blue_ticks_late_total` | counter | ticks started at least one period late |
| `blue_ticks_skipped_total` | counter | ticks dropped by resynchronisation after a stall |
| `blue_packets_in_total`, `blue_bytes_in_total` | counter | received |
| `blue_packets_out_total`, `blue_bytes_out_total` | counter | sent |
| `blue_packets_dropped_total` | counter | duplicate, stale, rate limited |
| `blue_packets_invalid_total` | counter | protocol violations |
| `blue_commands_missing_total` | counter | player ticks run without a fresh command |
| `blue_commands_late_total` | counter | commands for ticks already simulated (normal resends) |
| `blue_clients_kicked_total` | counter | clients disconnected for violations |
| `blue_hits_total` | counter | lag-compensated player hits |
| `blue_sim_events_total` | counter | simulation events forwarded |
| `blue_projectile_segments_total` | counter | projectile segments swept |
| `blue_players` | gauge | welcomed players |
| `blue_connections` | gauge | netcode connections including handshakes |
| `blue_ready` | gauge | 1 when ready |

## Soak testing with bots

```sh
target/release/blue-server --sim standin &
target/release/blue-bot --count 16 --duration 60 --latency 80 --jitter 20 --loss 5

# Against the native sim: pass its content hash (logged as content_hash on start).
target/release/blue-bot --count 16 --duration 60 --latency 80 --jitter 20 --loss 5 \
  --aim --content-hash <hex>
```

Options: `--server`, `--count`, `--duration`, `--latency` (added one-way
delay per direction, ms), `--jitter`, `--loss`, `--dup`, `--reorder` (%),
`--seed`, `--content-hash`, `--private-key`, `--name`, `--aim` (aim at the
nearest player and fire). The bot exits 0 only if every bot stayed connected
and every invariant held (ticks advance, commands consumed, no decode
errors, no missing baselines, late-join sync complete) and prints RTT,
loss, snapshot sizes, input depth, corrections (prediction uses the
stand-in model, so they are only meaningful with `--sim standin`) and
message counts.

## Development key and production tokens

Without `BLUE_PRIVATE_KEY` the server uses a built-in development key (the
32 ASCII bytes `blue-dev-key-do-not-use-in-prod!`) and logs a warning on
every start; with `BLUE_ENV=production` it refuses to start. With that key
anyone can mint connect tokens, which is how the game client and the bots
connect today.

A production deployment needs a token service (behind the game's login) that
holds the private key and, per match join: authenticates the player, picks
the server, and calls the netcode.io connect-token generator with the
server's public address, protocol id `0x424C55455F4D5031`, a unique 64-bit
client id, an expiry of at most 30 s beyond issue (the server's
`max_connect_token_lifetime`), a timeout, and optional user data (player
identity) - then hands the 2048-byte token to the client. The key never
leaves the token service and the servers.

## Known limits

- Docker image not built or run yet (see the table at the top).
- One scene per process; no match lifecycle, no token service, no
  matchmaking, no anti-cheat beyond server authority and input validation.
- netcode's own C allocations are outside the Rust no-allocation check.
- The bot's network conditioner only delays game payloads; netcode's
  connection and keep-alive packets are not conditioned.
- Native-sim gaps reported to the C side: C++ log lines bypass the JSON log,
  `Death` weapon keys come from the killer's last shot, dropped weapons carry
  no magazine rounds or velocities, respawn yaw is read from the player
  state.
