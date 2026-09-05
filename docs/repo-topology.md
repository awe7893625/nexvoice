# Repo topology：兩條無關的 git 歷史（2026-08-29 查證）

NexVoice 的 git 倉庫有**兩條沒有共同祖先的歷史**。用錯基準會把整條工作線
看成大規模刪除、誤擋審查與合併（本專案曾因此誤判一次，2026-08-29）。

```
local main (1ca6cae 起)          ← 工作線的乾淨祖先
   └── feat/vad-pregate          ← 整合線（所有票合入這裡、push origin）
         ├── 票A VAD pre-gate
         ├── 票B/B2 翻譯層
         ├── 票C SRT 匯出
         ├── 票D 熱鍵左右鍵
         ├── 票E 熱鍵 SSOT
         └── 票F install 重啟 gateway

origin/main (40df132)            ← 改寫過的公開發布鏡像（open-source publish）
   與工作線「無 merge-base」——PR #1-#4 對應本地同名 commit，但是 rewrite 過的歷史
```

## 規則

1. **審查/diff/合併基準一律用工作線**：`5c04579..<候選>` 或
   `local main...branch`；**絕不用 origin/main 當 diff 基準**。
2. 票做完 → 合入 `feat/vad-pregate`（`merge(--no-ff)`，merge commit 計入出貨
   計數）→ push 該 branch；local `main` 只 ff 當快照、不 push。
3. `origin/main` 的發布走獨立流程（改寫鏡像），與整合線的 push 是兩回事。
4. home-root git（/Users/ray 下的 repo）不是 rollback unit，不做為本專案的
   回滾依據。

## 歷史沿革

- 2026-08-29：誤用 origin/main 當審查基準，誤判「無共同歷史」為 blocker；
  查證後確立本文件規則，並寫入 auto-memory（nexvoice-repo-topology）。
