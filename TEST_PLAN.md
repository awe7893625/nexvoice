# TEST_PLAN

## 用途
票 A（VAD pre-gate，branch `feat/vad-pregate`）驗收證據：TTS 語音在低音量不得被前置閘誤擋；非語音必須在付 Whisper 解碼成本前被擋下（幻覺防線）；warmup 不得被自家 gate 打掉。

- task_id: nexvoice 票A VAD closeout
- owner: Orchestrator（Claude Code session）；writer: codex `gpt-5.6-luna`（Atlas lane）；reviewer: codex `gpt-5.6-sol`（獨立，多輪）
- 變更摘要: `2e5a214` numpy 能量＋過零率 VAD 前置閘（只擋或外修、不內剪）；`c8f71fe` RMS cutoff `0.012→0.006` 修 -26dB 英語 false negative；`e208c08` 驗收矩陣＋本計畫；`e798535` warmup bypass VAD（`skip_vad`）；`c9b7b7c` 測試誠實化＋已知限制鎖定
- 受影響模組: `runtime/nexvoice_local_runtime.py`、`runtime/tests/test_vad_pregate.py`、`runtime/test_runtime_contract.py`、`runtime/test_vad.py`（既有 gate 測試，回歸覆蓋）、本檔
- 審查基準: 票 A 範圍 `5c04579..head`。branch 對 local main `1ca6cae` 是乾淨堆疊（祖先）；origin/main `40df132` 與本線**無共同歷史**（發布鏡像），不適合作 diff 基準
- SHA 區分: **code candidate = `c9b7b7c`**（產品碼最後變更）；其後為測試/文件 packet commits（head 見 git log），不改產品碼

## 測試案例
| 類型 | 指令 / 步驟 | 預期結果 | 實際結果 | 狀態 |
|---|---|---|---|---|
| acceptance | `python3 runtime/tests/test_vad_pregate.py`（say TTS 嚴格模式：zero-frame 即 FAIL；`VAD_TEST_ALLOW_SYNTHETIC=1` 僅為 headless portability 模式，不計 TTS 驗收） | 語音全保留且 trim 後 ≥50% 長度；穩態非語音全 gated | **21/21 acceptance pass（+1 KNOWN-LIMITATION reproduced）**，雙 voice `source=say`；逐案例 receipt 見下 | pass |
| unit | `python3 -m pytest runtime/ server/ -q` | 全綠 | `94 passed in 11.93s`，含 warmup contract `skip_vad=True` 斷言（`runtime/test_vad.py` 6 passed 在內） | pass |
| warmup e2e | probe：monkeypatch `_trim_wav_for_vad` 計數後跑 `_warm_final_model()`＋`_warm_partial_model()` | trim 呼叫 0 次、模型實際載入 | `warmup: final model ready in 2.5s`／`warmup: partial model ready in 0.5s`，`trim calls: 0`（修復前 trim 後 0 bytes、模型不載入） | pass |
| build | `cd macos && swift build` | Build complete | `Build complete! (14.79s)`（41 targets） | pass |

### Acceptance 逐案例 receipt（Orchestrator 親跑，fixture 均 `source=say`）
```text
PASS  speech:Meijia@+0dB survives          PASS  speech:Samantha@+0dB survives
PASS  speech:Meijia@+0dB keeps>=50%        PASS  speech:Samantha@+0dB keeps>=50%
PASS  speech:Meijia@-10dB survives         PASS  speech:Samantha@-10dB survives
PASS  speech:Meijia@-10dB keeps>=50%       PASS  speech:Samantha@-10dB keeps>=50%
PASS  speech:Meijia@-20dB survives         PASS  speech:Samantha@-20dB survives
PASS  speech:Meijia@-20dB keeps>=50%       PASS  speech:Samantha@-20dB keeps>=50%
PASS  speech:Meijia@-26dB survives         PASS  speech:Samantha@-26dB survives
PASS  speech:Meijia@-26dB keeps>=50%       PASS  speech:Samantha@-26dB keeps>=50%
PASS  noise@-26dB gated        PASS  noise@-40dB gated       PASS  digital silence gated
PASS  220Hz tone gated         PASS  single click gated
PASS  KNOWN-LIMITATION composite click+sweep kept（鎖定現行行為）
RESULT: 21/21 acceptance pass (+1 KNOWN-LIMITATION reproduced)
```

## 審查紀錄（codex gpt-5.6-sol，獨立）
- 第一輪 **REQUEST_CHANGES**（4 阻擋）：①基準誤用 origin/main（派工方規格錯誤）→ 改 `5c04579..head`，解消；②warmup 被 VAD 短路 → `e798535`，reviewer 判 RESOLVED（負向 probe：預設路徑 trim=1/model=0、skip_vad 路徑 trim=0/model=1）；③retention 斷言恆真 → `c9b7b7c`，判 RESOLVED；④composite click+sweep 穿透 → 處置「如實記載＋characterization test 鎖定＋silero tier follow-up」，reviewer 第二輪**明確接受**（「再收緊同一組 numpy 閾值無證據保證不重新誤擋 −26dB 語音，正解是 learned VAD tier」）。
- 第二輪 **REQUEST_CHANGES（僅證據面，產品碼無阻擋）**：TTS fallback 假綠 → strict 模式修復（見上）；TEST_PLAN 宣稱不精確（candidate/head 未分離、第二輪 verdict 預先自證、receipt 無逐案例、受影響模組漏列）→ 本版修正；sweep 數學經 reviewer 獨立 probe 驗證正確（180Hz→2999.91Hz、click +0.5）。
- 第三輪：reviewer 對證據修正 delta 的最終 ack——pending，見 session 報告。

## 未執行測試
- 項目: mlx_whisper 對 gated/kept clip 的端到端解碼（驗證擋掉後幻覺短語確實消失）
- 原因: 驗收目標是 gate 決策與 warmup 行為；gate 短路在 unit 層已覆蓋；warmup e2e 已證明 bypass 路徑會真載模型
- 風險: 低——模型層幻覺防線另有 hallucination guard tiers（`034ad20`）

## 驗收結論
- 結論: PASS（證據級別：runs＋親驗＋獨立審查多輪）。code candidate `c9b7b7c`。
- follow-up（任務帳 #4）: silero/ONNX tier（收斂 composite 穿透，reviewer 建議 learned VAD tier）；`5c04579` `pinned_model_path()` 暫時性下載失敗靜默永久 cache——補 fallback log；origin/main 與工作線歷史關係文件化。
