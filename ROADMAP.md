# NexVoice Roadmap

Roadmap 是方向，不代表已完成或承諾日期。完成狀態以 Release 與同一 SHA 的測試
證據為準。

## 現在

- [x] Apple Silicon 原生 macOS App
- [x] 本機 MLX Whisper partial/final transcription
- [x] 21 款 HUD、外框、字幕與主題
- [x] Token-authenticated Loopback Gateway
- [x] OpenAI-compatible transcription subset
- [x] Gemini/Groq/NIM opt-in cloud routing
- [x] AI `doctor`、auto-tune、safe apply 與 `SKILL.md`
- [x] Source install、ZIP/DMG packaging 與 checksum

## 接下來

- [ ] 乾淨 Mac 的完整 installer acceptance matrix
- [ ] Developer ID 簽章與 Apple notarization receipt
- [ ] App 內顯示 doctor/readiness 與模型安裝進度
- [ ] Release manifest 與使用者主動確認的更新流程
- [ ] 更多語言的本地詞彙/標點包

## Windows

- [ ] 原生 Windows tray/HUD client
- [ ] Windows installer 與 portable ZIP
- [ ] faster-whisper / DirectML / CUDA runtime adapter
- [ ] Windows microphone、global hotkey、paste acceptance tests

Windows native 版本完成前，Windows 僅列為 Gateway API Client，不會提供或聲稱
已有 NexVoice Windows EXE。
