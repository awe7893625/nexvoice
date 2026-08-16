# 本地模型與免費雲端設定

NexVoice 開源版的建議流程是：

1. 執行 `zsh macos/scripts/install-app.sh`；首次安裝會自動建立 MLX runtime。進階使用者也可單獨執行 `zsh runtime/setup-runtime.sh`。
2. 在 App「設定 → 本地 MLX 模型」填入模型名稱（預設 `eoleedi/Breeze-ASR-25-mlx`；詳見 docs/LOCAL_MODELS.md）。
3. 保持「零費用模式」開啟；此時只會使用本機 `127.0.0.1:5112`。
4. 若要使用免費額度，在「免費雲端 API」輸入 Groq/Gemini key，按「儲存、測試並啟用」。App 會驗證 MLX／Groq／Gemini，成功後自動開啟適用的雲端備援與整理功能。

本地 runtime 介面是受 token 保護的 HTTP API：

- `GET /health`：需要 `X-NexVoice-Local-Token`。
- `POST /`：JSON 會包含 `audio_base64`、固定錄音 `session`、`sequence`、`quality` 與受限的 `vocab_terms`，同樣需要 token。
- 音訊上限 32 MiB；靜音會回傳空字串，不送入 Whisper。
- 詞彙最多傳 64 個 canonical terms，runtime 只把它們放進本機 MLX Whisper 的固定 `initial_prompt`；不會把詞彙當成指令，也不會因此呼叫工具或雲端。
- final 轉錄會在本機完成繁體中文轉換、字典修正、口述標點與保守斷句。詞彙服務短暫離線時會使用 `~/.cache/nexvoice/vocabulary-cache.json` 的 0600 安全快取。

## 詞彙怎麼生效

在 App「詞彙」頁加入 canonical 寫法與「聽起來像」變體，例如：

- 詞彙：`NexVoice`
- 聽起來像：`next voice，nex voice`

下一個錄音 session 會固定一份詞彙快照：canonical 詞先提示 MLX，辨識完成後再以最長變體優先、英文單字邊界及單次掃描修正結果。替換產物不會再次被其他規則處理，因此不會出現 `foo → bar → baz` 的連鎖污染。

App 不會把 API key 放入 URL、log 或 Git。雲端 key 的存在不等於授權；隱私模式與零費用模式會在 pipeline 前阻止雲端路由。
