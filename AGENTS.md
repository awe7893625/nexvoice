# NexVoice Developer & AI Agent Context

## Local Stack Overview
- **App**: Native macOS (SwiftUI) in `macos/`
- **Gateway**: Python loopback service in `server/` (Default port: 5111)
- **Local STT**: MLX Whisper helper process (Default port: 5112)
- **Local LLM**: Ollama (`http://127.0.0.1:11434`)

## Core Commands
- `python3 server/agent_cli.py doctor [--json]` — System health check & TCC inspection
- `python3 server/agent_cli.py tune [--json] [--bench] [--apply]` — Model auto-tuning
- `python3 server/agent_cli.py setup-local [--json]` — Print non-interactive setup instructions
- `python3 -m pytest -q server runtime` — Run Python server and runtime unit tests
- `cd macos && swift test` — Run macOS app Swift tests

## Protected Files & Configuration Rules
- Settings DB location controlled by `NEXVOICE_DB_PATH` environment variable.
- Gateway authentication token at `~/.cache/nexvoice/gateway.token` or via `NEXVOICE_GATEWAY_TOKEN`.

## Public API & Privacy Rules
- **Local-First Default**: `privacy_mode` enforces local-only routing.
- **No Secret Leakage**: Doctor and CLI diagnostic outputs must never expose API keys or token secret values.
- **Human TCC Boundary**: Never automate macOS Microphone or Accessibility permission prompts.
- **No Surprise Downloads**: Benchmarks use cached models unless the user explicitly passes `--allow-download`.
- **Safe Tuning**: Auto-tune may change only `local_model` and `cleanup_local_model`; it must preserve cloud/privacy and unknown fields.
