# TEST_PLAN

## 用途
票 A（VAD pre-gate，branch `feat/vad-pregate`）驗收證據：TTS 語音在低音量不得被前置閘誤擋；非語音必須在付 Whisper 解碼成本前被擋下（幻覺防線）；warmup 不得被自家 gate 打掉。

- task_id: nexvoice 票A VAD closeout
- owner: Orchestrator（Claude Code session）；writer: codex `gpt-5.6-luna`（Atlas lane）；reviewer: codex `gpt-5.6-sol`（獨立，兩輪）
- 變更摘要: `2e5a214` numpy 能量＋過零率 VAD 前置閘（只擋或外修、不內剪）；`c8f71fe` RMS cutoff `0.012→0.006` 修 -26dB 英語 false negative；`e208c08` 驗收矩陣＋本計畫；`e798535` warmup bypass VAD（`skip_vad`）；`c9b7b7c` 測試誠實化＋已知限制鎖定
- 受影響模組: `runtime/nexvoice_local_runtime.py`、`runtime/tests/test_vad_pregate.py`、`runtime/test_runtime_contract.py`
- 審查基準: 票 A 範圍 `5c04579..c9b7b7c`（branch 對 local main `1ca6cae` 是乾淨堆疊；origin/main 為無共同歷史的發布鏡像，不適合作 diff 基準）

## 測試案例
| 類型 | 指令 / 步驟 | 預期結果 | 實際結果（raw receipt） | 狀態 |
|---|---|---|---|---|
| acceptance | `python3 runtime/tests/test_vad_pregate.py`（say TTS：Meijia zh-TW＋Samantha en-US × 0/−10/−20/−26 dB；靜音、白噪音 −26/−40 dB、220 Hz tone、single click；composite click+sweep 為 KNOWN-LIMITATION 鎖定現行行為） | 語音全保留且 trim 後 ≥50% 長度（期望值固定、actual 獨立計算）；穩態非語音全 gated | `RESULT: 22/22 pass` ×3 連跑（Orchestrator 親跑） | pass |
| unit | `python3 -m pytest runtime/ server/ -q` | 全綠 | `94 passed in 11.93s`，含 warmup contract 新增 `skip_vad=True` 斷言 | pass |
| warmup e2e | probe：monkeypatch `_trim_wav_for_vad` 計數後跑 `_warm_final_model()`＋`_warm_partial_model()` | trim 呼叫 0 次、模型實際載入 | `warmup: final model ready in 2.5s`／`warmup: partial model ready in 0.5s`，`trim calls: 0`（修復前 trim 後 0 bytes、模型不載入） | pass |
| build | `cd macos && swift build` | Build complete | `Build complete! (14.79s)`（41 targets） | pass |

## 審查紀錄（codex gpt-5.6-sol，兩輪）
第一輪 **REQUEST_CHANGES**，四項阻擋：
1. 審查基準誤用 origin/main（派工方規格錯誤；正確基準=local main 堆疊，見上）→ 解消。
2. warmup 被 VAD 短路（final＋partial）→ `e798535` 修復，receipt 見上。
3. ≥50% retention 斷言恆真 → `c9b7b7c` 修復（expect 固定、got 獨立計算）。
4. composite click(0.5 peak)+sweep(−26dB) 可穿透新 cutoff → 處置：**已知限制如實記載**（矩陣 KNOWN-LIMITATION 案例鎖定行為防漂移；numpy gate 追殺此案例會重新犧牲 −26dB 真語音），silero/ONNX tier 列 follow-up（任務帳 #4）。

第二輪：對 `e798535`＋`c9b7b7c` delta 重審（見 session 報告）。

## 未執行測試
- 項目: mlx_whisper 對 gated/kept clip 的端到端解碼（驗證擋掉後幻覺短語確實消失）
- 原因: 驗收目標是 gate 決策與 warmup 行為；gate 短路在 unit 層已覆蓋（`transcribe_wav` 對 gated 輸入回 `""`，不觸模型——本表的 warmup e2e 已證明 bypass 路徑會真載模型）
- 風險: 低——模型層幻覺防線另有 hallucination guard tiers（`034ad20`）

## 驗收結論
- 結論: PASS（證據級別：runs＋親驗＋獨立審查）。候選 SHA：`c9b7b7c`（head）；票 A 範圍 `5c04579..c9b7b7c`。
- follow-up（任務帳 #4）: silero/ONNX tier（收斂 composite 穿透）；`5c04579` `pinned_model_path()` 暫時性下載失敗會靜默永久 cache——補 fallback log；origin/main 與工作線歷史關係文件化。
