# 本地模型與免費雲端設定

NexVoice 開源版的建議流程是：

1. 執行 `zsh macos/scripts/install-app.sh`；首次安裝會自動建立 MLX runtime。進階使用者也可單獨執行 `zsh runtime/setup-runtime.sh`。
2. 在 App「設定 → 本地 MLX 模型」填入模型名稱（預設 `mlx-community/whisper-large-v3-turbo`）。
3. 保持「零費用模式」開啟；此時只會使用本機 `127.0.0.1:5112`。
4. 若要使用免費額度，在「免費雲端 API」輸入 Groq/Gemini key，按「儲存、測試並啟用」。App 會驗證 MLX／Groq／Gemini，成功後自動開啟適用的雲端備援與整理功能。

本地 runtime 介面是受 token 保護的 HTTP API：

- `GET /health`：需要 `X-NexVoice-Local-Token`。
- `POST /`：JSON 會包含 `audio_base64`、固定錄音 `session`、`sequence`、`quality` 與受限的 `vocab_terms`，同樣需要 token。
- 音訊上限 32 MiB；靜音會回傳空字串，不送入 Whisper。
- 詞彙最多傳 64 個 canonical terms，runtime 只把它們放進本機 MLX Whisper 的固定 `initial_prompt`；不會把詞彙當成指令，也不會因此呼叫工具或雲端。
- final 轉錄會在本機完成繁體中文轉換、字典修正、口述標點與保守斷句。詞彙服務短暫離線時會使用 `~/.cache/nexvoice/vocabulary-cache.json` 的 0600 安全快取。

## 詞彙怎麼生效

- `GET /api/settings` 與 `POST /api/settings`：讀取與以 JSON POST 更新 gateway 設定。
- `/v1/audio/transcriptions`：OpenAI 相容子集端點，接收 multipart 音訊檔案並回傳 JSON 轉錄文字。

## STT 與 AI 整理供應商

- **Gateway STT 雲端提供商**：僅限 Gemini（`GEMINI_API_KEY`）。
- **AI 整理提供商**：支援本機 Ollama（`cleanup_local_model`），以及當 `cloud_enabled=true` 且 `privacy_mode=false` 時可選用 Groq (`GROQ_API_KEY`)、NIM (`NVDA_NIM_KEY_1` 至 `NVDA_NIM_KEY_4`) 與 Gemini。
- **注意**：`OPENAI_API_KEY` 並非 gateway 支援的 STT 或 cleanup 供應商。
