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

```bash
git clone <this-repo> kokoro-audiobook-mcp
cd kokoro-audiobook-mcp
make install          # builds release + copies `kab` to /usr/local/bin
# or just: swift build -c release   (binary at .build/release/kab)
```

## Usage (CLI)

```bash
kab enqueue book.epub --language eng --voice am_adam   # queue a conversion
kab status                                             # whole-queue view (%/ETA)
kab list                                               # every job
kab cancel <job_id>                                    # cancel queued/running
kab move <job_id> 1                                    # reprioritize (1 = next)
kab config set synthCmd /path/to/kokoro-say            # wire real audio
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

## Voice demos

Per-voice samples (and a demo audiobook) are published as a **GitHub Release**
(kept out of the source tree). Demo source texts live in [`demo/`](demo/).
→ *Release link added once the synth backend is wired.*

## Architecture

`Store` (flock queue) · `Worker` (concurrency, retry, orphan reconcile) ·
`Epub` (spine → sentences) · `Synth` (pluggable backend) · `Convert` (cache +
progress + chapter concat) · `Assemble` (ffmpeg m4b) · `MCPServer` (swift-sdk) ·
`CLI` (ArgumentParser). See [TODO.md](TODO.md) for the roadmap and the
MimikaStudio gap analysis.

## License

MIT © Federico Ramallo
