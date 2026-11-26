# Cooks the assets the dedicated server reads on Linux, from the project-blue
# submodule, and exports exactly what scripts/stage-assets.sh stages
# (range.mscn, *.pbo, *.cfg with relative paths). Build from the repository
# root; scripts/cook-assets.sh runs it:
#   docker build -f docker/assets.Dockerfile --output type=local,dest=assets .
#
# blue-pack is a target of the full game configure, which needs a renderer to
# configure: the Vulkan headers and loader (libvulkan-dev) and slangc, a
# pinned Slang release. Neither is used to cook: only the blue-pack target is
# built, and shader hot reload (the Slang library) is off. SDL is configured
# as a console library (no X11/Wayland): blue-pack only uses its file system.
#
# Works on linux/arm64 and linux/amd64 (the Slang archive follows TARGETARCH).
ARG BUILD_IMAGE=debian:trixie-slim@sha256:8aa5a7bf5a1955bddbe7d74fcdd0b91ab30e74362a8b73af672b0481b35b44a0

FROM ${BUILD_IMAGE} AS cook

# git and ca-certificates: CMake's FetchContent clones SDL3, glm, assimp, ...
# (network required); curl: the Slang download.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        cmake make g++ git ca-certificates curl pkg-config libvulkan-dev zlib1g-dev \
 && rm -rf /var/lib/apt/lists/*

# slangc 2026.17 (the oldest version the shaders accept, cmake/Shaders.cmake),
# checked by SHA-256. Only `slangc -v` runs, at configure time.
ARG TARGETARCH
ARG SLANG_VERSION=2026.17
ARG SLANG_SHA256_ARM64=1873b032fd9e44fa91cba567287304b8886e3e01a4ebe4f26dd20af5f8050582
ARG SLANG_SHA256_AMD64=e8162da376858faf7d00dc9a94be52a8ff014d14c35c5f8e49c97688ec57bb7b
RUN set -eu; \
    case "${TARGETARCH}" in \
      arm64) file="slang-${SLANG_VERSION}-linux-aarch64-glibc-2.28.tar.gz"; sha="${SLANG_SHA256_ARM64}" ;; \
      amd64) file="slang-${SLANG_VERSION}-linux-x86_64-glibc-2.27.tar.gz"; sha="${SLANG_SHA256_AMD64}" ;; \
      *) echo "unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/slang.tar.gz \
        "https://github.com/shader-slang/slang/releases/download/v${SLANG_VERSION}/${file}"; \
    echo "${sha}  /tmp/slang.tar.gz" | sha256sum -c -; \
    mkdir /opt/slang; \
    tar -xzf /tmp/slang.tar.gz -C /opt/slang; \
    rm /tmp/slang.tar.gz; \
    /opt/slang/bin/slangc -v

WORKDIR /src
COPY project-blue/ .

# Parallel compile jobs: docker build --build-arg JOBS=6 ...
ARG JOBS=0
RUN cmake -S . -B /build -DCMAKE_BUILD_TYPE=Release \
        -DBLUE_BUILD_TESTS=OFF -DBLUE_SHADER_HOT_RELOAD=OFF \
        -DBLUE_SLANGC=/opt/slang/bin/slangc \
        -DSDL_UNIX_CONSOLE_BUILD=ON \
 && cmake --build /build --target blue-pack \
        --parallel "$([ "${JOBS}" -gt 0 ] && echo "${JOBS}" || nproc)"

# Full quality textures, like the Release game build; the server never reads
# them, so the content hash does not depend on it.
RUN /build/bin/blue-pack samples --source samples --out /cooked \
 && mkdir /out \
 && cd /cooked \
 && find . -type f \( -name range.mscn -o -name '*.pbo' -o -name '*.cfg' \) \
        -exec cp --parents {} /out/ \; \
 && find /out -type f | sort

FROM scratch
COPY --from=cook /out/ /
