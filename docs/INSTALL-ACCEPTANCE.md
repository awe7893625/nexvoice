# 安裝驗收操作

正式安裝前先執行 dry-run：

```sh
cd macos
NEXVOICE_INSTALL_BUILD_KIND=acceptance NEXVOICE_INSTALL_DRY_RUN=1 zsh scripts/install-app.sh
```

Dry-run 只會重新建置、簽章與驗證候選 App，不會關閉現有 NexVoice，也不會替換 `~/Applications/NexVoice.app`。

取得使用者明確同意後，才執行：

```sh
NEXVOICE_INSTALL_BUILD_KIND=acceptance zsh scripts/install-app.sh
```

安裝器會先要求現有 App graceful handback，確認 hotkey owner 已回到 legacy，將舊版移至 timestamped backup，再以 atomic move 安裝 candidate。若 owner handback 失敗，安裝會停止，不會覆蓋舊版。
