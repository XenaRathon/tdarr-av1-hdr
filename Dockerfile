ARG TDARR_VERSION=2.78.01
FROM ubuntu:24.04 AS base

ENV DEBIAN_FRONTEND=noninteractive
ENV PKG_CONFIG_PATH=/usr/local/lib/pkgconfig

RUN apt-get update && apt-get install -y \
    build-essential \
    cmake \
    ninja-build \
    meson \
    nasm \
    yasm \
    autoconf \
    automake \
    libtool \
    pkg-config \
    python3-dev \
    cython3 \
    git \
    wget \
    curl \
    libssl-dev \
    xxd \
    && (ln -sf /usr/bin/cython3 /usr/bin/cython || true) \
    && rm -rf /var/lib/apt/lists/*

# Install Rust stable
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
ENV PATH="/root/.cargo/bin:${PATH}"

FROM base AS build-libopus

# libopus 1.6.1 — empaa's ffmpeg ships WITHOUT libopus. Bundle the latest reference encoder so
# audio can be transcoded with `-c:a libopus` (far better quality than ffmpeg's native opus encoder).
RUN git clone --depth 1 --branch v1.6.1 https://github.com/xiph/opus.git /src/opus && \
    cd /src/opus && \
    ./autogen.sh && \
    ./configure --prefix=/usr/local --enable-shared --disable-static && \
    make -j$(nproc) && \
    make install && \
    ldconfig && \
    rm -rf /src

FROM base AS build-libdovi

# libdovi (Dolby Vision) C library from quietvoid/dovi_tool, built via cargo-c. Lets SVT-AV1-Tritium
# inject the DV RPU into the AV1 stream (--dolby-vision-rpu). Installs dovi.pc into PKG_CONFIG_PATH.
RUN cargo install cargo-c
RUN git clone --depth 1 --branch 2.3.2 https://github.com/quietvoid/dovi_tool.git /src/dovi && \
    cd /src/dovi/dolby_vision && \
    cargo cinstall --release --prefix=/usr/local --libdir=/usr/local/lib && \
    ldconfig && \
    rm -rf /src /root/.cargo/registry

FROM base AS build-libhdr10plus

# libhdr10plus C library from quietvoid/hdr10plus_tool, built via cargo-c. Lets SVT-AV1-Tritium carry
# HDR10+ dynamic metadata (--hdr10plus-json). Installs hdr10plus.pc into PKG_CONFIG_PATH.
RUN cargo install cargo-c
RUN git clone --depth 1 --branch 1.7.2 https://github.com/quietvoid/hdr10plus_tool.git /src/h10p && \
    cd /src/h10p/hdr10plus && \
    cargo cinstall --release --prefix=/usr/local --libdir=/usr/local/lib && \
    ldconfig && \
    rm -rf /src /root/.cargo/registry

FROM base AS build-svtav1

# SVT-AV1-Tritium (fork of SVT-AV1-HDR incorporating SVT-AV1-PSYEX + Essential features) replaces
# mainline SVT-AV1. Same project VERSION 4.1.0 -> same libSvtAv1Enc.so.4 SONAME, so ffmpeg's
# --enable-libsvtav1 links against it natively (ab-av1's libsvtav1 path) and SvtAv1EncApp (av1an's
# direct path) is Tritium too. Built with Dolby Vision (LIBDOVI_FOUND) + HDR10+ (LIBHDR10PLUS_RS_FOUND)
# support; the C libs are copied in and found via pkg-config (mirrors Build/linux/build.sh's mapping).
COPY --from=build-libdovi      /usr/local /usr/local
COPY --from=build-libhdr10plus /usr/local /usr/local
RUN ldconfig

RUN git clone --depth 1 --branch v4.1.0 \
        https://github.com/Uranite/svt-av1-tritium.git /src/svtav1 && \
    cmake -S /src/svtav1 -B /src/svtav1/build \
        -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DBUILD_SHARED_LIBS=ON \
        -DLIBDOVI_FOUND=1 \
        -DLIBHDR10PLUS_RS_FOUND=1 && \
    cmake --build /src/svtav1/build -j$(nproc) && \
    cmake --install /src/svtav1/build && \
    ldconfig && \
    rm -rf /src

FROM base AS build-libaom

RUN wget -q "https://storage.googleapis.com/aom-releases/libaom-3.14.1.tar.gz" \
        -O /tmp/libaom.tar.gz && \
    mkdir -p /src/aom && \
    tar -xf /tmp/libaom.tar.gz -C /src/aom --strip-components=1 && \
    rm /tmp/libaom.tar.gz && \
    cmake -S /src/aom -B /src/aom_build \
        -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DBUILD_SHARED_LIBS=ON \
        -DENABLE_NASM=ON \
        -DENABLE_DOCS=OFF \
        -DENABLE_TESTS=OFF && \
    cmake --build /src/aom_build -j$(nproc) && \
    cmake --install /src/aom_build && \
    ldconfig && \
    rm -rf /src/aom /src/aom_build

FROM base AS build-libvmaf

RUN git clone --depth 1 --branch v3.2.0 \
        https://github.com/Netflix/vmaf.git /src/vmaf && \
    meson setup /src/vmaf/libvmaf/build /src/vmaf/libvmaf \
        --buildtype=release \
        -Dbuilt_in_models=true \
        -Dprefix=/usr/local && \
    ninja -C /src/vmaf/libvmaf/build && \
    ninja -C /src/vmaf/libvmaf/build install && \
    mkdir -p /usr/local/share/vmaf && \
    cp -r /src/vmaf/model/. /usr/local/share/vmaf/ && \
    ldconfig && \
    rm -rf /src

FROM base AS build-vapoursynth

# Ubuntu 24.04 ships Python 3.12. VapourSynth R73 requires Cython 3.
# --break-system-packages required on Ubuntu 24.04 (PEP 668).
RUN apt-get update && apt-get install -y python3-pip --no-install-recommends \
    && rm -rf /var/lib/apt/lists/* \
    && pip3 install --break-system-packages --upgrade "cython>=3" \
    && ln -sf /usr/local/bin/cython /usr/bin/cython3

# Build zimg 3.0.6 first — VapourSynth depends on it
RUN git clone --depth 1 --branch release-3.0.6 \
        https://github.com/sekrit-twc/zimg.git /src/zimg && \
    cd /src/zimg && \
    ./autogen.sh && \
    ./configure --prefix=/usr/local && \
    make -j$(nproc) && \
    make install && \
    ldconfig

# MUST be R73 or later — av1an 0.5.2 uses vapoursynth-rs v0.5.1 which requires
# VSScript API v4. R72 only provides API v3 and will fail to load at runtime.
RUN git clone --depth 1 --branch R77 \
        https://github.com/vapoursynth/vapoursynth.git /src/vapoursynth && \
    cd /src/vapoursynth && \
    # R75+ unconditionally installs every artifact (libs, vspipe, headers,
    # pkgconfig) into the Python site-packages 'vapoursynth' subdirectory.
    # We relocate the libs and vspipe to standard /usr/local paths and write
    # our own headers + pc files there.
    meson setup build --prefix=/usr/local --buildtype=release && \
    ninja -C build && \
    ninja -C build install && \
    VS_PKG="$(find /usr/local/lib -path '*/vapoursynth/libvapoursynth.so.4' -printf '%h' -quit)" && \
    cp -a "${VS_PKG}"/lib*.so* /usr/local/lib/ && \
    cp "${VS_PKG}/vspipe" /usr/local/bin/ && \
    install -d /usr/local/include/vapoursynth && \
    cp include/*.h /usr/local/include/vapoursynth/ && \
    install -d /usr/local/lib/pkgconfig && \
    printf 'prefix=/usr/local\nlibdir=${prefix}/lib\nincludedir=${prefix}/include/vapoursynth\n\nName: vapoursynth\nDescription: VapourSynth\nVersion: 77\nLibs: -L${libdir} -lvapoursynth\nCflags: -I${includedir}\n' \
        > /usr/local/lib/pkgconfig/vapoursynth.pc && \
    printf 'prefix=/usr/local\nlibdir=${prefix}/lib\nincludedir=${prefix}/include/vapoursynth\n\nName: vsscript\nDescription: VapourSynth Script Library\nVersion: 77\nRequires: vapoursynth\nLibs: -L${libdir} -lvsscript\nCflags: -I${includedir}\n' \
        > /usr/local/lib/pkgconfig/vsscript.pc && \
    # R74+ renamed libvapoursynth-script → libvsscript. av1an's vapoursynth-rs
    # crate still links -lvapoursynth-script, so provide a compat symlink.
    ln -sf libvsscript.so /usr/local/lib/libvapoursynth-script.so && \
    ldconfig && \
    rm -rf /src

FROM base AS build-ffmpeg

COPY --from=build-svtav1       /usr/local /usr/local
COPY --from=build-libaom       /usr/local /usr/local
COPY --from=build-libvmaf      /usr/local /usr/local
COPY --from=build-libopus      /usr/local /usr/local
COPY --from=build-libdovi      /usr/local /usr/local
COPY --from=build-libhdr10plus /usr/local /usr/local
RUN ldconfig

RUN wget -q https://ffmpeg.org/releases/ffmpeg-8.1.2.tar.xz -O /tmp/ffmpeg.tar.xz && \
    tar xf /tmp/ffmpeg.tar.xz -C /tmp && \
    cd /tmp/ffmpeg-8.1.2 && \
    ./configure \
        --prefix=/usr/local \
        --enable-gpl \
        --enable-shared \
        --disable-static \
        --disable-doc \
        --enable-libsvtav1 \
        --enable-libaom \
        --enable-libvmaf \
        --enable-libopus && \
    make -j$(nproc) && \
    make install && \
    ldconfig && \
    rm -rf /tmp/ffmpeg*

FROM base AS build-lsmash

COPY --from=build-vapoursynth /usr/local /usr/local
COPY --from=build-ffmpeg      /usr/local /usr/local
RUN ldconfig

RUN apt-get update && apt-get install -y --no-install-recommends libxxhash-dev \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch v2.14.5 https://github.com/l-smash/l-smash.git /src/l-smash && \
    cd /src/l-smash && \
    ./configure --prefix=/usr/local --enable-shared && \
    make -j$(nproc) && \
    make install && \
    ldconfig && \
    rm -rf /src/l-smash

# Use HomeOfAviSynthPlusEvolution fork — AkarinVS is incompatible with FFmpeg 5+
# (references AVStream.index_entries which was made private in FFmpeg commit cea7c19).
# Pinned to a specific commit for reproducibility; update intentionally when needed.
RUN git clone \
        https://github.com/HomeOfAviSynthPlusEvolution/L-SMASH-Works.git /src/lsmash && \
    git -C /src/lsmash checkout 0079a06ee384061ecdadd0de03df4e0493dd56ab && \
    meson setup /src/lsmash/VapourSynth/build /src/lsmash/VapourSynth \
        --buildtype=release \
        --prefix=/usr/local && \
    ninja -C /src/lsmash/VapourSynth/build && \
    ninja -C /src/lsmash/VapourSynth/build install && \
    ldconfig && \
    rm -rf /src

FROM base AS build-av1an

COPY --from=build-vapoursynth /usr/local /usr/local
COPY --from=build-ffmpeg      /usr/local /usr/local
RUN ldconfig

ENV VAPOURSYNTH_LIB_DIR=/usr/local/lib

COPY patches/av1an-vmaf.py /patches/av1an-vmaf.py

# av1an's canonical repo moved from master-of-zen/Av1an to rust-av/Av1an.
# (The old URL still redirects, but pin to the new canonical location.)
RUN git clone --depth 1 --branch v0.5.2 \
        https://github.com/rust-av/Av1an.git /src/av1an && \
    cd /src/av1an && \
    python3 /patches/av1an-vmaf.py && \
    cargo build --release && \
    cp target/release/av1an /usr/local/bin/ && \
    rm -rf /src

FROM base AS build-ab-av1

RUN cargo install ab-av1 --version 0.11.3 --root /usr/local

FROM ubuntu:24.04 AS av1-stack

COPY --from=build-svtav1      /usr/local /usr/local
COPY --from=build-libaom      /usr/local /usr/local
COPY --from=build-libvmaf     /usr/local /usr/local
COPY --from=build-vapoursynth /usr/local /usr/local
COPY --from=build-ffmpeg      /usr/local /usr/local
COPY --from=build-lsmash      /usr/local /usr/local
COPY --from=build-av1an        /usr/local /usr/local
COPY --from=build-ab-av1       /usr/local /usr/local
COPY --from=build-libopus      /usr/local /usr/local
COPY --from=build-libdovi      /usr/local /usr/local
COPY --from=build-libhdr10plus /usr/local /usr/local

# R74 wheel build installs the Python module to python3/dist-packages; also keep
# site-packages for any pip-installed packages (e.g. future VS plugins).
ENV PYTHONPATH=/usr/local/lib/python3/dist-packages:/usr/local/lib/python3.12/site-packages

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    libpython3.12 \
    mkvtoolnix \
    && rm -rf /var/lib/apt/lists/*

RUN ldconfig && \
    mkdir -p /etc/vapoursynth && \
    echo "SystemPluginDir=/usr/local/lib/vapoursynth" > /etc/vapoursynth/vapoursynth.conf && \
    # R74's wheel-installed Python module ignores SystemPluginDir and only loads
    # plugins from its own directory. Symlink system plugins into the wheel path.
    VS_PLUGIN_DIR="$(PYTHONPATH=/usr/local/lib/python3/dist-packages python3 -c \
        'import vapoursynth; print(vapoursynth.get_plugin_dir())')" && \
    mkdir -p "${VS_PLUGIN_DIR}" && \
    for so in /usr/local/lib/vapoursynth/*.so; do \
        [ -f "$so" ] && ln -sf "$so" "${VS_PLUGIN_DIR}/"; \
    done

# av1an defaults to looking for vmaf_v0.6.1.json relative to CWD (/). Symlink
# to the installed model so the default path resolves without --vmaf-path.
RUN ln -sf /usr/local/share/vmaf/vmaf_v0.6.1.json /vmaf_v0.6.1.json \
    && ln -sf /usr/local/share/vmaf/vmaf_4k_v0.6.1.json /vmaf_4k_v0.6.1.json

FROM ghcr.io/haveagitgat/tdarr:${TDARR_VERSION} AS tdarr
# On amd64, the Tdarr base image has an s6 init script (03-setup-ffmpeg) that
# symlinks Jellyfin's ffmpeg (no libvmaf) to /usr/local/bin/ffmpeg on every
# container start. Remove it so our custom ffmpeg is not overwritten at runtime.
RUN rm -f /etc/cont-init.d/03-setup-ffmpeg
# Remove system libaom (3.8.x) so the linker uses our custom build in /usr/local.
RUN apt-get remove -y libaom3 || true
COPY --from=av1-stack /usr/local /usr/local
COPY --from=av1-stack /etc/vapoursynth /etc/vapoursynth
ENV PYTHONPATH=/usr/local/lib/python3/dist-packages:/usr/local/lib/python3.12/site-packages
RUN ldconfig && \
    apt-get update && \
    apt-get install -y --no-install-recommends python3 libpython3.12 mkvtoolnix curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*
# dovi_tool + hdr10plus_tool CLIs (quietvoid) for the AV1 flow's HDR / Dolby-Vision branches —
# extract the DV RPU / HDR10+ JSON that the Tritium encoder then re-injects. Version-pinned to match
# the libdovi / libhdr10plus the encoder was linked against.
RUN set -eux; \
    for spec in "dovi_tool:2.3.2" "hdr10plus_tool:1.7.2"; do \
        name="${spec%%:*}"; ver="${spec##*:}"; \
        url="$(curl -fsSL "https://api.github.com/repos/quietvoid/${name}/releases/tags/${ver}" \
              | grep browser_download_url | grep 'x86_64-unknown-linux-musl' | head -n1 | cut -d '"' -f4)"; \
        curl -fsSL "$url" -o /tmp/${name}.tar.gz; \
        tar -xzf /tmp/${name}.tar.gz -C /usr/local/bin; \
        chmod +x /usr/local/bin/${name}; \
        rm /tmp/${name}.tar.gz; \
    done; \
    /usr/local/bin/dovi_tool --version; \
    /usr/local/bin/hdr10plus_tool --version
# VapourSynth R74 requires a TOML config mapping libvsscript to the Python
# interpreter. Generate it dynamically so the libpython path is correct for
# each architecture (aarch64-linux-gnu vs x86_64-linux-gnu).
RUN mkdir -p /home/Tdarr/.config/vapoursynth && \
    LIBPY="$(find /usr/lib -name 'libpython3.12.so.*' | head -1)" && \
    printf '"/usr/local/lib/libvsscript.so" = ["/usr/bin/python3","%s"]\n' "$LIBPY" \
        > /home/Tdarr/.config/vapoursynth/vapoursynth.toml
RUN ln -sf /usr/local/share/vmaf/vmaf_v0.6.1.json /vmaf_v0.6.1.json \
    && ln -sf /usr/local/share/vmaf/vmaf_4k_v0.6.1.json /vmaf_4k_v0.6.1.json

FROM ghcr.io/haveagitgat/tdarr_node:${TDARR_VERSION} AS tdarr_node
RUN rm -f /etc/cont-init.d/03-setup-ffmpeg
RUN apt-get remove -y libaom3 || true
COPY --from=av1-stack /usr/local /usr/local
COPY --from=av1-stack /etc/vapoursynth /etc/vapoursynth
ENV PYTHONPATH=/usr/local/lib/python3/dist-packages:/usr/local/lib/python3.12/site-packages
RUN ldconfig && \
    apt-get update && \
    apt-get install -y --no-install-recommends python3 libpython3.12 mkvtoolnix curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*
# dovi_tool + hdr10plus_tool CLIs (quietvoid) for the AV1 flow's HDR / Dolby-Vision branches —
# extract the DV RPU / HDR10+ JSON that the Tritium encoder then re-injects. Version-pinned to match
# the libdovi / libhdr10plus the encoder was linked against.
RUN set -eux; \
    for spec in "dovi_tool:2.3.2" "hdr10plus_tool:1.7.2"; do \
        name="${spec%%:*}"; ver="${spec##*:}"; \
        url="$(curl -fsSL "https://api.github.com/repos/quietvoid/${name}/releases/tags/${ver}" \
              | grep browser_download_url | grep 'x86_64-unknown-linux-musl' | head -n1 | cut -d '"' -f4)"; \
        curl -fsSL "$url" -o /tmp/${name}.tar.gz; \
        tar -xzf /tmp/${name}.tar.gz -C /usr/local/bin; \
        chmod +x /usr/local/bin/${name}; \
        rm /tmp/${name}.tar.gz; \
    done; \
    /usr/local/bin/dovi_tool --version; \
    /usr/local/bin/hdr10plus_tool --version
RUN mkdir -p /home/Tdarr/.config/vapoursynth && \
    LIBPY="$(find /usr/lib -name 'libpython3.12.so.*' | head -1)" && \
    printf '"/usr/local/lib/libvsscript.so" = ["/usr/bin/python3","%s"]\n' "$LIBPY" \
        > /home/Tdarr/.config/vapoursynth/vapoursynth.toml
RUN ln -sf /usr/local/share/vmaf/vmaf_v0.6.1.json /vmaf_v0.6.1.json \
    && ln -sf /usr/local/share/vmaf/vmaf_4k_v0.6.1.json /vmaf_4k_v0.6.1.json
