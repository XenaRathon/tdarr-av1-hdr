# Build and Publish

Read this before any build, test, or GHCR publish work.

All commands go through `./build.sh`, a single entrypoint over `docker-bake.hcl`.

---

## Quick reference

| Command                                | What it does                                                       |
| -------------------------------------- | ------------------------------------------------------------------ |
| `./build.sh`                           | Build + test, native arch                                          |
| `./build.sh --all-platforms`           | Build + test, amd64 + arm64                                        |
| `./build.sh --arm64`                   | Build + test, arm64 only                                           |
| `./build.sh --amd64`                   | Build + test, amd64 only                                           |
| `./build.sh --encode`                  | Build + test with encode tests (uses samples, or generates one)    |
| `./build.sh --stack-only`              | Build + test av1-stack only (fast feedback)                        |
| `./build.sh --interactive`             | Build + test, then run a live tdarr + tdarr_node stack until Enter |
| `./build.sh --publish`                 | Push previously tested images to GHCR                              |
| `./build.sh --all-platforms --publish` | Build + test + publish (one shot)                                  |
| `./build.sh --clean`                   | Remove images + test output, stop builder                          |
| `./build.sh --clean-cache`             | Same as --clean + prune buildx cache                               |

Platform flags (`--all-platforms`, `--arm64`, `--amd64`) are mutually exclusive.
Omitting all three defaults to native architecture. `--stack-only` and `--publish`
cannot be combined — `av1-stack` is a build/test target only and is never published.
`--interactive` requires the full `tdarr_node` image, so it cannot be combined with
`--stack-only` either. `--clean`/`--clean-cache` are standalone and cannot be
combined with any build/test/publish flag.

## What gets tested

Each build runs, per target image:

- **Binary checks** — `av1an`, `ab-av1`, and `ffmpeg` respond to a version flag.
- **Version checks** — output matches the pinned versions (`av1an` 0.5.2, `ab-av1`
  0.11.3, `ffmpeg` 8.1).
- **Library-linkage checks** — `ldd` confirms `ffmpeg`, `aomenc`, `av1an`, and
  `vspipe` resolve their custom-built libraries (`libaom`, `libSvtAv1Enc`,
  `libvmaf`, `libvapoursynth`/`libvsscript`) from `/usr/local`, not a system
  package. This catches the case where the Tdarr base image's own libraries shadow
  ours.
- **Startup check** (`tdarr`/`tdarr_node` builds only) — a server and node container
  are actually started against each other and checked for a running, responsive
  state, not just a successful image build.
- **Encode tests** (with `--encode`) — see below.

`build.sh` checks binaries via the `BINARIES` array (`av1an`, `ab-av1`, `ffmpeg`).
Update that array when new binaries are added to the `Dockerfile`.

## How publishing works

Images are built into the local Docker daemon during testing. Publishing retags
and pushes those exact images — no rebuild. This guarantees what you tested is
what you ship. Images are pushed to `ghcr.io/empaa`.

**Typical two-step workflow:**

```bash
./build.sh --all-platforms          # build + test
./build.sh --publish --all-platforms  # push (no rebuild)
```

**One-shot workflow:**

```bash
./build.sh --all-platforms --publish  # build + test + publish
```

For multi-platform publishes, arch-specific images are pushed first, then a
manifest list is created for the `:latest` tag via `docker buildx imagetools`.

Running `--publish` alone (no other build flags) auto-detects every architecture
already built locally and republishes all of them, so a bare `./build.sh --publish`
after a full `--all-platforms` build still produces a correct multi-arch `:latest`.

## One-time setup per machine

1. Create a PAT at GitHub → Settings → Developer settings → Personal access tokens
   (classic) with `write:packages` scope, then:

```bash
echo <TOKEN> | docker login ghcr.io -u <your-github-username> --password-stdin
```

Alternatively, if you have the `gh` CLI authenticated:

```bash
gh auth token | docker login ghcr.io -u <your-github-username> --password-stdin
```

2. The buildx builder (`multiplatform`) is auto-created on first run. To create it
   manually:

```bash
docker buildx create --name multiplatform --driver docker-container --use
```

## Encode tests

Place sample video files (>= 2 min long) in `test/samples/` before running with
`--encode`. If `test/samples/` is empty, `./build.sh --encode` generates a short
synthetic clip (`test/genSample.sh`) so the test still runs. Outputs land in
`test/output/stack/` (for `--stack-only --encode`) or `test/output/tdarr/` (for a
full `tdarr` build) for inspection.

## Platform notes

On M1 Mac: arm64 compiles natively, amd64 via Rosetta/QEMU (reliable).
On Intel/AMD Linux: arm64 uses QEMU and may segfault on the SVT-AV1 compile.

The local build cache (`.buildcache/`) is automatically disabled on filesystems
where BuildKit's local cache export is known to corrupt (virtiofs, 9p, NFS, CIFS)
— `build.sh` detects this and unsets `CACHE_DIR`. Override by exporting `CACHE_DIR`
yourself before running.

## Branching strategy

All development uses feature branches merged with `--no-ff` (merge commits):

```
main ──────────────●──────────────●──── (stable, release-ready)
                  ╱              ╱
dev ────●────●───●────●────●───●────── (integration branch)
       ╱    ╱              ╱
      feature/a       feature/b
```

1. Branch `feature/xyz` from `dev` for any new feature or significant change
2. Work and commit on the feature branch
3. Merge to `dev`: `git merge --no-ff feature/xyz`
4. To revert a feature later: `git revert -m 1 <merge-commit>`

Small fixes (typos, single-line changes) can commit directly to `dev`.

## Merge workflow

1. Run `./build.sh` locally — must pass
2. Create PR from `dev` to `main`
3. Merge using **"Create a merge commit"** (not squash, not rebase)

Do not squash merge — it creates divergent histories between dev and main,
causing conflicts on every subsequent PR.

## Release workflow

1. Run `./build.sh --all-platforms --encode` locally — must pass (requires sample files)
2. Merge `dev` → `main` via PR (merge commit, not squash)
3. Run `./build.sh --publish --all-platforms` — pushes tested images to GHCR
