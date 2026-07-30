# Changelog

本專案遵循語意化版本概念；公開下載檔的簽章與 notarization 狀態以各 Release
說明為準。

## [Unreleased]

- 新增 Windows native client roadmap。
- 規劃正式 Developer ID 簽章與 notarization。

## [1.1.0] - 2026-07-30

### Added

- 新增穩定 JSON `doctor`，支援全新 clone/DB、環境、runtime、model cache、
  Token 權限、Loopback port、Ollama、雲端 key presence 與 TCC human gate。
- 新增硬體 auto-tune、真實 MLX benchmark 與 `NOT_RUN` 誠實狀態。
- 新增原子設定套用、冪等性、備份、驗證與失敗回滾。
- 新增根目錄 `AGENTS.md`、`SKILL.md` 與 AI 維運文件。
- 新增 GitHub 內嵌的 21 款 HUD 實際 renderer 截圖。
- 新增 macOS ZIP/DMG、SHA256SUMS 與 GitHub Release workflow。

### Changed

- GitHub README 改為完整產品首頁，明確列出下載、平台、API、隱私、FAQ 與
  Windows 支援邊界。

### Security

- Doctor 只顯示 provider key 是否存在，永不輸出 key/token 值。
- Auto-tune 只允許本地模型欄位，保留所有 cloud/privacy 欄位。

## [1.0.0] - 2026-07-30

- 首次公開 MIT 版本。
- 原生 macOS SwiftUI App、MLX Whisper runtime、Token-authenticated Gateway。
- 21 款 HUD、7 種外框、5 種字幕、3 種 App 主題。

[Unreleased]: ../../compare/v1.1.0...HEAD
[1.1.0]: ../../releases/tag/v1.1.0
[1.0.0]: ../../releases/tag/v1.0.0
