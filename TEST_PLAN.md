# TEST_PLAN

## 用途
票 A（VAD pre-gate，branch `feat/vad-pregate`）驗收證據：真人語音在低音量不得被前置閘誤擋；非語音必須在付 Whisper 解碼成本前被擋下（幻覺防線）。

- task_id: nexvoice 票A VAD closeout
- owner: Orchestrator（Claude Code session）；writer: codex `gpt-5.6-luna`（Atlas lane）
- 變更摘要: `2e5a214` 新增 numpy 能量＋過零率 VAD 前置閘（只擋或外修、不內剪）；`c8f71fe` 修 false negative——`_numpy_vad` 固定 RMS cutoff `0.012` → `0.006`
- 受影響模組: `runtime/nexvoice_local_runtime.py`（`_numpy_vad` / `_trim_wav_for_vad` / `transcribe_wav` gate 路徑）

## 測試案例
| 類型 | 指令 / 步驟 | 預期結果 | 實際結果 | 狀態 |
|---|---|---|---|---|
| acceptance | `python3 runtime/tests/test_vad_pregate.py`（say TTS：Meijia zh-TW＋Samantha en-US × 0/−10/−20/−26 dB；靜音、白噪音 −26/−40 dB、220 Hz tone、single click） | 語音全保留且 trim 後 ≥50% 長度；非語音全 gated | **21/21 pass ×3 連跑**（Orchestrator 親跑，非 writer 自報） | pass |
| unit | `python3 -m pytest runtime/ server/ -q` | 全綠 | **94 passed**（8.94s），含既有 `test_vad.py` 6 passed | pass |
| build | `cd macos && swift build` | Build complete | Build complete（14.79s，41 targets，含 `2329af9` Swift 變更） | pass |

## 修復紀錄（第一輪驗收抓到的缺陷）
- 初版矩陣 19/20：`speech:Samantha@-26dB` 被誤擋——先前自報「−26dB 全部通過」經 Orchestrator 複驗**不成立**（原始測試僅涵蓋中文語音）。
- root cause（codex luna 量測）：−26 dB 英語語音 frame RMS 大多低於固定下限 `0.012`，energy_cutoff 全靠它撐 → 語音 frame 全數落選。
- 修法：絕對下限降至 `0.006`；noise-floor 比例（×1.35）、ZCR 視窗（0.01–0.35）、candidate 數下限、envelope 變化檢查**全部保留**，負向案例未弱化（矩陣複跑證實）。

## 未執行測試
- 項目: mlx_whisper 對 gated/kept clip 的端到端解碼（驗證擋掉後幻覺短語確實消失）
- 原因: 驗收目標是 gate 決策本身；gate 短路在 unit 層已覆蓋（`transcribe_wav` 對 gated 輸入回 `""`，不觸模型）
- 風險: 低——模型層幻覺防線另有 hallucination guard tiers（`034ad20`）負責

## 驗收結論
- 結論: PASS（本表證據級別：runs＋親驗）。候選 SHA：`c8f71fe`（fix）＋ `2e5a214`（gate 本體）。獨立審查由 `gpt-5.6-sol` 對 `origin/main..feat/vad-pregate` 全 diff 執行，審查紀錄見 session 報告。
- follow-up: silero/ONNX tier 為刻意未來選項（`_select_vad_tier` 預留）；真麥克風真人語音矩陣可作日常驗收補強。
