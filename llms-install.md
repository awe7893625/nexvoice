# NexVoice — installation guide & AI contract

Structured instructions for an AI assistant installing or configuring NexVoice on a user's Mac.
Follow the steps in order. Steps marked **HUMAN** cannot be automated — hand them to the user and wait.

## What this installs

A macOS voice-dictation app (`~/Applications/NexVoice.app`) plus a per-user local MLX Whisper runtime (`~/.cache/nexvoice/runtime/`). Everything runs on-device; no account, no API key, no network transcription unless the user explicitly opts in.

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

Optional gateway & agent setup:
```sh
NEXVOICE_SETUP_GATEWAY=1 zsh install.sh
```

To start the gateway explicitly (foreground server, not background daemon):
```sh
python3 server/app.py
```


## Post-install permissions (**HUMAN** required)

macOS TCC permissions cannot be granted programmatically:

1. `open ~/Applications/NexVoice.app`
2. System Settings → Privacy & Security → **Microphone** → enable NexVoice.
3. System Settings → Privacy & Security → **Accessibility** → enable NexVoice (required for pasting the transcript into the focused app).
4. In the app's onboarding, confirm both permissions show as granted.

Note: ad-hoc (dev) builds get a new code signature every rebuild, and macOS ties Accessibility grants to the signature — after reinstalling a dev build the user must re-grant Accessibility.

## Token acquisition & API authorization

The gateway requires token authentication (`X-NexVoice-Token` header) for all sensitive routes:

```sh
# Read gateway auth token
CAT_TOKEN=$(cat ~/.cache/nexvoice/gateway.token)
```

## Gateway & Agent CLI commands

Inspect capabilities and diagnostics via Python CLI:
```sh
python3 server/agent_cli.py doctor [--json]
python3 server/agent_cli.py capabilities [--json]
python3 server/agent_cli.py config-schema [--json]
python3 server/agent_cli.py tune [--json] [--bench --sample FILE.wav] [--allow-download] [--apply] [--config PATH]
python3 server/agent_cli.py setup-local [--json]
```

curl examples:
```sh
# Health check (unauthenticated)
curl -s http://127.0.0.1:5111/health

# Get settings (token required)
curl -s -H "X-NexVoice-Token: $CAT_TOKEN" http://127.0.0.1:5111/api/settings

# Update settings (strictly allowlisted JSON body via POST)
curl -s -X POST -H "X-NexVoice-Token: $CAT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"engine_default": "local", "privacy_mode": true}' \
  http://127.0.0.1:5111/api/settings

# OpenAI-compatible subset transcription endpoint (/v1/audio/transcriptions supports standard file uploads and returns text)
curl -s -H "X-NexVoice-Token: $CAT_TOKEN" \
  -F "file=@sample.wav" \
  http://127.0.0.1:5111/v1/audio/transcriptions

```

## Local & Cloud configuration rules

- **Privacy / Local-first**: Set `privacy_mode: true` to enforce 100% offline transcription.
- **Gateway STT**: Gateway STT cloud provider is Gemini only (`GEMINI_API_KEY`).
- **Cleanup engines**: Text cleanup can use local Ollama (`cleanup_local_model`) and optional Groq/NIM/Gemini cloud models when `cloud_enabled: true` and `privacy_mode: false`. Note: `OPENAI_API_KEY` is not a gateway provider.
- **Safe auto-tune**: `tune` is a dry run unless `--apply` is present. Apply changes only `local_model` and `cleanup_local_model`, preserves all cloud/privacy and unknown fields, writes the JSON config atomically, and activates the same values in the Gateway SQLite settings.
- **Windows**: Windows clients can call the authenticated Gateway API. The native HUD app and local MLX runtime currently require Apple Silicon macOS; do not claim a Windows EXE exists.

## Rollback & Uninstall

> [!NOTE]
> The `install.sh` installer automatically creates a backup of `~/Applications/NexVoice.app` before updating and performs automatic rollback if building or installing the new version fails.

```sh
# Stop app
osascript -e 'tell application "NexVoice" to quit' 2>/dev/null || true

# Complete uninstall
rm -rf ~/Applications/NexVoice.app ~/.cache/nexvoice ~/.local/share/nexvoice
```

## Troubleshooting

- **Build fails with a sandbox error** — ensure `NEXVOICE_SWIFTPM_DISABLE_SANDBOX=1` is set.
- **Port occupied** — find with `lsof -i :5112` or `lsof -i :5111` and terminate process.
- **Hotkey does nothing** — verify Accessibility permission in System Settings.
