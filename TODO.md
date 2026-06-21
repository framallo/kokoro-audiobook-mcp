# TODO — kokoro-audiobook-mcp (`kab`)

Potential features, by priority. Captures everything discussed (incl. the
MimikaStudio gap analysis) plus the known blockers.

## P0 — make it real
- [ ] **English synthesis (real audio)** via `kokoro-say` (KokoroSwift / MLX / Metal).
      Needs: download the Kokoro-82M MLX weights + `voices.npz`, then
      `kab config set synthCmd <…>/kokoro-say`. (Build of MLX in progress.)
- [ ] **Spanish synthesis — BLOCKED.** The vendored KokoroSwift is English-only
      (its `Language` enum has no `es`; `eSpeakNGSwift` is commented out in its
      `Package.swift`; Misaki G2P covers English only). Options:
      - (a) enable `eSpeakNGSwift` in the vendored package + add `Language.es` + Spanish voices;
      - (b) shell out to the installed `espeak-ng` for phonemes → feed the model;
      - (c) use the kokoro-coreml ANE pipeline with a Swift G2P.
      Pick one before ES audiobooks work natively.
- [ ] **Easy install for others** — Homebrew tap / prebuilt release binary / install script.

## P1 — core quality & speed
- [ ] **ANE/CoreML backend** (kokoro-coreml) for max speed (faster than MLX). Needs Swift G2P + token/voice prep (kokoro-bench expects pre-tokenized input).
- [ ] **More input formats**: PDF, DOCX, TXT, Markdown (currently EPUB only).
- [ ] **Real voice catalog** in `list_voices` (reflect downloaded voices) + voice preview/audition.
- [ ] **Generation controls**: seed (reproducibility), per-chapter voice.
- [ ] **MCP handshake**: verify initialize/tools/list/call against a real client; firm up the stdio keepalive.
- [ ] **Worker hardening**: cleaner detached daemon, log rotation.

## P2 — product parity (vs MimikaStudio)
- [ ] **Voice cloning** (3s reference) — add Qwen3-TTS / Chatterbox backends.
- [ ] **Multi-engine** (Kokoro / Qwen3 / Chatterbox) selectable per job.
- [ ] **More languages** (Qwen3 ~10, Chatterbox ~23).
- [ ] **Subtitles** (SRT/VTT) aligned to chapters/sentences.
- [ ] **Crossfade** between segments (currently plain concat).
- [ ] **REST API** (HTTP) alongside MCP.
- [ ] **Read-aloud / live playback** + sentence highlighting (TUI).
- [ ] **Advanced controls**: temperature, top-p/k, repetition penalty, style instructions.

## P3 — polish
- [ ] GUI (out of scope near-term; Mimika covers this).
- [ ] Universal binary + notarization.
- [ ] Tests (EPUB parsing, queue, m4b assembly).
- [ ] Demo audiobook + per-voice demos published as a GitHub Release.

## Edge to keep (vs Mimika)
- Native single binary, headless, scriptable (no Flutter / Python servers).
- Per-sentence content cache → re-rendering an edited book reuses unchanged audio.
- Targets ANE (potentially faster than Mimika's MPS/CPU Kokoro at ~60 chars/sec).
- Purpose-built: EPUB → m4b + queue + MCP, end to end.
