# Sottovoce

(Formerly "Transcribe" — renamed 2026-08-01; bundle id `dev.samir.sottovoce`.)

macOS menu bar dictation app backed by OpenAI's `gpt-live-transcribe` realtime
model. Hold a hotkey to dictate (push-to-talk), double-tap it to dictate
hands-free until you double-tap again; transcribed text is inserted at the
cursor of the frontmost app. A floating pill overlay (configurable corner)
shows the current mode.

## Build & run

- Plain SwiftPM (no Xcode project): `make bundle` builds and assembles
  `dist/Sottovoce.app`; `make run` also launches it.
- The `.app` bundle is required — TCC (mic + Accessibility) won't grant
  permissions to a bare executable. `Packaging/Info.plist` is copied into the
  bundle by the Makefile.
- **Signing**: the Makefile signs with the `Apple Development` identity
  (free Apple ID, cert created through Xcode; override with `SIGN_IDENTITY=…`).
  A cert with a **real Team ID is required**: TCC grants survive any stable
  designated requirement, but Keychain item ACLs use `teamid:`-based partition
  lists — with a self-signed cert (no team ID) the identity degrades to the
  per-binary cdhash and every rebuild re-prompts for the Keychain password,
  even after "Always Allow" (tried and failed with a self-signed cert first).
  The cert renews yearly via Xcode; Team ID and leaf CN stay the same, so
  permissions and Keychain access survive renewal too. Falls back to ad-hoc
  (with a warning) if the identity is missing.
- **Gotcha**: codesign failed with "unable to build chain to self-signed
  root" + `errSecInternalComponent` because the machine only had the WWDR
  **G1** intermediate (expired 2023) — Xcode created the cert but didn't
  install the **G3** intermediate that issued it. Fixed by installing
  https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer into the login
  keychain (`security add-certificates`; no trust settings needed, it chains
  to the Apple Root CA in the system roots).

## Non-obvious decisions

- **Provider abstraction**: dictation goes through the `TranscriptionSession`
  protocol. Streaming providers: OpenAI (`TranscriptionClient`, append-only
  live deltas → typed live) and Deepgram (`DeepgramClient`, nova-3 over
  `wss://api.deepgram.com/v1/listen`, raw binary PCM frames, `Token` auth).
  Batch providers subclass `BatchTranscriptionClient` (PCM buffered in
  memory, WAV+multipart upload on stop, 30 min cap): Groq
  (`whisper-large-v3-turbo`, OpenAI-compatible endpoint) and Fish Audio
  (`POST /v1/asr`; **no realtime ASR** — their WebSocket API is TTS-only and
  `s2.1-pro` is a TTS model; OpenRouter likewise has no realtime STT).
  Per-provider API keys are separate Keychain accounts under the same
  service. Delay/keywords/context-prompt options are OpenAI-only.
- **Deepgram delta semantics**: interims are *revisions*, not append-only
  deltas — they must never be typed. The protocol has a dedicated
  `onInterim` (display-only, feeds the overlay preview); stable `is_final`
  segments go through `onCompleted` and are inserted per phrase during
  dictation. `finish()` sends `{"type":"CloseStream"}` and waits for the
  final flush (`Metadata` event) or socket close. Language: `multi` unless
  exactly one language hint is configured.

- **Wire protocol** (docs pages are thin; assembled from the realtime
  transcription guide): WebSocket to
  `wss://api.openai.com/v1/realtime?intent=transcription` with
  `Authorization: Bearer`. On open, send `session.update` with
  `session.type: "transcription"`, model `gpt-live-transcribe`, PCM16 mono
  24 kHz (`audio/pcm`, rate 24000), and **`turn_detection: null`** — the model
  rejects server VAD ("turn detection is not supported by this model"); it
  streams live deltas on its own and the buffer is committed manually on stop.
  Audio goes as base64 in `input_audio_buffer.append`; results arrive as
  `conversation.item.input_audio_transcription.delta` / `.completed`
  (completed fires after the manual commit).
- **Model tuning params** (all optional, inside
  `session.audio.input.transcription`, exposed in Settings → Transcription,
  sent only when set): `languages` (ISO codes), `prompt` (free-text context),
  `keywords` (literal terms; `<`, `>` and newlines are stripped — the API
  forbids them), `delay` (`minimal`/`low`/`medium`/`high`/`xhigh`, latency vs
  accuracy). The model returns no word timestamps, speaker labels, or
  confidence scores. Options are captured at session start
  (`TranscriptionClient.Options.fromPrefs()`), so settings changes apply from
  the next dictation.
- **Insertion strategy** (per the insertion-method setting):
  - *Type live* (default): deltas are typed into the frontmost app as they
    arrive — deltas are assumed append-only. On `completed`, if the final
    transcript extends the typed text, only the missing tail is typed; if the
    model revised earlier text, the typed text stands (no retro-editing).
  - *Paste*: deltas only feed the overlay preview; the completed transcript is
    pasted once on stop.
  On stop, a manual `input_audio_buffer.commit` flushes the buffer; "buffer
  too small/empty commit" API errors are expected then and silently ignored.
- **Hotkey**: a CGEvent tap on the main run loop (needs Accessibility).
  Modifier hotkeys (default: Right ⌥) are tracked via `flagsChanged` and never
  swallowed; regular-key hotkeys are swallowed (down and up) unless pressed
  with ⌘/⌃/⌥/⇧, so a letter hotkey doesn't break normal typing/chords.
  Caps Lock can't be a hotkey (it toggles rather than press/release).
  Tap-vs-hold: hold ≥ 0.30 s = push-to-talk; two taps within 0.40 s = lock.
  A single tap starts capture immediately (so the first words of a
  double-tap-lock aren't lost) and is discarded if no second tap arrives.
  Esc cancels any active dictation (consumed only in that case).
- **Synthetic events**: pasted ⌘V / typed unicode events are marked with
  `eventSourceUserData = 0x54524E53` so our own tap ignores them; pasting
  sets `flags = [.maskCommand]` explicitly so a still-held hotkey modifier
  doesn't merge into the synthetic keystroke.
- **Audio buffering before session ready**: mic capture starts immediately on
  key-down; chunks are queued in the client until `session.updated` arrives,
  then flushed — nothing said during connection setup is lost.
- **Overlay**: borderless non-activating `NSPanel`, `.statusBar` level,
  joins all Spaces + fullscreen, click-through, placed on the screen containing
  the mouse pointer. The panel is oversized (600×150) with 20 pt inner padding
  so the pill's shadow isn't clipped; visibility is animated in SwiftUI.
- **Pause media while dictating** (off by default): implemented with
  AppleScript via `osascript`, not the private MediaRemote framework —
  system-wide "Now Playing" control is restricted to entitled processes since
  macOS 15.4, so only scriptable players are supported (Spotify, Music, VLC;
  browser media can't be paused reliably). State-aware: only players that were
  actually playing get paused, and only those get resumed on teardown (VLC's
  `play` toggles, hence its guarded resume script). Apps that aren't running
  are never scripted — an Apple event would launch them. Scripts run on a
  background queue because a pending Automation-consent dialog would otherwise
  block the main thread (where the event tap lives). Needs
  `NSAppleEventsUsageDescription`; macOS prompts once per player.
- **API key** lives in the Keychain (service `dev.samir.sottovoce`), not
  UserDefaults. Other prefs are UserDefaults (`hotkeyKeyCode`,
  `overlayPosition`, `insertionMethod`, `playSounds`, `languages`).
- Paste insertion saves/restores the clipboard (string flavor only) with a
  0.4 s delay; back-to-back segments keep the *original* user clipboard.
