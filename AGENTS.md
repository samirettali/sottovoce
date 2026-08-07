# Sottovoce

(Formerly "Transcribe" — renamed 2026-08-01; bundle id `com.samirettali.sottovoce`.)

The bundle id changed from `dev.samir.sottovoce` on 2026-08-07, after 0.1.0 had
shipped: reverse DNS of a domain actually owned. It is also the Keychain service
string, so upgrading from 0.1.0 means re-granting Microphone and Accessibility,
re-entering the API keys and losing the UserDefaults prefs — done deliberately
while the only installation was the author's. The cask zaps both plists.

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
- **Signing**: `make bundle` signs with `Developer ID Application` — the *same*
  identity used for distribution, deliberately, so dev and release builds share
  one designated requirement and the TCC grants / Keychain ACLs don't reset when
  switching between them. Falls back to `Apple Development`, then ad-hoc, each
  with a warning (`SIGN_IDENTITY=…` overrides).
  A cert with a **real Team ID is required**: TCC grants survive any stable
  designated requirement, but Keychain item ACLs use `teamid:`-based partition
  lists — with a self-signed cert (no team ID) the identity degrades to the
  per-binary cdhash and every rebuild re-prompts for the Keychain password,
  even after "Always Allow" (tried and failed with a self-signed cert first).
  Certs renew yearly; Team ID and leaf CN stay the same, so permissions and
  Keychain access survive renewal.
  The paid membership issues Developer ID certs under the same team as the
  earlier free Apple ID (`22K9H4B864`), so the switch to Developer ID cost no
  re-prompt and no re-grant of Microphone + Accessibility. (The `(272RW235BP)`
  in the `Apple Development` cert's name is a certificate id, not the team —
  only Developer ID cert names carry the Team ID in parentheses.)
- **Hardened runtime** is on for every build (`--options runtime`), not just for
  release, so dev builds hit the same restrictions the shipped app does. It
  blocks the mic and outgoing Apple events unless claimed, hence
  `Packaging/Sottovoce.entitlements`: `com.apple.security.device.audio-input`
  and `com.apple.security.automation.apple-events`. **No App Sandbox** — the
  CGEvent tap and Accessibility-based insertion can't work inside one.
- **Release**: `make release` → notarised, stapled `dist/Sottovoce-<version>.dmg`.
  It notarises *twice*, the app and then the DMG: the ticket stapled to a DMG
  only covers the app while it's on the mounted image, so the app needs its own
  ticket to launch offline after being dragged to /Applications. Needs a
  notarytool keychain profile named `sottovoce`
  (`xcrun notarytool store-credentials sottovoce --apple-id samir@ettali.com
  --team-id 22K9H4B864 --password <app-specific-password>`; override with
  `NOTARY_PROFILE=…`).
- **DMG layout** (`Packaging/make-dmg.sh`): the image is built read/write, Finder
  is scripted to set the window (600×400, icon view, 128 pt icons, app at
  (150,175) and the `/Applications` symlink at (450,175)), then converted to
  compressed read-only. The layout lives in a `.DS_Store` *inside* the image, so
  everyone sees the same window instead of their own Finder defaults.
  - **No background art on purpose**: a background image is static, but Finder's
    icon labels turn white in dark mode, so a light background with a drawn
    arrow becomes unreadable. Position alone conveys the drag and survives both
    appearances.
  - HFS+, not the APFS default: it's the safer filesystem for a Finder-laid-out
    DMG, and with `zlib-level=9` the image came out smaller too (2.6 MB vs 3.0).
  - The volume is mounted **browsable** (no `-nobrowse`) because Finder has to
    see it to script it, and the mount point is read back from `hdiutil` rather
    than assumed — a stale `/Volumes/Sottovoce` would push the new one to
    `Sottovoce 1` and the AppleScript would address the wrong disk.
  - Scripting Finder needs Automation consent for whatever runs `make dmg`.
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
- **On-device provider** (`parakeet`): Parakeet TDT 0.6B v3 on CoreML/ANE via
  [FluidAudio](https://github.com/FluidInference/FluidAudio). Chosen over
  Whisper (WhisperKit) because it beats large-v3 on accuracy at a quarter of
  the size, streams natively, and — being a transducer — doesn't hallucinate
  text during silences, which is the failure mode that matters for
  push-to-talk. v3 (not v2) because v2 is English-only; v3 covers 25 European
  languages including Italian. Trade-off: no CJK.
  - `ParakeetEngine` (actor) is a singleton that keeps the models **resident
    across dictations** — loading them costs seconds, so per-session loading
    would put that on every hotkey press. `loadTask` dedupes a dictation
    started while Settings is still downloading.
  - They are loaded **ahead of the first dictation**
    (`AppState.preloadLocalModelIfNeeded`): at launch when the provider is
    already `.parakeet`, when Settings switches to it, and when a dictation
    starts. Otherwise the first load happens inside `transcribe`, which for a
    batch provider runs *after* the user stops speaking — the wrong moment to
    do work the user is waiting on. Cheap to over-call, `loadTask` dedupes.
  - Preloading costs far less memory than the model size suggests: CoreML
    memory-maps the weights, so the process stays around 90 MB RSS rather than
    growing by the ~470 MB the models occupy on disk, and those pages are
    evictable. For the same reason neither RSS nor `lsof` can tell you whether
    the models are resident — the files aren't held open once loaded.
    `ParakeetEngine.isLoaded` is the signal.
  - Models are ~470 MB, cached by FluidAudio under
    `~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3`.
    That cache is **shared with any other FluidAudio app** (Hex, Spokenly,
    Voice Ink…), so it may already be populated. The download is explicit in
    Settings → Providers, never lazy on a hotkey press (it takes ~75 s cold).
  - Audio: capture produces 24 kHz PCM16 but Parakeet wants 16 kHz Float32, so
    `ParakeetEngine` converts and resamples via FluidAudio's `AudioConverter`.
  - Batch semantics: it subclasses `BatchTranscriptionClient`, which grew an
    overridable `processBuffer(_:)` (default = WAV + multipart upload) plus
    `deliver`/`fail` so on-device providers reuse the buffering without the
    HTTP path. No live preview; ~110× realtime, so a normal dictation resolves
    in a fraction of a second.
  - Keywords/context-prompt don't apply: Parakeet has no prompt conditioning.
    FluidAudio does ship CTC keyword spotting + vocabulary rescoring
    (`CustomVocabularyContext`), which is the path to wire up if the Keywords
    field should ever work here.
  - `TranscriptionProvider.requiresAPIKey` gates the Keychain check in
    `AppState.startSession` and the first-run "open Settings" nudge.
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
- **Input device selection** (`AudioDevices.swift`, Settings → Dictation):
  without it the engine implicitly takes the system default, which means
  connected AirPods capture through their headset profile and drag any music
  playing through them down with it for the whole dictation. Pinning the
  built-in microphone avoids that.
  - The preference stores the device **UID**, never the `AudioDeviceID`: the
    numeric id is assigned at runtime and gets reused across reboots and
    reconnections, so a stored id would eventually point at a different
    microphone. UIDs like `BuiltInMicrophoneDevice` are stable.
  - The device is set on `inputNode.auAudioUnit` **before** anything reads
    `outputFormat(forBus:)` — the format belongs to the device, so reading it
    first would build the converter for the wrong one. It's also set explicitly
    for "system default", because the audio unit remembers the last device it
    was given and would otherwise keep using a deselected microphone.
  - Input-capable devices are told apart from output-only ones by an empty
    input `kAudioDevicePropertyStreamConfiguration`.
  - A device that disappears mid-dictation throws nowhere and simply stops
    delivering audio; `AVAudioEngineConfigurationChange` is the only signal, so
    `AudioCapture.onInterrupted` listens for it and ends the session with an
    error. A device missing at start falls back to the default with a notice.
- **Input level meter** (`InputLevelMonitor.swift`, next to the picker): its own
  `AVAudioEngine`, because `AudioCapture` only exists during a dictation and the
  meter has to work when nothing is being dictated. Display only — gain belongs
  on the device.
  - **Peak, not RMS.** The overlay's level is RMS, which averages away the short
    transients that actually clip, so an RMS meter reads comfortable while the
    signal is already flat-topped. Fast attack, decay at `level * 0.82` per
    buffer so peaks stay readable; the top segments go red only once samples
    have really reached full scale, not merely because it's loud.
  - Only one engine on the device at a time: while a dictation runs the monitor
    stops and the meter shows `AppState.level` instead.
  - The microphone is **live whenever the Dictation tab is open**, so macOS
    shows its orange indicator, exactly as System Settings does. It's stopped
    from the tab's `onDisappear` *and* the window's, so a missed callback can't
    leave it running. It only starts if microphone access is already granted,
    checked directly rather than through the timer-refreshed `micAuthorized`,
    so opening Settings never triggers a surprise permission prompt.
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
- **API key** lives in the Keychain (service `com.samirettali.sottovoce`), not
  UserDefaults. Other prefs are UserDefaults (`hotkeyKeyCode`,
  `overlayPosition`, `insertionMethod`, `playSounds`, `languages`).
- Paste insertion saves/restores the clipboard (string flavor only) with a
  0.4 s delay; back-to-back segments keep the *original* user clipboard.
