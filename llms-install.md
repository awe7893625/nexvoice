# NexVoice — installation guide for AI agents

Structured instructions for an AI assistant installing NexVoice on a user's Mac.
Follow the steps in order. Steps marked **HUMAN** cannot be automated — hand them
to the user and wait.

## What this installs

A macOS voice-dictation app (`~/Applications/NexVoice.app`) plus a per-user local
MLX Whisper runtime (`~/.cache/nexvoice/runtime/`). Everything runs on-device;
no account, no API key, no network transcription unless the user later opts in.

## Prerequisites (verify before starting)

| Check | Command | Requirement |
|---|---|---|
| macOS version | `sw_vers -productVersion` | 14.0 or newer |
| CPU | `uname -m` | `arm64` (Apple Silicon) for local transcription |
| Xcode CLT | `xcode-select -p` | must succeed; else **HUMAN**: `xcode-select --install` |
| Swift | `swift --version` | any recent toolchain |
| Python | `python3 --version` | 3.10+ |
| Disk | — | ~4 GB free (MLX models are downloaded on first setup) |

## Install (one command)

```sh
curl -fsSL https://raw.githubusercontent.com/awe7893625/nexvoice/main/install.sh | zsh
```

Or from a clone:

```sh
git clone https://github.com/awe7893625/nexvoice.git && cd nexvoice && zsh install.sh
```

This builds from source with an ad-hoc signature (no certificate needed),
installs to `~/Applications/NexVoice.app`, and sets up the local MLX runtime.
First run downloads Whisper model weights — allow several minutes.

Useful environment overrides:

- `NEXVOICE_SKIP_RUNTIME_SETUP=1` — skip MLX environment/model download (app
  will prompt for runtime setup later).
- `NEXVOICE_SIGN_IDENTITY='Developer ID Application: ...'` plus
  `NEXVOICE_INSTALL_BUILD_KIND=acceptance` and `NEXVOICE_EXPECTED_TEAM_ID=...` —
  stable signed builds (Accessibility permission then survives rebuilds).

## Post-install (HUMAN required)

macOS TCC permissions cannot be granted programmatically:

1. `open ~/Applications/NexVoice.app`
2. System Settings → Privacy & Security → **Microphone** → enable NexVoice.
3. System Settings → Privacy & Security → **Accessibility** → enable NexVoice
   (required for pasting the transcript into the focused app).
4. In the app's onboarding, confirm both permissions show as granted.

Note: ad-hoc (dev) builds get a new code signature every rebuild, and macOS
ties Accessibility grants to the signature — after reinstalling a dev build the
user must re-grant Accessibility.

## Verify

```sh
pgrep -x NexVoice                       # app process exists
pgrep -f nexvoice_local_runtime         # bundled MLX helper is running
```

Then a **HUMAN** functional check: focus any text field, press `Option` once,
speak, press `Option` again — the transcript should paste within a few seconds.
`Esc` cancels a recording without pasting.

Do not probe `127.0.0.1:5112` directly: the local runtime API is authenticated
with an HMAC challenge-response bound to a per-user secret file; unauthenticated
requests return 401 by design.

## Local runtime API (for integrators)

The app talks to its bundled helper on `127.0.0.1:5112` using HMAC-SHA256
request/response proofs derived from `~/.cache/nexvoice/local-runtime.token`
(0600, per-user). The contract, capabilities, and identity handshake are
documented in `docs/LOCAL_RUNTIME_AND_PROVIDERS.md` and implemented in
`runtime/nexvoice_local_runtime.py` / `macos/Sources/NexVoice/LocalRuntimeContract.swift`.
Third-party processes should not bind or call this port; it is an internal,
identity-checked channel owned by the app.

## Update

Re-run the install command. The installer gracefully stops the running app,
backs up the previous version next to it (`NexVoice.app.previous.*`), and rolls
back automatically if the swap fails.

## Uninstall

```sh
osascript -e 'tell application "NexVoice" to quit' 2>/dev/null
rm -rf ~/Applications/NexVoice.app ~/Applications/NexVoice.app.previous.*
rm -rf ~/.cache/nexvoice ~/.local/share/nexvoice
```

## Troubleshooting

- **Build fails with a sandbox error** — the installer already sets
  `NEXVOICE_SWIFTPM_DISABLE_SANDBOX=1`; ensure it is not overridden.
- **"port 5112 is still occupied"** — another process holds the runtime port;
  the installer fails closed rather than killing unknown PIDs. Find it with
  `lsof -i :5112` and stop it, then re-run.
- **Hotkey does nothing** — almost always a missing/stale Accessibility grant
  (see Post-install). Toggle the app's enable switch on the home page after
  re-granting.
- **Transcript is empty for quiet audio** — intentional: a silence guard
  suppresses Whisper hallucinations on near-silent recordings.
