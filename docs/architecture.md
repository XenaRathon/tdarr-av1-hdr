# Architecture

Read this before adding features or making structural changes.

This file is populated as the project is built.

---

## AV1 Stack as a Build Stage

The AV1 stack (av1an, ab-av1, FFmpeg, VapourSynth, SVT-AV1, libaom, libvmaf,
L-SMASH-Works, mkvtoolnix) is compiled from source in the `av1-stack` named stage of the
single `Dockerfile`. The `tdarr` and `tdarr_node` targets layer the stack on top
of the official Tdarr base images via `COPY --from=av1-stack`.

All components install to `/usr/local`. `/etc/vapoursynth/vapoursynth.conf` is also
copied to configure the VapourSynth plugin directory. `ENV PYTHONPATH` is set in each
target to point at the compiled VapourSynth Python bindings.

**FFmpeg shadowing:** Our FFmpeg at `/usr/local/bin/ffmpeg` takes precedence over
Tdarr's bundled `/usr/bin/ffmpeg` via standard `$PATH` ordering. No wrappers or
`LD_LIBRARY_PATH` manipulation needed. On amd64, the Tdarr base image ships an
s6 init script (`/etc/cont-init.d/03-setup-ffmpeg`) that symlinks Jellyfin's
ffmpeg (no libvmaf) to `/usr/local/bin/ffmpeg` on every container start. The
Dockerfile removes this script — do not remove the `rm -f` step.

**glibc compatibility:** The `base` stage matches Tdarr's Ubuntu version exactly.
See `docs/constraints.md` for the pinned version.

**av1-stack is not published.** It exists solely as a build stage and test target —
`./build.sh --stack-only` builds and tests it directly, without the Tdarr layer, for
fast iteration on the AV1 toolchain. Only `tdarr` and `tdarr_node` are pushed to GHCR.
See `docs/build-and-publish.md` for the full build/test/publish workflow.

## Build Stage Graph (Dockerfile)

```
base (Ubuntu 24.04 + build tools + Rust)
 ├── build-svtav1       (independent)
 ├── build-libaom       (independent)
 ├── build-libvmaf      (independent)
 ├── build-vapoursynth  (zimg built inside; independent)
 │
 ├── build-ffmpeg  ←── svtav1, libaom, libvmaf
 │
 ├── build-lsmash    ←── vapoursynth, ffmpeg
 ├── build-av1an     ←── vapoursynth, ffmpeg
 └── build-ab-av1         (Rust only; independent)
          │
          ▼
      av1-stack  ←── all build-* stages (named target; test + layer source)
          │
          ├── tdarr       ←── ghcr.io/haveagitgat/tdarr + av1-stack
          └── tdarr_node  ←── ghcr.io/haveagitgat/tdarr_node + av1-stack
```

BuildKit runs independent stages in parallel automatically. `docker-bake.hcl` mirrors
this graph as buildx targets: `av1-stack` (cache-only, used by `--stack-only`), and
`tdarr`/`tdarr_node`, which both reference `av1-stack` as a build context so it is
only built once per invocation.

## Stage Notes

**build-av1an:** av1an is patched at build time (`patches/av1an-vmaf.py`) to fix an
upstream bug where the `.json`/version-string branches for selecting a VMAF model are
inverted — without the patch, passing a VMAF model path behaves as if a builtin model
version were requested, and vice versa. The patch is applied to the cloned source
before `cargo build`.

**mkvtoolnix:** Installed in both the `av1-stack` stage and the final `tdarr`/
`tdarr_node` stages (as a runtime `apt-get install`, not built from source) to give
plugin scripts an `mkvmerge`/`mkvextract` for muxing AV1 output into Matroska.

**Runtime config generation:** The `tdarr` and `tdarr_node` stages each generate a
VapourSynth TOML config (`/home/Tdarr/.config/vapoursynth/vapoursynth.toml`) at build
time, computing the correct `libpython3.12.so` path for the target architecture
(`aarch64-linux-gnu` vs `x86_64-linux-gnu`). This is required for av1an's VapourSynth
integration to find the Python interpreter at runtime. See `docs/constraints.md` for
why this file is needed at all.
