# NexVoice

NexVoice is a macOS voice-input app: press a hotkey once to start dictating and press again to stop, or hold for push-to-talk and release to finish. Transcription runs locally on Apple Silicon via MLX Whisper — local-first and zero-cost by default.

## Status

This repository is an open-source release candidate under active hardening. The current candidate includes the native hotkey state machine, ownership handoff with Typeless/Hammerspoon, duplicate-paste protection, privacy/zero-cost routing policy, a bundled authenticated MLX helper, local punctuation and vocabulary injection, signed build/install scripts, and an automated test suite. Public notarization and release approval remain explicit gates.

## Product principles

- Local MLX transcription on Apple Silicon is the default path.
- Cloud STT or cleanup is opt-in, credential-gated, and disabled by zero-cost/privacy mode.
- Audio and transcripts stay on the Mac unless the user explicitly enables a provider.
- One recording session may produce at most one paste.
- NexVoice and Typeless own the global hotkey exclusively; failed handoff fails closed.

## Requirements

- macOS 14 or newer
- Apple Silicon recommended; 16 GB RAM minimum for the turbo local model
- Microphone and Accessibility permission, granted manually in System Settings

## Quick install

```sh
curl -fsSL https://raw.githubusercontent.com/awe7893625/nexvoice/main/install.sh | zsh
```

Builds from source (ad-hoc signature, no certificate needed), installs to
`~/Applications/NexVoice.app`, and sets up the local MLX runtime. Afterwards,
grant Microphone and Accessibility permission in System Settings.

Installing with an AI assistant? Point it at [`llms-install.md`](llms-install.md) —
a structured install guide written for AI agents.

## Build and test

```sh
cd macos
swift test
NEXVOICE_BUILD_KIND=dev zsh scripts/build-app.sh
```

`dev` builds may use an ad-hoc signature. Acceptance/distribution builds require a Developer ID identity and must be verified before installation. Never commit API keys, model caches, or a personal signing identity.

## Runtime

The App bundle ships the authenticated `:5112` helper contract. First install creates a per-user MLX Python environment; audio is sent as bounded bytes with a stable session/sequence rather than a filesystem path. The helper enforces silence, audio, vocabulary and prompt limits, keeps the partial/final models warm, and returns the session identity with the transcript.

The App dictionary is part of the transcription path, not just a CRUD screen. Enabled canonical terms bias the local Whisper decoder, while sounds-like variants are applied once to the final Traditional Chinese transcript with ASCII word boundaries and longest-match priority. Dictated punctuation such as `逗號`、`句號`、`問號` and `換行` is handled locally without an API charge.

The optional legacy HTTP gateway is loopback-only and creates `~/.cache/nexvoice/gateway.token`; API clients must send it as `X-NexVoice-Token`. `/health` is intentionally unauthenticated for process discovery, while transcript/history/settings routes are authenticated.

## Privacy and cloud costs

See [docs/PRIVACY.md](docs/PRIVACY.md) and [docs/CLOUD_PROVIDERS_AND_COSTS.md](docs/CLOUD_PROVIDERS_AND_COSTS.md). NexVoice does not require a paid API for its intended local workflow. Provider keys are never authorization by themselves; the explicit settings toggle and privacy/zero-cost policy must allow a request.

## Contributing and security

Read [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md). Please report vulnerabilities privately before opening a public issue.

## License

The project license and third-party/model notices are release gates and will be added before the first public repository publication. Do not redistribute model weights or provider SDKs without verifying their terms.
