# tdarr-av1-hdr

**HDR- and Dolby-Vision-capable AV1 encoding images for [Tdarr](https://tdarr.io).** A fork of
[`empaa/tdarr-av1`](https://github.com/empaa/tdarr-av1) ("Tdarr with AV1 superpowers") that swaps the
mainline SVT-AV1 encoder for the psychovisual **[SVT-AV1-Tritium](https://github.com/Uranite/svt-av1-tritium)**
fork and wires up real HDR / Dolby Vision / HDR10+ handling — so a CPU software-AV1 transcode pipeline
fed by arbitrary source files keeps grain, HDR, and DV intact.

Both a **server** and a **node** image are built from the same definition so they always run the same
Tdarr + encoder version and never drift out of sync:

```
ghcr.io/xenarathon/tdarr-av1-hdr-server:latest
ghcr.io/xenarathon/tdarr-av1-hdr-node:latest
```

<details>
<summary><b>What this changes versus upstream empaa/tdarr-av1 (click to expand)</b></summary>

| | empaa/tdarr-av1 | **this fork** |
|---|---|---|
| SVT-AV1 encoder | mainline v4.1.0 | **SVT-AV1-Tritium** (HDR + PSYEX + Essential lineage), v4.1.0-based → same `libSvtAv1Enc.so.4` SONAME, so ffmpeg's `libsvtav1` and av1an's `SvtAv1EncApp` both use it |
| Dolby Vision | — | **libdovi** built in → `--dolby-vision-rpu` RPU injection into the AV1 stream |
| HDR10+ | — | **libhdr10plus** built in → `--hdr10plus-json` dynamic metadata |
| Opus audio | ffmpeg built **without** libopus | **libopus 1.6.1** + `--enable-libopus` so audio re-encodes use the real `libopus` encoder |
| HDR tooling | — | `dovi_tool` + `hdr10plus_tool` CLIs in the image for RPU / HDR10+ extraction in flows |
| ffmpeg | 8.1.2 (CVE-2026-8461 "PixelSmash" patched) | **inherited unchanged** — kept current via upstream sync |

Everything else (av1an, ab-av1, VapourSynth, libaom, libvmaf, l-smash, mkvtoolnix) is kept at empaa's
tested pins; this fork stays mergeable with upstream so empaa's ffmpeg/Tdarr bumps sync straight in.
</details>

## Why
Source media (e.g. from public trackers) is untrusted *and* frequently HDR10/HDR10+/Dolby Vision.
Mainline SVT-AV1 can't re-inject a DV RPU, so DV is lost on transcode. Tritium + libdovi/libhdr10plus
fixes that, and its psychovisual tuning (`--variance-boost-curve`, `--ac-bias`, `--fgs-table`, tuned
defaults) is well suited to anime and grain-heavy film at the VMAF-targeted CRF search this pipeline uses.

## Setup & usage
See the **[Wiki](../../wiki)** for building, publishing, pulling the images, and pointing your DockHand
server + node stacks at them.

## Credits & lineage
Standing on a lot of shoulders — thank you to:
- **[Tdarr](https://tdarr.io)** (HaveAGitGat) — the transcode automation platform these images package.
- **[empaa/tdarr-av1](https://github.com/empaa/tdarr-av1)** — the AV1 build this fork is based on.
- **[SVT-AV1-Tritium](https://github.com/Uranite/svt-av1-tritium)** (Uranite) ← **[SVT-AV1-HDR](https://github.com/juliobbv-p/svt-av1-hdr)** (juliobbv-p) ← **[SVT-AV1-PSYEX](https://github.com/BlueSwordM/svt-av1-psyex)** (BlueSwordM) ← SVT-AV1-PSY ← mainline **[SVT-AV1](https://gitlab.com/AOMediaCodec/SVT-AV1)**.
- **[dovi_tool / hdr10plus_tool](https://github.com/quietvoid)** (quietvoid) — Dolby Vision & HDR10+ libraries and CLIs.
- **[Av1an](https://github.com/rust-av/Av1an)**, **[ab-av1](https://github.com/alexheretic/ab-av1)**, **[FFmpeg](https://ffmpeg.org)**, **[Opus](https://opus-codec.org)**.

## Built with Claude
The fork's changes (encoder swap, HDR/DV/HDR10+/Opus build stages, CI, docs) were developed with the
help of **Claude (Anthropic, Claude Opus 4.8)**.

## License
This fork's own additions — the Dockerfile changes, GitHub Actions workflow, and documentation in this
repository — are licensed **GPL-3.0** (see [`LICENSE`](LICENSE)). Files inherited from upstream
`empaa/tdarr-av1` remain under their original terms (the upstream repository is published without an
explicit license); this fork claims no rights over them.

## Roadmap
- Validate Tritium DV RPU injection end-to-end through the existing TV/Movie AV1 flows.
- Optionally pin `TDARR_VERSION` deliberately (vs tracking upstream) for fully controlled updates.
- Mirror to Forgejo (`git.ourserver.party`) alongside this GitHub home.
