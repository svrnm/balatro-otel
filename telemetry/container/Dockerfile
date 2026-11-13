# Balatro test runner: native Linux LÖVE + Lovely + Steamodded + BalatroBot under Xvfb.
# The game itself is NOT in the image: run.sh mounts Balatro.love from the local Steam install.
# Lovely only ships x86_64 Linux builds, so it is built from source for the host architecture.

FROM ubuntu:24.04@sha256:2198e4c65076e9cb0b3d695219df667c0e3b0072da64ca3c2648aca17dcecaf5 AS lovely
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git build-essential g++-14 cmake pkg-config \
    && update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-14 10 \
    && update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-14 10 \
    && rm -rf /var/lib/apt/lists/*
COPY downloads.sha256 /tmp/downloads.sha256
# Verify the versioned bootstrap binary; Lovely requires nightly Rust.
RUN arch=$(uname -m) \
    && curl -sfL -o "/tmp/rustup-init-$arch" "https://static.rust-lang.org/rustup/archive/1.28.2/$arch-unknown-linux-gnu/rustup-init" \
    && cd /tmp && sha256sum --check --ignore-missing downloads.sha256 \
    && chmod +x "rustup-init-$arch" \
    && ./rustup-init-"$arch" -y --profile minimal --default-toolchain nightly-2026-10-29 \
    && rm "rustup-init-$arch"
# Lovely v0.10.0, including submodules at the commits recorded by that revision.
RUN git init /src \
    && git -C /src remote add origin https://github.com/ethangreen-dev/lovely-injector \
    && git -C /src fetch --depth 1 origin 073060eeb81b3664f476bdd33c263663d48762d1 \
    && git -C /src checkout --detach FETCH_HEAD \
    && git -C /src submodule update --init --recursive --depth 1
WORKDIR /src
RUN /root/.cargo/bin/cargo +nightly-2026-10-29 build --locked --release --package lovely-unix

# Fedora, not Ubuntu, for the runtime: Steamodded's nativefs reaches PhysFS through LuaJIT FFI
# (ffi.C.PHYSFS_*), which needs LÖVE built as a shared liblove.so. Ubuntu's love links it
# statically without exporting the symbols. (liblovely.so from the Ubuntu stage runs on Fedora's
# newer glibc.)
FROM fedora:42@sha256:99e203b80b1c3d8f7e161ec10a68fd02b081ef83a3963553e513c82846b97814
RUN dnf install -y --setopt=install_weak_deps=False \
      love xorg-x11-server-Xvfb mesa-dri-drivers ca-certificates unzip python3 \
    && dnf clean all
COPY --from=ghcr.io/astral-sh/uv:0.9.21@sha256:15f68a476b768083505fe1dbfcc998344d0135f0ca1b8465c4760b323904f05a /uv /uvx /usr/local/bin/
ENV UV_TOOL_DIR=/opt/uv/tools UV_PYTHON_INSTALL_DIR=/opt/uv/python UV_TOOL_BIN_DIR=/usr/local/bin
RUN uv tool install balatrobot==1.5.2

COPY --from=lovely /src/target/release/liblovely.so /usr/local/lib/liblovely.so
COPY downloads.sha256 /tmp/downloads.sha256
ENV LOVELY_MOD_DIR=/mods
RUN mkdir -p /mods /tmp/dl && cd /tmp/dl \
    && curl -sfL -o smods.zip https://github.com/Steamodded/smods/archive/refs/tags/1.0.0-beta-1814a.zip \
    && curl -sfL -o bb.zip https://github.com/coder/balatrobot/archive/refs/tags/v1.5.2.zip \
    && sha256sum --check --ignore-missing /tmp/downloads.sha256 \
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
