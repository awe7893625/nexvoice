# NexVoice — Local-First macOS Voice Dictation App

NexVoice is a native macOS voice-dictation app built for Apple Silicon: press a hotkey once to start dictating and press again to stop, or hold for push-to-talk and release to finish. Transcription runs locally via MLX Whisper — local-first, privacy-focused, and zero-cost by default.

## App Features & Design

- **Native macOS SwiftUI App**: Ultra-fast hotkey response, with test suites covering Swift unit tests, runtime contract tests, and gateway tests.
- **3 App Visual Themes**: 純淨 (Pristine), 設計工房 (Studio), and 曜石 (Obsidian).
- **21 Dynamic HUD Styles & 7 Frame Treatments**: 亮條, 膠囊光暈, 等離子柱, 液態脈衝, 流光絲帶, 琉璃, 極光, 光球, 虹核, 赤霞, 彗尾, 雙螺旋, 水銀, 電漿, 日蝕, 煙霧, 橫煙, 海浪, 絲綢氣流, 極光霧, 墨滴擴散, with customizable frames (無邊框, 髮絲細邊, 流光邊, 呼吸光環, 超薄無底, 微光流體, 浮雕).
- **Local-First & Opt-in Cloud Routing**: Seamless fallback between local Apple Silicon MLX, local Ollama, and opt-in cloud models (Gateway cloud STT is Gemini-only; optional cloud cleanup supports Groq, NIM, or Gemini when enabled; App directly supports Groq and Gemini integrations, with Groq utilizing an OpenAI-compatible API, while the Gateway exposes an inbound OpenAI-compatible subset endpoint).
- **Privacy & Security Guarantee**: All sensitive endpoints require `X-NexVoice-Token`. Zero arbitrary remote command execution. Strictly no data leaves your Mac unless explicitly configured.

## Open Source Project

This repository is released under the **MIT License**. The open-source project includes:
- Native hotkey state machine with duplicate-paste prevention.
- Bundled authenticated MLX helper (`:5112`) and loopback HTTP gateway (`:5111`).
- Agent-friendly discovery via `python3 server/agent_cli.py doctor`.
- Automated test suites for runtime services and gateway logic.

## Requirements

- macOS 14.0 or newer (Apple Silicon `arm64` required for local MLX)
- Xcode Command Line Tools (`xcode-select --install`)
- Python 3.10+ (for local MLX runtime)

## Quick Install

```sh
curl -fsSL https://raw.githubusercontent.com/awe7893625/nexvoice/main/install.sh | zsh
```

Installing via an AI Assistant? See [`llms-install.md`](llms-install.md) for a structured step-by-step contract.

To start the optional local Python HTTP Gateway:

```sh
python3 server/app.py
```

## Build and Test

```sh
# Run Python Gateway & Agent tests
pytest server/

# Build Web Showcase site
npm --prefix website run build

# Build macOS SwiftUI App (requires Swift toolchain)
cd macos && swift test
```

## API & Integrations

NexVoice provides an OpenAI-compatible subset `/v1/audio/transcriptions` endpoint alongside REST APIs for settings (POST `/api/settings`), vocabulary, and agent discovery. See [docs/LOCAL_RUNTIME_AND_PROVIDERS.md](docs/LOCAL_RUNTIME_AND_PROVIDERS.md) and [docs/PRIVACY.md](docs/PRIVACY.md) for details.

## License

This project is licensed under the [MIT License](LICENSE).

