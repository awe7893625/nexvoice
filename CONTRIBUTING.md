# Contributing

1. 建立獨立分支，先執行 `cd macos && swift test`。
2. 不提交 API key、模型權重、`dist/`、`.build/`、個人路徑或簽章憑證。
3. 涉及錄音、Accessibility、全域快捷鍵、雲端路由、安裝器或更新流程的修改，必須補測試與安全性說明。
4. 變更完成後執行 `git diff --check`，並在 pull request 說明本機/雲端行為與回滾方式。
5. 未經維護者確認，不要發布公開 release、notarization 證書或模型檔案。
