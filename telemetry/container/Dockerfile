# Balatro test runner: native Linux LÖVE + Lovely + Steamodded + BalatroBot under Xvfb.
# The game itself is NOT in the image: run.sh mounts Balatro.love from the local Steam install.
# Lovely only ships x86_64 Linux builds, so it is built from source for the host architecture.

FROM ubuntu:24.04 AS lovely
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git build-essential g++-14 cmake pkg-config \
    && update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-14 10 \
    && update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-14 10 \
    && rm -rf /var/lib/apt/lists/*
RUN curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain nightly
RUN git clone --depth 1 --branch v0.10.0 --recurse-submodules --shallow-submodules \
      https://github.com/ethangreen-dev/lovely-injector /src
WORKDIR /src
RUN /root/.cargo/bin/cargo build --release --package lovely-unix

# Fedora, not Ubuntu, for the runtime: Steamodded's nativefs reaches PhysFS through LuaJIT FFI
# (ffi.C.PHYSFS_*), which needs LÖVE built as a shared liblove.so. Ubuntu's love links it
# statically without exporting the symbols. (liblovely.so from the Ubuntu stage runs on Fedora's
# newer glibc.)
FROM fedora:42
RUN dnf install -y --setopt=install_weak_deps=False \
      love xorg-x11-server-Xvfb mesa-dri-drivers ca-certificates unzip python3 \
    && dnf clean all
COPY --from=ghcr.io/astral-sh/uv:0.9.21 /uv /uvx /usr/local/bin/
ENV UV_TOOL_DIR=/opt/uv/tools UV_PYTHON_INSTALL_DIR=/opt/uv/python UV_TOOL_BIN_DIR=/usr/local/bin
RUN uv tool install balatrobot==1.5.2

COPY --from=lovely /src/target/release/liblovely.so /usr/local/lib/liblovely.so
ENV LOVELY_MOD_DIR=/mods
RUN mkdir -p /mods /tmp/dl && cd /tmp/dl \
    && curl -sfL -o smods.zip https://github.com/Steamodded/smods/archive/refs/tags/1.0.0-beta-1814a.zip \
    && curl -sfL -o bb.zip https://github.com/coder/balatrobot/archive/refs/tags/v1.5.2.zip \
    && unzip -q smods.zip && unzip -q bb.zip \
    && mv smods-1.0.0-beta-1814a /mods/smods \
    && mkdir -p /mods/balatrobot/src \
    && cp balatrobot-1.5.2/balatrobot.json balatrobot-1.5.2/balatrobot.lua /mods/balatrobot/ \
    && cp -R balatrobot-1.5.2/src/lua /mods/balatrobot/src/lua \
    && rm -rf /tmp/dl
# BalatroBot 1.5.2 sends each reply with one non-blocking send() and then closes the socket (coder/balatrobot#243); a large
# game state that does not fit the socket buffer is cut off ("Remote end closed connection without
# response"), which happens under load. Make that send blocking (5 s) so the whole reply goes out.
RUN sed -i 's|  local _, err = BB_SERVER.client_socket:send(response_str)|  BB_SERVER.client_socket:settimeout(5)\n  local _, err = BB_SERVER.client_socket:send(response_str)|' \
      /mods/balatrobot/src/lua/core/server.lua \
    && grep -q "settimeout(5)" /mods/balatrobot/src/lua/core/server.lua

# RECORD=1 screen recording (x11grab, MJPEG); a separate layer so the layers above stay cached
RUN dnf install -y --setopt=install_weak_deps=False ffmpeg-free && dnf clean all

COPY entrypoint.sh /usr/local/bin/balatro-run
ENTRYPOINT ["balatro-run"]
