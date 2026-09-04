# 架構：統一後處理管線與 ASR Backend 契約

本文件的目的是把一個決定寫死：**PTT Whisper 只有一條後處理管線。**
任何語音辨識實作都必須以 backend 的身分接進來，不得自建平行路徑。

---

## 管線

實際執行順序如下。層與層之間的擁有權（誰負責什麼）是這份文件的重點。

```
Hotkey (Right Option)
  │
  ▼
Audio Capture                        ptt_whisper.lua
  ├ ffmpeg -f avfoundation -af <即時濾波器鏈> -flush_packets 1 → ptt_record.wav
  └ 濾波器鏈只放逐樣本即時的濾波器；需要 lookahead 的一律往後放
  │
  ▼
Input validation                     transcribe.sh
  ├ 檔案存在、大小 ≥ 1000 bytes
  └ 環境變數型別／範圍驗證（逾時、max_context、cache 上限…）
  │
  ▼
Capability & parameter resolution
  ├ 模型解析（候選掃描或明確指定）
  ├ whisper build 能力偵測（--prompt / --vad / -mc / -t），結果快取
  ├ prompt 長度上限 + UTF-8 安全截斷
  └ VAD 決策（auto / true / false × build 支援 × model 是否存在）
  │
  ▼
Cache lookup ①                       key = audio hash + model + lang
  └ 命中 → 直接輸出並結束                    + variant(prompt, VAD, max_context,
                                                      backend, normalize)
  │
  ▼
Pre-processing
  ├ sample-rate 檢查（ffprobe）
  ├ 非 16kHz → 自動 resample
  └ 響度正規化（loudnorm，WHISPER_NORMALIZE=true 時）
     失敗一律降級用原始音訊，不讓整次轉錄失敗
  │
  ▼
ASR Dispatcher                       run_transcription()
  ├ server backend   POST /inference   ← 優先，若 server_usable()
  └ CLI backend      whisper-cli       ← 預設 / 退路
  │
  ▼
Retry & fallback policy
  ├ server 失敗 → Cache lookup ②（改用 CLI 的 identity）→ CLI backend
  ├ VAD 失敗    → 關掉 VAD、同一主模型重試
  └ 仍失敗      → fallback model
  │
  ▼
Final transcript（純文字，${OUT_PREFIX}.txt）
  │
  ▼
Text Pipeline                        統一、與 backend 無關
  ├ cleanup（移除 whisper 特殊標記 [BLANK_AUDIO] 等）
  ├ hallucination guard（exact → normalized 兩層）
  ├ 重複標點檢查
  ├ glossary                         ◇ planned extension point（尚未實作）
  └ OpenCC 簡繁轉換                   ◇ planned extension point（尚未實作）
  │
  ▼
Cache store                          用「實際完成推理的 backend」作 identity
  │
  ▼
Output Adapter                       ptt_whisper.lua
  ├ Secure Input 偵測（密碼框 → 中止）
  ├ clipboard paste + 原剪貼簿還原
  └ Unicode 直接輸入                  ◇ planned extension point（尚未實作）
```

◇ 標記的是**尚未實作**的延伸點，寫在這裡是為了標明它們未來屬於哪一層，
不代表已經存在。

### 幾個容易誤解的點

- **Cache lookup 在 resample 之前。** hash 算的是原始音檔，所以命中時
  連 resample 都可以整個跳過。這是刻意的。
- **音訊前處理分成兩段，分界是「需不需要 lookahead」。** 逐樣本即時的
  （highpass / lowpass）留在錄音端；需要先聽一段才能決定的（loudnorm）
  一律放到 Pre-processing。
  理由不是效能，是**錄音的可存活性**：任何在濾波圖裡囤積音訊的東西，都會
  在 ffmpeg 沒能優雅結束時把那段音訊一起帶走。實測 loudnorm 會壓著約 2.4
  秒——錄 2 秒、硬砍 ffmpeg，磁碟上是 0 bytes。
  同理，錄音端的 `-flush_packets 1` 不是調校參數而是正確性要求：少了它，
  整段音訊會囤在輸出緩衝區，錄音期間磁碟上全程 0 bytes。
- **Fallback 屬於 inference orchestration，不是後處理。** 它決定「由誰產生
  文字」，發生在文字產生之前。
- **Cache identity 描述「實際完成推理的 backend」，不是「偏好」。**
  preference 是 server 但實際降級到 CLI 時，結果寫進 CLI 的 namespace。
- **Text Pipeline 之後的所有步驟都與 backend 無關。** 這是整個架構的重點：
  換 backend 不該影響文字處理，新增文字處理不該要求每個 backend 各做一次。

## Backend 契約

一個 ASR backend 必須滿足下列全部條件：

1. **只負責推理**。錄音、resample、正規化、清理、過濾、快取、貼上都不是
   它的事。
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

---

## 已知架構債

這些是明確記錄下來、但**刻意不在 v4.0.x 處理**的問題。

### 1. 模型候選清單存在兩份

`DEFAULT_MODEL_CANDIDATES` 在 `ptt_whisper.lua` 與 `transcribe.sh` 各有一份，
註解要求「兩端保持一致」——需要靠註解維持的一致性就是漂移訊號。

**方向**（尚未實作）：讓正常 Hammerspoon 路徑的模型選擇擁有者只有 Lua，
由 Lua 解析出絕對路徑後傳給 `transcribe.sh`；`transcribe.sh` 保留自己的
fallback 解析，但那條路徑只服務「在終端機直接執行」的場景。

不在 v4.0.x 動的理由：現在改會同時影響兩個 entry point 的模型解析，
風險大於收益，而目前兩份清單的內容有測試覆蓋（`tests/cases/10-*`）。

### 2. 幻覺列表的 single source of truth 尚未完成

目前有三份：repo 的 `hallucinations_builtin.txt`、Lua 的硬編碼 fallback、
Bash 的硬編碼 fallback。後兩者是完整的 43 條複本。

**方向**：解析順序改為
runtime copy → repo copy → **最小**緊急 fallback（只留最常見的幾條），
兩端都不再維護完整複本。

### 3. `max_context` 的抗幻覺效果尚未驗證

`max_context: 0` 曾是預設值，理由是「關掉跨段上下文可減少重複與拖尾幻覺」。
真機 A/B 已證實它會讓 `initial_prompt` 完全失效，因此預設已改為 `-1`
（不帶 `-mc`）。

但**「關掉 context 能減少重複／拖尾幻覺」這個原始假設本身仍未被驗證**——
只證明了它的副作用不可接受。若日後要重新評估，需要涵蓋不同長度與語言的
語料做 A/B，並同時觀察術語命中率的損失。見 `REAL_MAC_VALIDATION.md`。
