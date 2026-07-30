# NexVoice 疑難排解

先執行：

```bash
python3 server/agent_cli.py doctor --json
```

輸出只包含狀態與修復提示，不會顯示 provider key 或 Gateway token。

## 熱鍵沒有反應

1. 確認執行的是 `~/Applications/NexVoice.app`。
2. 刪除或移走 `/Applications/NexVoice.app` 的重複副本。
3. 在系統設定確認 Accessibility 已授權給同一份 App。
4. 重新開啟 App。不要由 AI 自動操作 TCC 視窗。

## 沒有收到聲音

1. 在系統設定確認 Microphone 權限。
2. 確認輸入裝置音量。
3. 在 NexVoice 設定內測試裝置。
4. 若權限畫面沒有 NexVoice，先由使用者正常啟動 App，再回到系統設定。

## 每次重建都要重新授權

Ad-hoc 簽章可能在每次建置後改變 designated requirement。公開社群包若未提供
Developer ID/notarization receipt，就可能需要重新授權。這不是透過複製 TCC
資料庫可以安全修復的問題。

## Local Runtime 未就緒

```bash
zsh runtime/setup-runtime.sh
python3 server/agent_cli.py doctor --json
```

模型下載需要網路與磁碟空間。Auto-tune benchmark 預設不下載模型；只有在使用者
允許時才使用 `--allow-download`。

## 5111 或 5112 已被占用

```bash
lsof -nP -iTCP:5111 -sTCP:LISTEN
lsof -nP -iTCP:5112 -sTCP:LISTEN
```

確認 PID/程式身分後再由使用者決定是否停止；不要自動終止未知程序。

## Gateway 回傳 401

```bash
export NEXVOICE_TOKEN="$(cat ~/.cache/nexvoice/gateway.token)"
curl -H "X-NexVoice-Token: $NEXVOICE_TOKEN" \
  http://127.0.0.1:5111/api/settings
```

不要把 Token 貼到 Issue、截圖或日誌。

## 雲端 provider 沒有被使用

必須同時滿足：

- `cloud_enabled=true`
- `privacy_mode=false`
- 對應 provider key 存在
- 指定 engine/provider 可用

只設定 API Key 不會自動將資料送上雲端。

## Windows

目前 Windows 可作為 API Client，但沒有官方 NexVoice 原生 EXE。請勿執行第三方
假冒安裝檔；追蹤進度請看 [ROADMAP](../ROADMAP.md)。
