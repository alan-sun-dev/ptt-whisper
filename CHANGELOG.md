# Changelog

本專案的所有重要變更都記錄於此。格式參考 [Keep a Changelog](https://keepachangelog.com/zh-TW/1.1.0/)，
版本號為 `ptt_whisper.lua` / `transcribe.sh` 兩者的對應版本。

---

## [4.0.2] / transcribe.sh 2.10.1 — 嚴格 /health 分類

### Fixed

- **`classifyHealthResponse` 改用 JSON 解析，不再做 substring 推斷。**

  原本 HTTP 200 的判定是「body 小寫後同時含 `status` 與 `ok`」。
  這會把下列全部誤判成 ready：

  ```
  {"status_message":"ok"}      ← status 與 ok 都在，但不是 whisper 的契約
  {"status":"not ok"}          ← 明確表示不 ok
  status check ok              ← 根本不是 JSON
  ```

  改為對照 whisper.cpp server 的正式契約：

  | 回應 | 分類 |
  |---|---|
  | 連線失敗 | `unavailable` |
  | `200` + 合法 JSON object + `status == "ok"` | `ready` |
  | `503` + 合法 JSON object + `status == "loading model"` | `loading` |
  | 其他一切（200 非 JSON、200 無關 JSON、503 無關 JSON、404、500…） | `foreign` |

  實作細節：`hs.json.decode` 遇到非法 JSON 會 **raise error 而非回傳 nil**，
  因此包在 `pcall` 裡；JSON 陣列在 Lua 裡也是 table，所以除了「是 table」
  還要求 `status` 必須是**字串**。

- **`probeEndpointOccupancy()` 不再重用 `classifyHealthResponse`。**
  readiness 收緊成「必須符合 whisper 的 JSON 契約」之後，若 occupancy 跟著
  收緊，回 404 的其他 HTTP 服務會被誤判成「port 是空的」，接著 bind 失敗。
  占用偵測維持「任何 HTTP 回應都算被占用」。

- **測試抽取 pattern 的 bug。** `[TESTABLE:...]` 的擷取從 `]` 之後開始，
  把 marker 行尾那段沒有 `--` 前綴的中文說明也當成程式碼。
  這個 bug 一直存在，但因為本機沒有 lua 直譯器、測試從未真正執行過，
  所以從未暴露。改為從 marker 行的**換行之後**開始擷取。

### Testing

`./tests/run.sh` → **180 passed, 0 failed, 0 skipped**（前一版是 128 + 1 skipped）。

`classifyHealthResponse` 現在由 lua 直譯器**實際執行** 43 條斷言：
27 條決策表 + 16 條「拿 fake server 真實回應餵進去」的情境，涵蓋
`{"status_message":"ok"}`、`{"status":"not ok"}`、`status check ok`、
`{"status":true}`、JSON 陣列、空 body、malformed JSON、503 非 loading 等
全部誤判向量。

被測的是從 `ptt_whisper.lua` 抽出的同一份程式碼，不是複製的實作。
測試注入嚴格 JSON decoder test double，因為 `hs.json.decode` 只存在於
Hammerspoon runtime——**這個替換本身沒有自動化覆蓋**，已列入真機驗證。

### Docs

- `REAL_MAC_VALIDATION.md` 措辭修正：第 22/23 項的目的不是再證明 upstream
  支不支援（原始碼已確認支援），而是確認**這台實際編譯出來的 build**
  與 contract 是否一致。

---

## [4.0.1] / transcribe.sh 2.10.1 — Hardening

沒有新功能。這一版把 v3.8.0 引進的 server 路徑修到可以信任的程度，
並把測試從「一次性 session 驗證」變成 repo 裡可重複執行的東西。

### Fixed — Server readiness

- **`GET /` + 「任何 HTTP 回應就算 ready」改為 `GET /health`。**
  whisper-server 在模型載入完成前就會接受連線，原本的判定等於
  「行程活著」，不等於「模型可用」——第一次錄音會打到還沒就緒的 server。
  現在分成四類：`ready` / `loading`(503) / `foreign` / `unavailable`。

- **占用偵測與就緒偵測拆成兩個函式。** 原本同一個布林值同時回答
  「port 有沒有人在聽」與「模型能不能用」。占用偵測刻意把 404 之類的
  回應也算成「被占用」——若改成「只有 200 才算」，回 404 的其他 HTTP
  服務會被誤判成「port 是空的」，接著 bind 失敗。

### Fixed — Stale callback race

- **新增 `serverGeneration`。** start / stop / 非預期結束都會 +1，
  所有非同步 callback 在排程時 capture 當下的 generation，不符就 return。

  修掉的具體漏洞：舊 server 的 exit callback 會把新 server 的 `serverTask`
  設成 nil（原本只檢查 `if serverTask then`）；`stopServer()` 之後在途的
  readiness callback 仍會把 `serverReady` 設回 true；重複 restart 會累積
  多個 poll loop。

- `stopServer()` 先 bump generation 再 terminate，順序不能顛倒。

### Fixed — Shutdown

- 重啟由 `doAfter(0.5, startServer)`（睡半秒然後祈禱）改為
  `waitForTaskExit()` 輪詢到行程真正結束，上限 5 秒，逾時記錄並照常啟動。
  不做無條件強制 kill。

### Fixed — Cache identity

- **改以「實際完成推理的 backend」為準。** 原本用 `SERVER_MODE`，
  那只是「希望用 server」；server 失敗退回 CLI 時，CLI 產生的結果仍被
  寫進 server 的 namespace，下次 server 正常時就會拿到一份其實由 CLI
  產生的結果。現在查詢用「預計的 backend」，真的降級時再用 CLI 的
  identity 查第二次，寫入一律用實際的 backend。

- 快取命中會把 `last_backend.txt` 寫成 `cache:server` / `cache:cli`，
  Menubar 顯示「📦 快取（server 產生）」。

### Fixed — 其他

- **curl multipart 除音訊檔外一律 `--form-string`。** `-F` 會把值裡的
  `@` 解讀成「上傳這個本機檔案」、`<` 解讀成「從檔案讀入內容」，
  而 prompt 完全可能合法地以 `@` 或 `<` 開頭（`@channel`、`<tag>`）。
  實測 `-F "prompt=@/tmp/x"` 會把 `/tmp/x` 的內容當欄位值送出去。

- `WHISPER_TIMEOUT` 非數字時，`(( TIMEOUT_SEC > 0 ))` 會在 `set -u` 下
  把它當變數名解析，直接 `unbound variable` 中止整個腳本。

- `md5` / `md5sum` 都找不到時明確記錄「快取本次停用」，不再靜默跳過。

### Added — 測試

`./tests/run.sh`，**128 passed / 1 skipped**，不需要真的 whisper.cpp、
模型或 Hammerspoon。涵蓋模型解析、推理參數、UTF-8 截斷、VAD 降級鏈、
快取語意（含 backend identity 迴歸）、server 的六種失敗路徑、
multipart 字面值安全、幻覺過濾、異常輸入、`/health` 六種情境。

另跑靜態檢查：`bash -n`、JSON 合法性、Lua 區塊平衡，以及設定欄位在
Lua 白名單 / README / `config_example.json` 三方的一致性。

`tests/test-lua-units.lua` 從 `ptt_whisper.lua` 抽出
`[TESTABLE:classifyHealthResponse]` 區塊直接執行——驗證的是實際出貨的
程式碼。本機沒有 lua 直譯器時明確標示 skipped，不會假裝跑過。

### Docs

- `docs/ARCHITECTURE.md` 的管線圖修正順序：resample 在推理**前**、
  cache lookup 也在推理前、fallback 屬於 inference orchestration 而非
  後處理。未實作的 glossary / OpenCC / Unicode typing 標記為
  ◇ planned extension point，不寫成已實作。新增「已知架構債」章節。
- 新增 `REAL_MAC_VALIDATION.md`：30 項真機驗證清單。
- README 明確標註 `max_context: 0` 是理論推導、**尚未經真實語料 A/B 驗證**。

---

## [4.0.0] / transcribe.sh 2.10.0 — 移除 Streaming 模式

**Breaking change。** Streaming 模式整套移除。

### Removed

- `streaming_mode` / `streaming_step_ms` / `streaming_length_ms` 三個設定欄位
- `startStreaming()` / `stopStreaming()` / `handleStreamingFailure()`、
  stdout 累積器、`cleanStreamOutput()`、`STATE.STREAMING`、
  以及只服務 streaming 的降級狀態機（`streamingFailCount`）
- Diagnostics 的「`--stream` 支援」檢查
- README 中的 SDL2 建置說明與 Streaming 章節

共移除 271 行 Lua。`transcribe.sh` 不受影響（streaming 原本就完全繞過它），
版本維持 2.10.0。

### 為什麼

Streaming 是一條**繞過統一後處理管線的平行實作**。它在 Lua 端自行組裝
whisper 命令，不經過 `transcribe.sh`，因此：

- resample、快取、fallback model 對它無效
- 幻覺過濾必須在 Lua 端重複實作一份，兩份列表還得手動保持同步
- v3.7.0 加的 `--prompt` 與 `--vad` 對它一樣無效
- 它自帶一套只屬於自己的「連續失敗 N 次永久切換模式」狀態機

每個加進管線的功能都得在 streaming 那邊再做一次，而它始終掛著「實驗性」。

而 **v3.8.0 的常駐 server 已經用更穩定的機制達成了原本的目標**：
streaming 想解決的是「每次錄音重新載入模型」的固定成本，server 把模型
留在記憶體直接消除了它，且完整享有統一管線。

### 保存

最後一版實作保存於 git tag **`streaming-final`**：

```bash
git show streaming-final:ptt_whisper.lua
git diff streaming-final HEAD -- ptt_whisper.lua
```

### 未來的串流必須是 ASR backend

新增 [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)，明訂管線與 backend 契約：
任何語音辨識實作都必須以 backend 身分接進統一管線（只負責推理、產出純文字
交給下游、失敗可降級、參數變動併入快取 key），**不得自建平行路徑**。

若日後要重做低延遲串流：分段結果在 backend 內部累積，只在定稿時輸出一次；
「邊講邊上螢幕」的即時預覽屬於 UI 層，讀 backend 的中間狀態來顯示，
而不是繞過後處理直接寫入目標 App。

### 升級須知

舊的 `config.json` 留著 streaming 欄位不會壞。載入時會明確警告該欄位
**已移除且不再有作用**（而非籠統的 "unknown config key"），
Run Diagnostics 的「Config 驗證」項也看得到。可以安心刪掉那三行。

### Changed

- Diagnostics 標頭由 `Mode: Streaming/Traditional` 改為
  `Backend: server/CLI`；Menubar 移除「模式」列（Server 與上次後端已涵蓋）
- 啟動提示改顯示 backend 而非 mode

---

## [3.8.0] / transcribe.sh 2.10.0 — 常駐 Server

CLI 模式每次錄音都要重新載入模型（small 量化版約 0.3~0.5 秒）。這是與講話
長度無關的固定成本，對 2~15 秒的 PTT 錄音佔比很高。這版把 whisper-server
接進來，模型常駐記憶體。

### Added

- **`server_mode`（預設 `false`）**。啟用後由 `ptt_whisper.lua` 管理
  whisper-server 的生命週期：Hammerspoon 載入時非同步啟動（模型載入期間
  不阻塞，此時的錄音走 CLI），reload 時 `cleanup()` 收掉。
  Menubar 新增「重啟 whisper-server」，Console API 新增
  `PTTWhisper.restartServer()` / `stopServer()`。

  預設關閉是刻意的：這會多一個長駐行程、常駐佔用約一份模型大小的 RAM。
  這個交換該由使用者決定，不該在升級後自動出現。

- **`server_port`（預設 `8178`）**。

- **後端可見性**。`transcribe.sh` 每次會把實際用到的後端寫進
  `~/.ptt-whisper/last_backend.txt`，Menubar 顯示「上次後端：⚡ server / 📼 CLI」，
  Diagnostics 也有對應項目。**server 模式開著卻一直走 CLI 會被標成警告**——
  這條路徑設計上會靜默降級，沒有這個顯示使用者不會發現它其實沒生效。

### 降級策略

server 只取代「跑推理」這一步；resample、幻覺過濾、快取、fallback model
等管線完全不變，兩條路徑產出同一份 `${OUT_PREFIX}.txt`，下游不需要區分。

任何一項不成立就退回 CLI：

| 情況 | 行為 |
|------|------|
| server 未就緒 / 已掛掉（curl exit 7） | 該次走 CLI |
| HTTP 非 200、回應為空 | 退回 CLI |
| 回應是 JSON（舊版不支援 `response_format=text`） | 退回 CLI，不把 JSON 當結果 |
| 本次模型 ≠ server 載入的模型 | 直接走 CLI，不發請求 |
| 埠已被占用 | 不啟動 server，整個 session 走 CLI 並提示 |

最後兩項的理由相同：為單次請求叫 server 換模型，會把「省下載入時間」的
好處整個賠掉；而占用該埠的行程載入的是哪個模型無從得知，沿用可能拿到錯的
轉錄結果。兩種情況都寧可退回 CLI。

VAD 重試與 fallback model 一律留在 CLI 路徑上——那是已知穩定的路徑。

### Fixed

- 快取 key 納入 backend。server 與 CLI 對同一組參數理論上輸出相同，但
  server 是否真的吃下 `prompt` / `max_context` 取決於它的版本，因此不假設
  兩者等價，各自持有快取。

---

## [3.7.0] / transcribe.sh 2.9.0 — 推理參數

whisper.cpp 的呼叫原本只帶了 `-m -f -otxt -of -nt`，把準確度與速度的旋鈕
全留在桌上。這版把四個旗標接起來。

### Added

- **`--prompt`（術語注入）**。準確度收益最大的一項：把專有名詞、人名、
  中英混用詞先餵給解碼器當上下文。兩層設定會**串接**：全域 `initial_prompt`
  是通用術語表，`lang_models[bid].prompt` 是該 App 的領域術語，
  這樣全域術語表在每個 App 都有效，不必逐個 App 重複貼一遍。
  長度上限 800 bytes（≈266 中文字），超過從尾端截斷並記 WARNING。

- **`--vad`（靜音偵測）**。砍掉靜音段：短錄音推理更快，且能**從源頭**減少
  靜音幻覺——內建的幻覺黑名單是事後補救，VAD 是治本。
  VAD model 以 glob 掃描 `models/ggml-silero*.bin`，不寫死版本號。
  `vad_enabled` 預設 `"auto"`：whisper.cpp 支援且找得到 model 才啟用。

- **`-t`（執行緒數）**。whisper.cpp 預設 `min(4, hardware_concurrency)`，
  在 Apple Silicon 上偏保守。改為自動偵測**效能核心**數
  （`hw.perflevel0.physicalcpu`）——把效率核心也算進來反而會拖慢推理。

- **`-mc 0`（max-context）**。PTT 錄的是獨立短句，不需要跨段上下文；
  關掉可明顯減少 whisper 的重複與拖尾幻覺。

**能力偵測**：每個旗標都先確認這個 build 支援才帶上，舊版 whisper.cpp
不會因為多了不認得的旗標而失敗。偵測結果快取在
`~/.ptt-whisper/whisper_caps.txt`，以 binary 路徑 + mtime + size 為 key，
重新編譯 whisper.cpp 會自動失效，不必每次錄音都跑一次 `--help`。

**VAD 失敗的降級順序**：VAD 是最可能與環境衝突的一項（build 支援但 model
檔損壞）。失敗時先**關掉 VAD 用同一個主模型重試**，再考慮換 fallback model
——保住轉錄品質優先於保住流程。

- Diagnostics 新增三項：whisper.cpp 旗標支援度、VAD 狀態、目前生效的
  initial prompt（含前景 App）。

### Fixed

- **快取 key 納入 prompt / VAD / max-context**。這三者都會改變轉錄輸出，
  不進 key 的話改了 prompt 會拿到舊 prompt 產生的快取結果。

- **P3-1 — PATH 補上 `/sbin`，`cache_enabled` 才真的能運作**。
  macOS 的 `md5` 位在 `/sbin/md5`，而 Lua 傳給 transcribe.sh 的 PATH 是
  `/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin` — 找不到 `md5` 也找不到
  `md5sum`，`AUDIO_HASH` 因此永遠是空字串，快取被靜默停用。也就是說
  **F4 快取功能自 v3.5.0 引入以來，從 Hammerspoon 走的路徑上從未生效過**
  （包括後續 R1、CR9、CR12 針對 LRU 清理做的所有修正）。
  只有在終端機直接執行 `transcribe.sh` 時才會運作，因為互動式 shell
  的 PATH 通常含 `/sbin`。

### 設定

```json
{
  "initial_prompt": "Kubernetes, Terraform, gRPC, PostgreSQL",
  "vad_enabled": "auto",
  "max_context": 0,
  "whisper_threads": 0,
  "lang_models": {
    "com.tinyspeck.slackmacgap": { "lang": "en", "prompt": "standup, sprint, PR" }
  }
}
```

---

## [3.6.5] / transcribe.sh 2.8.5

### Fixed

- **MC1 — 預設模型改為候選清單掃描**。舊版兩端都硬寫 `ggml-small-q5_0.bin`，
  但 whisper.cpp 的 `download-ggml-model.sh` 對 small 只提供 **q5_1**
  （q5_0 僅 medium / large 有），使用者照官方指令下載後反而吃不到量化版、
  靜默退回 FP16。現在依偏好順序掃描：

  ```
  WHISPER_MODEL 環境變數（最高優先）
    → ggml-small-q5_1.bin
    → ggml-small-q5_0.bin
    → ggml-small-q8_0.bin
    → ggml-small.bin（FP16）
  ```

  清單在 `ptt_whisper.lua` 的 `DEFAULT_MODEL_CANDIDATES` 與 `transcribe.sh`
  的 `DEFAULT_MODEL_CANDIDATES` 兩處，需保持一致。

- Diagnostics 的模型類型標籤改為通用比對檔名量化後綴，
  現在 `q4_k_m` 等格式也能正確標示（原本只認 q5_0 / q5_1 / q8_0）。

- **MC2 — 轉發 `WHISPER_CACHE_MAX`**。Lua 端組裝 transcribe.sh 的環境變數時
  漏了這一項，導致從 Hammerspoon 走的正常路徑永遠吃預設值 50，
  只有直接在終端機執行 `transcribe.sh` 時才有效。

### Added

- 新增 `hallucinations_builtin.txt` 到 repo。此檔案自 v3.6.0（P1）起就是
  兩端共用的幻覺列表來源，但從未隨 repo 提供，也沒有任何安裝步驟建立它，
  因此實際上**兩端一直都在走硬編碼的 fallback 列表並記錄 WARNING**。
  現在檔案隨 repo 提供，安裝步驟也加上部署指令。內容與兩端的硬編碼
  fallback 完全一致（43 條）。

### Docs

- README 移除誤貼入的未整理草稿段落，重寫模型下載說明。
- 四份分散的 changelog（`CHANGELOG.md`、`CHANGELOG_v3.6.2.md`、
  `CHANGELOG_v3_6_3.md`、`CHANGELOG_v3_6_4.md`）合併為本檔案。
- README 補上未被文件化的 `audio_filter_chain` 設定欄位。

---

## [3.6.4] / transcribe.sh 2.8.4 — 第四輪 Code Review

### Fixed

- **CR12** `loadExternalConfig()` 改為結構化回傳，Diagnostics 能區分
  「無設定檔」/「空檔」/「JSON 解析失敗」三種情況。
- **CR13** `streamingFailCount` 改為漸進式衰減（成功 -1，而非歸零）。
  v3.6.2 的歸零讓降級保護被單次成功繞過，v3.6.3 的完全不衰減又會讓
  跨越數小時的偶發失敗永久累積；遞減 1 在兩者間取得平衡。
- **CR12-bash** LRU 快取清理的 `stat` 加入 Linux fallback
  （`stat -f '%m %N'` 是 BSD 語法，Linux 上靜默失敗會導致快取無限增長）。

### Added

- **CR14** Diagnostics 的 Model 檢查加上量化版本標籤 `[Q5_0]` / `[FP16]`。
- **CR15** Diagnostics 新增濾波器鏈 dry-run 驗證，用 `lavfi` 虛擬音源
  在診斷時就抓出 `-af` 語法錯誤，不必等到實際錄音才發現。

### Performance

- **CR13-bash** 幻覺比對改為批次 normalize，fork 次數從 O(N) 降為 O(1)
  （50 行列表：102 → 7 forks）。

---

## [3.6.3] / transcribe.sh 2.8.3 — 第三輪 Code Review

### Fixed

- **CR7** 修正工作目錄初始化順序：`loadExternalConfig()` 原本在
  `mkdir(PTT_DIR)` 之前呼叫，導致首次啟動讀不到 config.json。
- **CR8** 錄音濾波器 lowpass 從 3kHz 放寬到 **5kHz**。3kHz 切掉了齒擦音
  頻帶（/s/、/ʃ/、/f/ 約 4–8kHz），對英文辨識有負面影響。
- **CR9** `streamingFailCount` 不再於每次成功啟動時歸零
  （後於 v3.6.4 再調整為漸進式衰減）。
- **CR9-bash** LRU 快取清理從 `ls -1t` 改用 `find`，消除空目錄時
  glob 不展開的邊界問題。

### Added

- **CR10** Diagnostics 納入 config 驗證警告，設定錯誤一次可見。

### Performance

- **CR7-bash** `normalize_text()` 合併 sed pipeline，單次呼叫 fork 7 → 2。

### Docs

- **CR11** FFmpeg 收到 SIGINT 在 macOS 回傳 255 屬正常終止，加註解說明。
- **CR10-bash** 文件化 `LC_ALL=C` 的 trade-off：字元類只匹配 ASCII，
  全形空白 U+3000 需在 `normalize_text()` 中顯式處理。

---

## [3.6.2] / transcribe.sh 2.8.2 — 錄音品質 + 推理效能

### Added

- **OPT1 — 聲學濾波器鏈**。錄音的 ffmpeg 呼叫加入 `-af`：

  | 濾波器 | 作用 |
  |--------|------|
  | `highpass=f=200` | 切除冷氣、馬路隆隆聲等低頻環境噪音 |
  | `lowpass=f=5000` | 切除電路嘶聲、風扇雜音（v3.6.3 由 3000 放寬） |
  | `loudnorm=I=-16:TP=-1.5` | EBU R128 感知響度正規化，防止忽大忽小 |

  可透過 config.json 的 `audio_filter_chain` 覆寫，設為 `""` 停用。
  Streaming 模式由 whisper.cpp 自行擷取麥克風，不經過 ffmpeg，故不受影響。

- **OPT2 — 預設改用量化模型**。

  | 指標 | FP16 | Q5 量化版 |
  |------|------|-----------|
  | 檔案大小 | ~466 MB | ~181 MB (-61%) |
  | 記憶體佔用 | ~500 MB | ~200 MB (-60%) |
  | 推理速度 | 1x | 2~3x |
  | 準確率 | 基準 | 幾乎無損（<0.5% WER 差異） |

  量化將關鍵張量壓縮進 L3 cache，把 memory-bound 運算轉為 compute-bound。
  （此版寫死 q5_0，於 v3.6.5 修正為候選清單掃描。）

---

## 更早的版本

- **3.6.1** / 2.8.1 — CR1~CR6（第二輪 Code Review）
- **3.6.0** / 2.8.0 — P1~P6：共用幻覺列表檔、Streaming 累積上限
- **3.5.1** / 2.7.1 — R1~R10：Streaming 漸進式降級、快取 LRU 修正、
  config 範圍驗證、log rotation regex 精確化
- **3.5.0** / 2.7 — F4~F7：轉錄快取、Streaming 模式、Fallback Model、健康檢查
- **3.4.x** / 2.6.x — F1~F3：多語言 / 多 App 切換
- **3.3.x** ~ **2.1** — 早期迭代（詳見 git history）

---

## Known Issues

### whisper.cpp `-nt`（no timestamps）可能丟字

**狀態**：已知，暫不修正。

whisper.cpp issue [#2186](https://github.com/ggerganov/whisper.cpp/issues/2186)
報告 `-nt` 在長音訊（>30s）上可能導致部分語句被丟棄。PTT Whisper 的典型
錄音時長為 2~15 秒，觸發機率極低，目前保留 `-nt` 以維持輸出簡潔。

**未來方案**：若出現丟字回報，改用帶 timestamp 的輸出 + sed strip。

---

## Roadmap

### FFmpeg 8.0 `af_whisper` 原生整合

**狀態**：追蹤中，暫不採用。

FFmpeg 8.0「Huffman」(2025-08-22) 新增 `af_whisper` 濾鏡，理論上可用單一
命令完成錄音 → 濾波 → 推理，砍掉整個 `transcribe.sh`。暫不採用的原因：

1. Homebrew FFmpeg formula 尚未包含 `--enable-whisper` build option
2. `af_whisper` 不支援 streaming mode
3. 穩定性未經社群充分驗證

**評估時機**：Homebrew formula 支援，或 FFmpeg 8.1 發佈時。
