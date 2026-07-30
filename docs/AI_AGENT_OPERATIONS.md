# NexVoice AI Agent Operations (AI 代理維運指南)

本文檔為 AI Agent（如 Claude, Codex, Cursor 等）操作 NexVoice 系統提供標準化的診斷、調優與維運流程說明。

## 1. 診斷與健檢 (Doctor)

透過 Agent CLI 執行非破壞性、非互動式的系統與依賴項目檢查：

```bash
python3 server/agent_cli.py doctor --json
```

### 檢查項目與輸出規範
- **schema_version**: 穩定版本識別號（如 `"1.0"`）。
- **status**: 全域狀態（`HEALTHY`, `DEGRADED`, 或 `BLOCKED`）。
- **checks**: 包含 `id`, `status` (`PASS`/`WARN`/`FAIL`/`HUMAN`/`BLOCKED`), `message`, `fix`, `automatable`。
- **權限邊界**: TCC 麥克風與輔助功能 (Accessibility) 權限標記為 `HUMAN`/`BLOCKED`，絕不觸發 macOS 系統權限彈窗。
- **金鑰安全**: 檢查雲端 API 金鑰的存在性（如 `GEMINI_API_KEY`, `GROQ_API_KEY`），絕不印出金鑰明文值。

## 2. 自動調優 (Tune)

根據 Apple Silicon 晶片型號、物理記憶體 (RAM) 及剩餘磁碟空間，自動推薦最佳的 MLX 與 cleanup 模型：

```bash
# 預覽 recommended 變更 (Dry Run)
python3 server/agent_cli.py tune --json

# 執行基準測試（僅使用本機快取模型與範例，未帶 --allow-download 時絕不下載）
python3 server/agent_cli.py tune --json --bench

# 交易式套用設定（安全備份 + 原子覆蓋 + 失敗自動回滾）
python3 server/agent_cli.py tune --json --apply --config ./config.json
```

### 套用原則
- 僅修訂 `local_model` 與 `cleanup_local_model` 等本機模型設置。
- 同步更新 JSON 與 Gateway 實際讀取的 SQLite settings；回傳的
  `database_path` 與 `activated_settings` 可供 Agent 驗證。
- 絕不更動隱私模式 (`privacy_mode`) 或雲端開關 (`cloud_enabled`)。
- 具備冪等性 (Idempotent)，重複執行不會破壞配置。
- 8 GB 建議 `whisper-small`；16 GB 以上建議 `whisper-large-v3-turbo`。
- 本地文字整理預設建議 `qwen2.5:3b`，32 GB 以上可使用 `qwen2.5:7b`。
- 未提供 WAV、缺少依賴或模型未快取時，benchmark 必須回報 `NOT_RUN`，不能捏造速度。

## 3. 本地設定導引 (Setup Local)

印出非互動式的下一步操作指令與說明：

```bash
python3 server/agent_cli.py setup-local --json
```

## 4. 人工操作邊界 (HUMAN Boundaries)

下列操作無法由 AI Agent 自動化完成，需交由人類使用者處理：
1. **麥克風權限 (Microphone TCC)**: 系統設定 → 隱私權與安全性 → 麥克風 → 啟用 NexVoice。
2. **輔助功能權限 (Accessibility TCC)**: 系統設定 → 隱私權與安全性 → 輔助功能 → 啟用 NexVoice（用於自動貼上功能）。

## 5. Windows 邊界

Windows 程式或自動化工具可呼叫 NexVoice Gateway 的 Token 驗證 REST /
OpenAI-compatible subset API；目前原生 HUD 桌面 App 與 MLX Whisper Runtime
仍限定 Apple Silicon macOS。文件或 AI 不得聲稱已提供 Windows 原生 EXE。

原生 macOS App 連線 Gateway 時採 HMAC-SHA256 request/response challenge，
不會直接傳送共享密鑰；外部 Agent 使用 Token header。透過 API 可選的本機
STT 模型受 allowlist 限制，新增模型必須先經程式碼審核，不能用任意名稱
觸發未核准下載。
