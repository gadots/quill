# CLAUDE.md

Guidance for Claude Code sessions working in this repository.

## What quill is

A fully local macOS meeting recorder and transcriber. One menu-bar click records
the mic and all system audio as two separate tracks; on stop, both are
transcribed on-device and merged into a speaker-tagged transcript. Nothing leaves
the machine. Single Swift binary, no `.app` bundle, no dock icon.

## Build and test

```sh
swift build                 # debug
swift build -c release      # what gets installed
swift test                  # QuillCore only — see below
```

Requires macOS 15+ and Xcode 16+ (`swift-tools-version:6.0`, Swift 6 language
mode). CI runs `swift build` + `swift test` on a `macos-15` runner
(`.github/workflows/ci.yml`).

**Under Swift 6, `Error` implies `Sendable`.** Every associated value in a thrown
enum must be Sendable too. This is why `MicRecorder.RecorderError.formatUnsupported`
carries a `String` and not the `AVAudioFormat` — capture the rendered description
at the throw site. The repo did not build at all until this was fixed; expect the
same class of error when adding error cases that carry framework types.

## Architecture

Two targets, and the split is deliberate:

- **`Sources/QuillCore/`** — pure Foundation. No AVFoundation, no Core Audio, no
  AppKit. This is the only code the test target can import, so anything worth
  testing belongs here.
- **`Sources/quill/`** — everything that touches Apple frameworks, plus `@main`.
  Depends on `QuillCore`.

Keep that boundary. When adding logic, ask whether it can live in `QuillCore`; if
it can, put it there and test it. The `Info.plist` linker flag in `Package.swift`
must stay on the `quill` executable target — it embeds the plist into the binary
so TCC can attribute permissions to quill when it runs as a LaunchAgent.

### The capture path

| File | Role |
|---|---|
| `Audio/MicRecorder.swift` | Default input device via `AVAudioEngine` tap, AAC mono into CAF. Optional voice processing (echo cancellation) with a first-second liveness check and a raw fallback |
| `Audio/SystemAudioRecorder.swift` | All system output via a Core Audio process tap (macOS 14.2+) through a private aggregate device |
| `Audio/HostClock.swift` | mach absolute-time conversions. The one clock both tracks are stamped from |
| `RecordingSession.swift` | Owns one session folder, both recorders, and `meta.json` |

### The transcription path

`TranscriptionCoordinator` is a serial queue of session folders. The filesystem
*is* the queue: a folder with audio and no `transcript.json` is pending, so a
crash or quit just retries on the next launch. `ParakeetEngine` sits behind the
`TranscriptionEngine` protocol; adding an engine should not touch the
coordinator.

### Invariants worth not breaking

- **CAF, not m4a.** CAF needs no finalization pass, so everything written before a
  crash is still readable. That is the whole reason the format was chosen.
- **`meta.json` is written at session start** with `"status": "recording"`, then
  rewritten with `"finished"` at stop. Both writes atomic.
- **Both tracks are aligned on `mHostTime`**, not `Date()`. The callbacks already
  receive the real stamp; use it. Per-track `measured_sample_rate` corrects the
  drift between the mic device's clock and the tap aggregate's, which accumulates
  over a long meeting.
- **A live session must never be transcribed.** The coordinator tracks the
  recording session and a claimed-set; a scan must skip both.
- **`run` never exits non-zero on a failed check.** The LaunchAgent uses
  `KeepAlive{SuccessfulExit: false}`, so a non-zero exit is an infinite respawn
  loop. Surface problems in the menu bar instead. `doctor` keeps its non-zero exit.

## Conventions

- Comments explain *why*, especially where the code looks odd — most of the odd
  parts are load-bearing (see `.issues/rca-001` for the voice-processing graph).
- Config accessors in `QuillCore/Config.swift` keep their signatures; the typed
  `QuillConfig` is an implementation detail behind them.
- Do not accept a config key that nothing reads. An ignored key is
  indistinguishable from a typo, which is the failure the typed config exists to
  prevent. Add the key when the code honours it.
- New thresholds go in as named constants with a comment, not literals.

## Testing reality

`swift test` covers `QuillCore` only: segment grouping, transcript rendering and
schema, session metadata parsing and recovery, config precedence and unknown
keys, and the alignment maths. That is real coverage of real logic, and it is
also the whole of the automated safety net.

**It proves nothing about audio.** No test exercises `MicRecorder`,
`SystemAudioRecorder`, the menu bar, or the LaunchAgent. Changes there are
verified by recording on a real Mac — there is no substitute. If you are working
from an environment without a Mac (or without a Swift toolchain at all), CI is
your only compiler: land changes in small commits and let each one go green
before building on it.

Highest-risk unexercised code, in order:

1. `UI/MenuBarController.swift` → `showProblems` — computes insertion indices into
   an `NSMenu` that already holds fixed items, and only runs when a doctor check
   fails, so the happy path never reaches it.
2. The host-clock observation in both recorders — never seen a real buffer.
3. `Problem.settingsPane` deep links — the Settings anchors are unverified on
   macOS 15.

## Roadmap

Phases 0 and 1 are merged (PR #1): CI, the `QuillCore` split and first tests, the
typed config, and the three data-loss fixes (interrupted sessions never being
transcribed, the launchd respawn loop, and `Date()`-based track alignment).

The audit these came from is in PR #1's description: 25 findings, `P0` = data loss
or silent failure, `P1` = a real user-facing bug, `P2` = quality.

### Blocking everything below

Manual verification on a Mac of what Phase 1 landed. The alignment fix has never
run on real hardware, and the echo suppression below is built directly on top of
it — if alignment is wrong, that work rests on nothing. Roughly 15 minutes: a
short recording, then confirm the same event lands within ±50 ms on both tracks,
and that neither track is digitally silent.

### Recommended order

This reorders the original plan. The original put capture robustness first, to
protect the raw data before building on it — still sound in the abstract, but
Spanish is unusable *today*, and echo doubling is visible in the default config.

**1 · P1-7 — level metering and a silent-track alert.** Continuous RMS/peak per
track (100 ms windows). Feeds a meter in the menu bar and an alert when one track
is silent for >60 s while the other has signal. Small, immediately visible, and
it is what automatically catches the silent-track failure that a TCC/cdhash
change produces after every rebuild.

**2 · P1-14 + A1 — preprocessing and Spanish.** An `AudioPreprocessor` producing
16 kHz mono `[Float]` in chunks, feeding the engine with `TdtDecoderState` carried
across them. Resolves two open unknowns: whether a 2-hour session loads entirely
into memory, and whether the stereo system track is downmixed correctly rather
than losing a channel. Then make the Parakeet model selectable and add a language
setting.

Parakeet v2 vs v3, measured: v2 is English-only and better on English long-form
(3.4/7.1% WER vs 5.1/8.9%) — which is quill's actual case, hour-long meetings.
v3 covers 25 European languages plus Japanese, with Spanish at 3.45% WER on
FLEURS. So make it selectable rather than choosing: default v3, keep v2 for
English. Both are `AsrModels.downloadAndLoad(version:)` in FluidAudio; the
version is a value, not a different library. Each model is ~600 MB in cache, so
`doctor` should report which is present and only the configured one should
download.

**3 · P1-13 — cross-track echo suppression.** With voice processing off (the
default since `8ab6ebb`), recording through speakers puts the far end in both
tracks, so the transcript carries it twice: once as `them`, once as reverberated
`me`. Mark a mic segment as echo when it overlaps a system segment in time *and*
has high fuzzy token similarity, preserving segments with substantial unique mic
words so interruptions and double-talk survive. `.issues/rca-001` sketches this.
A sturdier variant correlates energy envelopes to estimate echo delay and gain
instead of deciding on text alone. Depends on the alignment fix being verified.

**4 · The rest of Phase 2 — capture robustness.**
- **P1-4** Data races. `MicRecorder` is `@unchecked Sendable` and mutates `file`
  and the clock counters from the tap callback while main reads and nils them.
  `fallBackToRaw()` dispatches to main from inside the callback and deletes the
  file while the callback may still be writing it. Give an `AudioWriter` sole
  ownership of the `AVAudioFile`; callbacks hand it buffers. The compiler does not
  catch this because the Core Audio block is not `@Sendable`.
- **P1-5** No dropout accounting. Encode and disk write happen on the capture
  callback; a stall silently loses buffers and a failed write prints one stderr
  line and continues. Ring buffer plus counters surfaced in the menu bar and
  `meta.json`.
- **P1-6** No survival of device changes or sleep. Nothing observes
  `AVAudioEngineConfigurationChange`, default-output changes, or
  `NSWorkspace.willSleepNotification`, and the tap format is read once and
  captured in the IO proc — a sample-rate change makes the buffer list mismatch
  the format. Close the current file cleanly, open a new segment, record the cut
  in `meta.json`.
- **P1-8** Honest failure. When the raw mic fallback fails, the session continues
  with no mic track and says so only on stderr.

### Later

- **Phase 3 remainder** — diarization of the system track (`them-1`/`them-2`, and
  FluidAudio ships it), VAD to skip silence, inverse text normalization, custom
  vocabulary, a Whisper fallback engine, per-word confidence.
- **Phase 4** — `quill transcribe <file>` for arbitrary audio, `quill sessions
  list/show/export`, full-text search across transcripts, `quill summarize` with a
  local LLM **on demand only** (never automatic; local only), a per-process tap
  instead of the global one, audio retention policy.
- **Plumbing** — a stable code-signing identity so TCC stops treating each rebuild
  as a new program (P2-21), a real system-audio check in `doctor` (P2-24),
  single-instance enforcement (P2-25), `on_stop` hook timeouts and output capture
  (P2-19), `0700` session directories (P2-12).

### Decisions already taken

- quill stays a **meeting recorder**. Global push-to-talk dictation (the Wispr
  Flow/Superwhisper shape) is out of scope. Custom vocabulary is the one idea
  borrowed from there.
- Any LLM work is **local only** and **on demand** — no automatic summaries.
- The Parakeet model is **selectable**, not chosen for the user.
