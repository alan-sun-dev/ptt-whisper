# 架構：統一後處理管線與 ASR Backend 契約

本文件的目的是把一個決定寫死：**PTT Whisper 只有一條後處理管線。**
任何語音辨識實作都必須以 backend 的身分接進來，不得自建平行路徑。

---

## 管線

```
按住熱鍵
   │
   ├─ ffmpeg 錄音（-af 聲學濾波器鏈）→ ptt_record.wav
   │
   ├─ [ ASR backend ] ──────────────── 唯一可替換的環節
   │      輸入：16kHz 單聲道 wav + (language, prompt, max_context)
   │      輸出：純文字，寫入 ${OUT_PREFIX}.txt
   │
   └─ 統一後處理（transcribe.sh）
          ├─ sample rate 檢查 + 自動 resample
          ├─ 快取查詢／寫入（key 含 audio hash + model + lang + 參數 variant）
          ├─ fallback model 重試
          ├─ clean_whisper_output（移除 whisper 特殊標記）
          ├─ 幻覺過濾（內建 + 自訂，exact → normalized 兩層）
          ├─ 重複標點檢查
          └─ stdout → Lua → 剪貼簿 → 貼上（含 Secure Input 偵測與剪貼簿還原）
```

後處理不知道、也不需要知道是哪個 backend 跑的。

---

## Backend 契約

一個 ASR backend 必須滿足下列全部條件：

1. **只負責推理**。錄音、resample、清理、過濾、快取、貼上都不是它的事。
2. **產出純文字到 `${OUT_PREFIX}.txt`**，交給下游。不得自行輸出到剪貼簿或
   直接貼上。
3. **接受統一的參數**：`language`、`prompt`（initial prompt）、`max_context`。
   不支援的參數可以忽略，但不得因此失敗。
4. **失敗時回傳非零，並且可降級**。上層會依序嘗試其他 backend 與
   fallback model；backend 自己不做「永久切換模式」這種全域決定。
5. **能力自我宣告**。不確定目標 build 是否支援某個旗標時，先偵測
   （見 `transcribe.sh` 的 `detect_whisper_caps`），不要假設。
6. **參數若會改變輸出，必須併入快取 key 的 variant hash**
   （見 `transcribe.sh` 的 `VARIANT_RAW`）。

### 目前的 backend

| Backend | 實作 | 說明 |
|---|---|---|
| CLI | `run_whisper()` | 每次執行 `whisper-cli`，每次重新載入模型 |
| server | `run_whisper_server()` | 常駐 `whisper-server`，HTTP `/inference` |

`run_transcription()` 是 dispatcher：server 優先，任何失敗都退回 CLI。

---

## 為什麼移除舊的 Streaming 模式

v4.0.0 之前的 Streaming 模式（`whisper.cpp --stream`）**違反了上述每一條**：

- 它在 Lua 端自行組裝 whisper 命令，完全不經過 `transcribe.sh`
- 因此 resample、快取、fallback model、幻覺過濾都對它無效——
  幻覺過濾必須在 Lua 端**重複實作一份**，兩份列表還得手動保持同步
- v3.7.0 新增的 `--prompt` 與 `--vad` 對它一樣無效
- 它自行維護 stdout 累積器、ANSI 清理、去重邏輯，以及一套只屬於它的
  「連續失敗 N 次就永久切換模式」降級狀態機

也就是說，每一個加進管線的功能都要在 streaming 那邊再做一次，
而它從頭到尾都掛著「實驗性」。這是典型的第二套管線代價。

同時，**v3.8.0 的常駐 server 已經用更穩定的機制達成了原本的目標**：
streaming 想解決的是「每次錄音都要重新載入模型」的固定成本，
而 server 把模型留在記憶體，直接消除了這個成本，且完整享有統一管線。

### 取回舊實作

```bash
git show streaming-final:ptt_whisper.lua        # 完整檔案
git diff streaming-final HEAD -- ptt_whisper.lua # 移除了什麼
```

---

## 未來若要重做低延遲串流

**必須是一個 backend，不是第二條管線。** 具體要求：

- 分段結果在 backend 內部累積，**只在最終定稿時**輸出一次純文字給下游，
  讓後處理照常運作。不要邊出邊貼。
- 若真的需要「邊講邊上螢幕」的即時預覽，那是 **UI 層的功能**，
  應該讀 backend 的中間狀態來顯示，而不是繞過後處理直接寫入目標 App。
  預覽與最終貼上是兩件事。
- 沿用既有的能力偵測與降級機制，不要新增第二套失敗狀態機。
- 上線前先確認它能通過與 CLI backend 相同的驗證：同一段音訊、同一組參數，
  經過管線後的輸出應與 CLI 一致（幻覺過濾與快取行為相同）。

不滿足這些條件的實作，不應該併入 main。
