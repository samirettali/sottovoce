# Sottovoce

Minimal macOS dictation. Lives in the menu bar, stays out of the way, and types
what you say into whatever app you're already in. A floating pill shows what
it's doing.

- **Hold** the dictation key (default: **Right ⌥**) → push-to-talk; release to
  insert the text at your cursor.
- **Double-tap** it → hands-free dictation; double-tap again to stop.
- **Esc** cancels a dictation without inserting anything.

Requires macOS 14 or later.

## Providers

Pick one in Settings → Providers. Each keeps its own API key, so you can switch
without re-entering anything.

| Provider | Model | How text arrives |
| --- | --- | --- |
| OpenAI | `gpt-live-transcribe` | live, word by word while you speak |
| Deepgram | `nova-3` | streaming, inserted phrase by phrase |
| Groq | `whisper-large-v3-turbo` | on release, in one go |
| Fish Audio | ASR | on release, in one go |
| On-device | Parakeet TDT 0.6B v3 | on release, in one go |

The on-device provider needs no API key and no network: it runs on the Neural
Engine and nothing leaves your Mac. It covers 25 European languages. The models
are ~470 MB and download once from Settings → Providers; the cache is shared
with other apps built on FluidAudio, so it may already be on your machine.

## Install

Download the DMG from the [releases page](../../releases) and drag Sottovoce to
Applications. It's signed and notarised, so it opens without any warning.

Or build it yourself:

```sh
make run
```

## Setup

1. Enter the API key for your chosen provider in Settings (opens automatically
   on first run; keys are stored in the Keychain, never on disk).
2. Grant **Microphone** and **Accessibility** when prompted. Both are needed:
   one to hear you, the other for the global hotkey and to type into other apps.

Everything else is optional: dictation key, overlay corner, insertion method
(simulated typing vs. paste), sounds, pausing media players while you dictate,
and language hints. OpenAI additionally accepts a context prompt, literal
keywords, and a latency/accuracy trade-off.

## Development

Plain SwiftPM, no Xcode project.

```sh
make bundle   # build and assemble dist/Sottovoce.app
make run      # the same, then launch it
make release  # signed, notarised, stapled DMG
```

The `.app` bundle is required even for development: macOS won't grant
microphone or Accessibility permission to a bare executable. See `AGENTS.md`
for how signing, notarisation and the rest of the pipeline fit together.

## License

MIT
