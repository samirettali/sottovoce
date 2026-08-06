# Sottovoce

Minimal macOS dictation, powered by OpenAI's `gpt-live-transcribe` realtime
model. Lives in the menu bar; a floating pill shows what it's doing.

- **Hold** the dictation key (default: **Right ⌥**) → push-to-talk; release to
  insert the text at your cursor.
- **Double-tap** it → hands-free dictation; double-tap again to stop.
- **Esc** cancels a dictation without inserting anything.

## Setup

```sh
make run
```

1. Enter your OpenAI API key in Settings (opens automatically on first run;
   stored in the Keychain).
2. Grant **Microphone** and **Accessibility** when prompted (both are needed:
   audio capture + global hotkey/text insertion).
3. Optionally change the dictation key, overlay corner, insertion method
   (paste vs. simulated typing), and language hints.

For reliable permissions across rebuilds, copy `dist/Sottovoce.app` to
`/Applications`.

## Release

`make release` produces a signed, notarised and stapled
`dist/Sottovoce-<version>.dmg`. It needs a `Developer ID Application`
certificate in the login keychain and a notarytool keychain profile:

```sh
xcrun notarytool store-credentials sottovoce \
  --apple-id <apple id> --team-id <team id> --password <app-specific password>
```
