# tdarr-av1

Drop-in replacements for the official [Tdarr](https://tdarr.io) Docker images with a full
AV1 encoding toolchain built in: [av1an](https://github.com/rust-av/Av1an) and
[ab-av1](https://github.com/alexheretic/ab-av1), plus everything they need to run
(a custom FFmpeg, VapourSynth, and their supporting libraries).

## Images

| Official                         | This project               |
| -------------------------------- | -------------------------- |
| `ghcr.io/haveagitgat/tdarr`      | `ghcr.io/empaa/tdarr`      |
| `ghcr.io/haveagitgat/tdarr_node` | `ghcr.io/empaa/tdarr_node` |

These extend the official images — swap the image name in your existing `docker run` or
`docker-compose.yml` and everything works the same. No other changes needed.

## What's inside

Two additional encoding tools are available to Tdarr plugin scripts:

- **[`av1an`](https://github.com/rust-av/Av1an)** — scene-based chunked encoding for fast,
  efficient AV1 transcoding
- **[`ab-av1`](https://github.com/alexheretic/ab-av1)** — quality-targeted encoding using VMAF
  to automatically find the right CRF

Both tools need supporting components to work, which are built and bundled alongside them:

- A custom-built **FFmpeg**, compiled with `libsvtav1`, `libaom`, and `libvmaf` so both AV1
  encoders and VMAF quality scoring are available. This FFmpeg takes precedence over Tdarr's
  bundled one.
- **VapourSynth**, with the **L-SMASH-Works** plugin for frame-accurate source demuxing — av1an
  uses this for scene detection and chunking.
- **mkvtoolnix**, for muxing/remuxing Matroska output.

See [`docs/architecture.md`](docs/architecture.md) for how these pieces fit together in the
Docker build, and [`docs/constraints.md`](docs/constraints.md) for the version pins and
compatibility requirements between them.

## Why

The official Tdarr images do not include av1an or ab-av1. This project bridges that gap so
plugin scripts can call these tools directly.

## Building and testing

`./build.sh` builds the images, runs binary/version/library-linkage checks, and does a live
startup check — all locally, without publishing anything. See
[`docs/build-and-publish.md`](docs/build-and-publish.md) for the full command reference,
including multi-platform builds, encode tests, and publishing to GHCR.

## Plugins

Tdarr FlowPlugins for AV1 encoding using these images are in the sibling repo:
[tdarr-plugins](https://github.com/empaa/tdarr-plugins)
