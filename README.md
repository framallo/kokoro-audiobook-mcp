# kokoro-audiobook-mcp (`kab`)

A native Swift CLI **and** MCP server that turns EPUBs into chaptered **m4b
audiobooks** with [Kokoro](https://huggingface.co/hexgrad/Kokoro-82M) TTS on
Apple Silicon. Built-in queue, live progress/ETA, per-sentence content cache,
and a Claude-ready MCP server — all in one native binary, no Python at runtime.

> Modeled on the proven `ebook2audiobook-mcp` queue, but native and Kokoro-based.

## Status

| Piece | State |
|---|---|
| EPUB → chapters → m4b (chapter markers) | ✅ working |
| Queue + progress/ETA + cancel/move (CLI + MCP) | ✅ working |
| Per-sentence content cache (cheap re-render) | ✅ working |
| Synthesis backend (pluggable, `synthCmd`) | ✅ seam working |
| **English audio** via `kokoro-say` (KokoroSwift/MLX) | 🚧 wiring (MLX build + model download) |
| **Spanish audio** | ⛔ blocked — KokoroSwift is English-only (see [TODO](TODO.md)) |

Out of the box it runs a **silent dry-run** backend that produces a valid,
chaptered m4b — useful for exercising the whole pipeline before the models land.

## Requirements

macOS 14+ (Apple Silicon), Swift 6, `ffmpeg` (m4b), `espeak-ng` (future Spanish).

```bash
brew install ffmpeg espeak-ng
```

## Install

macOS **arm64 only** (Apple Neural Engine).

### Homebrew (one line)

```bash
brew install framallo/tap/kab
```

### Prebuilt binary (no compile)

Download `kab-macos-arm64` from the [latest release](https://github.com/framallo/kokoro-audiobook-mcp/releases/latest), then:

```bash
curl -L -o kab https://github.com/framallo/kokoro-audiobook-mcp/releases/latest/download/kab-macos-arm64
chmod +x kab
xattr -dr com.apple.quarantine kab      # clear the downloaded-file quarantine
./kab --help
```

The binary is ad-hoc codesigned, so Gatekeeper allows it after the `xattr` step.
It still needs the **kokoro-coreml engine + CoreML models at runtime** — see
[Runtime setup](#runtime-setup-engine--models) below.

### Build from source

```bash
git clone https://github.com/framallo/kokoro-audiobook-mcp.git
cd kokoro-audiobook-mcp
make install          # builds release + copies `kab` to /usr/local/bin
# or just: swift build -c release   (binary at .build/release/kab)
```

## Runtime setup (engine + models)

`kab convert` shells out to the **kokoro-coreml** ANE engine, which loads the
pre-converted Kokoro-82M CoreML `.mlpackage` models (~1 GB). The models are **not**
bundled with `kab` (or this repo). Get them once on a fresh machine:

```bash
git clone https://github.com/framallo/kokoro-coreml.git
cd kokoro-coreml
uv sync                                          # Python deps (uv)
uv run python scripts/download_models.py --coreml   # pulls the .mlpackage models from Hugging Face
# (or: bash scripts/setup_bakeoff.sh  — deps + models + exports in one shot)
```

Kokoro-82M is Apache-2.0 and the CoreML conversion is published on Hugging Face
([`mattmireles/kokoro-coreml`](https://huggingface.co/mattmireles/kokoro-coreml)),
so the downloader fetches everything legally — no manual model tarball to attach.

Then point `kab` at the engine repo:

```bash
export KOKORO_COREML_REPO=/path/to/kokoro-coreml   # or: kab config set kokoroRepo /path/to/kokoro-coreml
```

## Usage (CLI)

### `kab convert` — chapters directory → chaptered `.m4b` (real audio)

The one command that actually produces an audiobook. It shells out to the proven
**ANE engine** (`scripts/ane_book.py book` in the `kokoro-coreml` repo — Python
driving the Swift `kokoro-bench` binary over the Apple Neural Engine), streaming
live progress/ETA and leaving **no** `kokoro-bench` process behind on exit.

```bash
kab convert \
  --chapters-dir /path/to/libro/es \
  --glob 'capitulo-*.md' \
  --voice ef_dora --lang e \
  --title 'Mi libro' --artist 'Autor' \
  --out /path/to/libro.m4b
```

| flag | meaning | default |
|------|---------|---------|
| `--chapters-dir` | directory of chapter markdown/text files | (required) |
| `--glob` | chapter filename glob | `capitulo-*.md` |
| `--prepend` | front-matter file spoken first (repeatable) | — |
| `--voice` | Kokoro voice (`ef_dora`, `af_heart`, …) | `af_heart` |
| `--lang` | `a`=English `e`=Spanish `f`=French `i`=Italian `p`=Portuguese | `a` |
| `--title` / `--artist` | metadata | — |
| `--out` | output `.m4b` path | (required) |
| `--speed` / `--drop-title` | speech speed / skip spoken heading | `1.0` / off |

Queue several books and drain them serially on the ANE engine:

```bash
kab ane-enqueue --chapters-dir … --out a.m4b --voice ef_dora --lang e
kab ane-enqueue --chapters-dir … --out b.m4b --voice af_heart --lang a
kab ane-queue-run            # drains serially (the ANE is one shared accelerator)
kab ane-queue-status
```

Point kab at the `kokoro-coreml` repo (default `~/work/libs/kokoro-coreml`):

```bash
kab config set kokoroRepo /path/to/kokoro-coreml   # or export KOKORO_COREML_REPO=…
kab config set runner 'uv run python'              # how to run ane_book.py (default)
```

### EPUB queue (legacy in-process pipeline)

```bash
kab enqueue book.epub --language eng --voice am_adam   # queue a conversion
kab status                                             # whole-queue view (%/ETA)
kab list                                               # every job
kab cancel <job_id>                                    # cancel queued/running
kab move <job_id> 1                                    # reprioritize (1 = next)
kab config voice spa em_alex                           # per-language default voice
```

`enqueue` returns immediately and a background worker drains the queue; poll
`kab status` for live percent and ETA.

## Usage (MCP, for Claude)

```bash
claude mcp add kokoro-audiobook -- kab serve
```

Exposes 7 tools: `enqueue_audiobook`, `queue_status`, `get_job`, `list_jobs`,
`move_job`, `cancel_job`, `list_voices`.

## Real audio (Kokoro)

1. Build the synthesizer: `cd tools/kokoro-say && swift build -c release`.
2. Download the Kokoro-82M **MLX weights** + `voices.npz` into
   `~/.kokoro-audiobook-mcp/models/` (`kokoro.safetensors`, `voices.npz`).
3. Wire it: `kab config set synthCmd <…>/tools/kokoro-say/.build/release/kokoro-say`.

English works today; Spanish is blocked on a Swift Spanish G2P — see [TODO.md](TODO.md).

## Demo / Listen

Short voice samples rendered by the Kokoro engine on the Apple Neural Engine
(GitHub can't embed an audio player, so these are download links). Demo source
texts live in [`demo/`](demo/).

- [English sample — `af_heart`](https://github.com/framallo/kokoro-audiobook-mcp/releases/download/v0.1.0/demo_en.mp3)
- [Spanish sample — `ef_dora`](https://github.com/framallo/kokoro-audiobook-mcp/releases/download/v0.1.0/demo_es.mp3)

## Architecture

`Store` (flock queue) · `Worker` (concurrency, retry, orphan reconcile) ·
`Epub` (spine → sentences) · `Synth` (pluggable backend) · `Convert` (cache +
progress + chapter concat) · `Assemble` (ffmpeg m4b) · `MCPServer` (swift-sdk) ·
`CLI` (ArgumentParser). See [TODO.md](TODO.md) for the roadmap and the
MimikaStudio gap analysis.

## License

MIT © Federico Ramallo
