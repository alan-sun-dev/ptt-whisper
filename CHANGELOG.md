# Changelog

本專案的所有重要變更都記錄於此。格式參考 [Keep a Changelog](https://keepachangelog.com/zh-TW/1.1.0/)，
版本號為 `ptt_whisper.lua` / `transcribe.sh` 兩者的對應版本。

---

## [4.1.2] — 第三方 code review 抓到的問題

`transcribe.sh` 2.11.0 → **2.12.0**。

這一版全部來自把 v4.1.0/v4.1.1 送給不同家族的模型（Codex）做對抗式 review。
作者原本明確聲稱「構造不出可達路徑」的那一項，被具體序列推翻了。

### Fixed — N4：升級 timer 會被別次錄音取消

`killFallbackTimer` / `killHardTimer` 原本是兩個模組級變數。作者的推理是
「升級鏈 2.8 秒內跑完，期間 `currentState` 是 `TRANSCRIBING`，新錄音進不來」。

**漏了誤觸路徑。** `stopRecordingAndTranscribe` 的順序是：

```lua
killTask(finishedRecordTask)          -- 先排好 2.0s / 2.8s 的升級鏈
...
if duration < MIN_RECORD_SEC then     -- 才檢查是不是誤觸
  currentState = STATE.IDLE           -- 立刻回 IDLE
  return
```

一次 0.04 秒的誤觸也會留下待處理的 timer，而狀態已經回到 IDLE——下一次錄音
可以立刻開始，兩組 timer 搶同一對變數。log 裡真的有
`recording: 按住 0.04s`，前提條件已在生產環境發生過。

**修這個問題時發現同源的第二處**（review 未指出）：轉錄 task 的 exit
callback 也在呼叫取消函式，會砍掉「錄音」那邊還沒觸發的升級鏈。而
`killTask` 從來沒有用在轉錄 task 上——它自己根本沒有 timer 可取消。
可達序列：錄音 X 的轉錄還在跑時發生誤觸 Y，Y 排下升級鏈；X 的轉錄結束就
砍掉 Y 的升級鏈，Y 若卡死便再也沒人收。純粹的誤傷，已移除。

改成 `killTimers[task] = { fallback, hard }`，閉包抓的是該 task 專屬的
table，別次錄音永遠碰不到。

### Fixed — N5：正規化失敗時，快取身分在說謊

`variant_raw` 原本用 `NORMALIZE_ENABLED`（**要求值**）。正規化失敗時我們用
原始音訊繼續轉錄——結果並沒有被正規化，卻存進了 `normalize=true` 的身分。
之後 ffmpeg 恢復正常，查快取會一直命中那筆髒資料，而且永遠不會被更新。

拆成兩個變數：`NORMALIZE_ENABLED`（要求）與 `NORMALIZE_APPLIED`（實際）。
查快取時樂觀假設會成功；三條失敗路徑（ffmpeg 不在、`mktemp` 失敗、ffmpeg
執行失敗）都把 `APPLIED` 打回 `false`，寫入時就會落在正確的身分底下。

這正是 `transcribe.sh` 既有的做法——寫快取前會用 `ACTUAL_BACKEND` 重算一次
identity。`docs/ARCHITECTURE.md` 早就寫了「identity 描述實際完成推理的
backend，不是偏好」，v4.1.0 加正規化時沒有沿用這條原則。

### Fixed — N6：reload 空窗會讓 ffmpeg 逃掉

放開熱鍵後 `recordTask` 立刻設為 nil，行程只存在於區域變數裡，要等 3 秒
逾時才進追蹤表。這段期間 `hs.reload()` 的話，`cleanup()` 兩邊都找不到它。

（這個空窗 v4.1.0 之前就存在，不是新的迴歸——v4.1.0 只補上了 3 秒之後的
部分。review 把它列為對本次 diff 的發現，沒做這層分流。）

改成一啟動就登記，整段空窗消失。`timedOut` 拆成獨立旗標：若混為一談，
每次錄音都會被當成 orphan 而無條件記錄 stderr，log 會迅速膨脹。

### Fixed — N6b：追蹤表沒有上限

SIGKILL 之後仍不死的行程實務上幾乎不存在，但沒有上限就是沒有上限。
超過 8 筆就丟掉最舊的引用並記一行 log（丟掉只是不再追蹤，該行程此時早已
被 SIGKILL 過）。

### Added — N7：`last_model.txt`（實際完成推理的模型）

v4.1.1 的「實際生效的模型」是**起飛前預測**，它無法預知某次轉錄會不會降級
到 fallback model。`transcribe.sh` 現在把實際跑完推理的模型寫進
`last_model.txt`（快取命中時從 cache key 還原），Diagnostics 新增對應項目，
與目前設定不一致時給警告。做法比照既有的 `last_backend.txt`。

### Fixed — 文件：`dynaudnorm` 的 15.5 秒不是 lookahead

15.5 秒是視窗總長（500ms 幀 × 31 幀高斯視窗），但對稱視窗只預填一半，
**實際啟動延遲約 7.5~8 秒**。原本的寫法暗示那是 lookahead，不精確。
「錄 8 秒、硬砍後仍是 0 bytes」的實測結果不受影響。

### Testing

`./tests/run.sh` → **253 passed, 0 failed, 0 skipped**（前一版 248）。

新增並**雙向驗證**的斷言：

- 正規化失敗 → 存進 `normalize=false` 的身分（改回用要求值，該條確實會紅）
- 正規化成功 → 身分與失敗時不同
- `last_model.txt` 正常情況記主模型
- `last_model.txt` 降級時記 **fallback**，不是主模型（改成只記主模型，
  該條確實會紅）

過程中專案自己的 linter 抓到新測試碼的一個 bash 陷阱：`"$key_ok）"` 的全形
括號會被當成變數名的一部分，必須寫成 `"${key_ok}）"`。

**N4 與 N6 沒有自動化斷言**——它們在 Hammerspoon 的非同步流程裡，測試套件
模擬不了。只有 `luac -p` 的語法檢查，行為待真機驗證。

### review 本身的評估

同時記下這份第三方 review 的問題，避免下次照單全收：

- **把既有問題當成本次 diff 的缺陷**（N6 的空窗 v4.1.0 之前就在）
- **完全沒評新增的測試**（21 條斷言與 `FAKE_ECHO_SR` 的忠實度）
- **沒發現證據就在 repo 裡**：N4 只論證到「理論可達」，但 log 裡就有
  `按住 0.04s`
- **對實驗設計的質疑停在「未證實」**，沒給出能了結的對照實驗
- 引用的 11 個 file:line **全部準確**

### 仍未解決

**`-flush_packets` 的病因歸因尚未證實。** 所有緩衝實驗都用 `lavfi` 合成
音源，缺少「真實 avfoundation 且不加 flag」的對照組。修法有效已由真機
驗證（`size=65922`），但「不加 flag 時真實錄音會全程 0 bytes」目前只是
高度合理的推論。

---

## [4.1.1] — Diagnostics 報的是候選清單，不是實際用的模型

`transcribe.sh` 未變動，維持 2.11.0。

### Diagnostics — 新增「實際生效的模型」

真機上撞到的落差：

```
Model 檔案      — /Users/…/models/ggml-small-q5_1.bin (181MB) [Q5_1]
實際每次轉錄用的 — ggml-large-v3-turbo-q5_0.bin
```

兩個數字都沒錯。「Model 檔案」報的是**候選清單掃描**的結果，而
`lang_models` 的 per-app 設定會蓋過它——這台機器的 `_default` 指定了 turbo。

問題在於**使用者會拿 Diagnostics 判斷「我現在到底在用哪個模型」**，而它給
的是錯的答案。這台機器的 turbo 是刻意選的（見 CHANGELOG v4.0.x 的真機 A/B：
turbo 純中文勝、small 技術術語勝），拿錯資訊做判斷會直接推翻那個結論。

新增一行報實際生效的那個，並標明來源：

```
✅ 實際生效的模型 — ggml-large-v3-turbo-q5_0.bin — lang_models 指定 · lang=zh（前景 App：Google Chrome）
```

語言一併顯示，因為它來自同一筆設定，而且 `lang: auto` 有記錄在案的坑——
會把中文判成英文並「翻譯」成英文。沒設 lang 時這裡會直接標出來：

```
lang=auto ⚠️ 中文會被判成英文並翻譯
```

前景 App 也一起報，因為 per-app 設定的生效與否取決於它。

### Testing

`./tests/run.sh` → **248 passed, 0 failed, 0 skipped**（此版未新增斷言：
`runDiagnostics` 依賴 `hs.application.frontmostApplication`，測試套件中無法
取得前景 App）。

真機驗證（2026-09-04 23:21，`hs.reload()` 後執行 Diagnostics）：
新的一行如實顯示 `ggml-large-v3-turbo-q5_0.bin — lang_models 指定 · lang=zh`，
與 log 中每次 `CACHE STORE` 的 model 一致。

---

## [4.1.0] — 0 bytes 錄音的根治

`transcribe.sh` 2.10.2 → **2.11.0**（新增響度正規化步驟）。

### 病根：錄音進行中，磁碟上的檔案是空的

v4.0.8 的診斷在 2026-09-04 20:56 抓到第一份完整證據：

```
20:56:37  recording: 按住 5.01s
20:56:38  killTask: SIGINT timeout, sent SIGTERM
20:56:40  recording: ffmpeg 未結束（SIGINT 後 3.68s）
20:56:40  ffmpeg 未在 3.0s 內結束，仍嘗試讀取錄音檔
20:56:40  skipped: 錄音檔過小（0 bytes）（按住 5.01s）
```

順著這條線做了受控實驗（`-re` 即時速率、16kHz mono、合成音源），每 0.5 秒
量一次磁碟上的檔案：

```
 0.5s → 0 bytes（理論應有  16000）
 ...
 6.0s → 0 bytes（理論應有 192000）
```

**錄了 6 秒，檔案從頭到尾都是 0 bytes。** 整段音訊待在 ffmpeg 的輸出緩衝區
裡，要到乾淨關檔才一次寫出。

這代表整個設計壓在一個我們控制不了的前提上：**只要 ffmpeg 沒有優雅地關閉，
錄音就 100% 消失**——不是壞掉一部分，是全部。而它會不會乖乖關閉，取決於
麥克風有沒有被別的程序搶走、藍牙裝置有沒有切換、系統是不是剛睡醒。

（v4.0.9 草稿裡把原因寫成「WAV header 要等關檔才補寫」。那是錯的：ffmpeg
用 `RIFF ffffffff` 佔位，header 沒補回去的檔案照樣解得動。真正的原因是輸出
緩衝。）

### Fixed — N2：錄音加上 `-flush_packets 1`

叫 ffmpeg 每收到一段音訊就寫進磁碟，不要囤。實測（錄 3 秒後 `kill -9`）：

| 寫法 | 執行中磁碟上 | 硬砍後保住 |
|---|---|---|
| 沒有 flush_packets | 0 bytes | **0 bytes** |
| 有 flush_packets | 112,718 bytes | **112,718 bytes** |

用 `ptt_whisper.lua` 實際組出來的 argv 逐字重跑（只把 avfoundation 麥克風
換成合成音源），硬砍後的檔案是 16000Hz / mono / 3.52 秒，**真正的
whisper-cli 讀得動**（`processing 'REC.wav' (56320 samples, 3.5 sec)`）。

錄音從此隨時都是有效的，「停止錄音」不再是攸關成敗的關鍵步驟。

### Fixed — N1：`loudnorm` 移出錄音濾波鏈

`-flush_packets` 解決了輸出端，但濾波圖自己也會囤。`loudnorm` 要「先聽一段
再決定音量」，實測壓著約 2.4 秒：

| 濾波器鏈 | 錄 2s 保住 | 錄 4s 保住 | 錄 8s 保住 |
|---|---|---|---|
| `highpass,lowpass` | 2.5s | 4.5s | 8.5s |
| 加 `loudnorm` | **0 bytes** | 1.6s | 5.6s |
| 加 `dynaudnorm` | **0 bytes** | **0 bytes** | **0 bytes** |

（`dynaudnorm` 不能當替代品：預設 500ms 幀 × 31 幀高斯視窗 ＝ 15.5 秒視窗，
對稱視窗只預填一半，**實際啟動延遲約 7.5~8 秒**——不是 15.5 秒的 lookahead，
但已比 loudnorm 的 2.4 秒糟得多，上表錄 8 秒仍是 0 bytes 就是這個緣故。）

正規化本來就不需要即時做。改由 `transcribe.sh` 在 cache lookup 之後、推理
之前執行（`WHISPER_NORMALIZE=true`），效果相同而沒有即時性限制。錄音端的
濾波鏈從此只放逐樣本即時的濾波器——這條規則已寫進 `docs/ARCHITECTURE.md`。

`-ar 16000` 不能省：loudnorm 內部以 192kHz 運作，漏掉就會產出 192kHz 的檔案
（已實測），而 whisper.cpp 只吃 16kHz、餵錯不會報錯只會給垃圾。已有迴歸測試
守住，並雙向驗證過（拿掉 `-ar` 該條斷言確實會紅）。

### Fixed — N3：SIGTERM 之後補上 SIGKILL

以前不敢硬砍，因為硬砍等於毀掉整段錄音。有了 N2 就沒有這個顧慮，而留著卡死
的 ffmpeg 反而更糟——它會繼續占住 AVFoundation 裝置，害下一次錄音也失敗。

時間軸：SIGINT `0s` → SIGTERM `2.0s` → SIGKILL `2.8s` → 放棄等待 `3.0s`。
`hs.task` 沒有提供 SIGKILL，用 `/bin/kill -9 <pid>` 送。

### Fixed — B4：逾時路徑的訊息與 stderr

- **不再一律報「請按住久一點」**。ffmpeg 沒結束而檔案又不足，跟「你按太短」
  是完全不同的病；2026-09-04 那次使用者按住了 5.01 秒，舊訊息把追查方向帶
  去完全錯誤的地方。
- **逾時不再整段放棄**。有了 `-flush_packets`，磁碟上通常已經有幾乎完整的
  音訊，照常轉錄並記錄「可能少了結尾片段」。
  （v4.0.9 草稿的做法是直接放棄——那在還沒有 flush_packets 的前提下才正確。
  前提變了，做法就跟著變。）
- **留住逾時 task 的引用**。`hs.task` 一旦沒有 Lua 端引用就會被 GC，exit
  callback 永遠不觸發、stderr 永遠拿不到——20 筆 `ffmpeg exit=` 記錄裡沒有
  20:56:40 那一次，推測就是這個原因（未驗證）。orphan 一律附上 stderr。
- **`cleanup()` 收掉滯留的 ffmpeg**，否則它會跨越 `hs.reload()` 繼續占住
  麥克風。

### Fixed — L1：兩處迴圈變數重新指派

v4.0.8 在 `tailLines` 修過「不可重新指派 for 的迴圈變數」，但檔案裡其實有
三處，當時只修了一處。剩下的在 `loadHallucinationsFromFile()` 與
`runDiagnostics()`，害**整個檔案在 Lua 5.5 下無法載入**——也就是說 `luac -p`
這道防線一直停在同一個錯誤上，後面的內容從來沒被檢查到。

行為未變，已用真實資料對拍：現行 `hallucinations_builtin.txt` 跑新舊兩種
寫法，43 條規則、集合內容逐項相同。

### Testing

`./tests/run.sh` → **248 passed, 0 failed, 0 skipped**（前一版 227）。

新增 `tests/cases/25-normalize.sh`（21 條），涵蓋：預設關閉、明確開啟、
送進推理的是正規化後的暫存檔、暫存檔清理、非法值、正規化失敗降級用原始
音訊、快取 key 不互相污染、**輸出仍是 16kHz**。

`fake-whisper-cli` 新增 `FAKE_ECHO_SR`：回報它實際收到的音檔取樣率。
「送進推理的檔案是幾 Hz」必須是能斷言的事實，否則 `-ar` 這種坑會再長回來。

`luac -p ptt_whisper.lua` 乾淨通過（L1 修好之後第一次真正跑完整份檔案）。

#### 真機驗證（2026-09-04 23:10，macOS 26.6.2 · Hammerspoon 1.1.1）

用 `tests/manual/freeze-ffmpeg.sh` 在真機逼出「ffmpeg 完全不回應訊號」的情境
（`SIGSTOP` 凍住它——這正是 20:56 那次實際發生的狀態，見下）：

```
23:10:20  recording: 按住 8.34s
23:10:22  killTask: SIGINT timeout, sent SIGTERM
23:10:23  killTask: SIGTERM timeout, sent SIGKILL to pid 22903
23:10:23  recording: ffmpeg exit=9 size=65922 bytes state=transcribing
23:10:23  recording: ffmpeg stderr（尾端 12 行）
23:10:23  recording: ffmpeg 已結束（SIGINT 後 2.88s）
23:10:23  INFO: normalized (loudnorm=I=-16:TP=-1.5)
23:10:24  CACHE STORE (cli): e52c1c20...
```

| 改動 | 驗證結果 |
|---|---|
| N2 `-flush_packets 1` | **`size=65922` bytes** —— 同情境下舊版必定是 `0 bytes` |
| N3 SIGKILL 升級 | 2.88s 送出，`exit=9`（趕在 3.0s 放棄等待之前） |
| N1 正規化移到事後 | `INFO: normalized`，whisper 收到 2.1 秒音訊 |
| B4 stderr 補記錄 | 第一次拿到卡死錄音的 stderr，12 行 |
| 整體 | **轉錄正常完成**，事後無任何 ffmpeg 殘留 |

音訊只有 2.06 秒是測試設計使然（腳本在第 2 秒凍住 ffmpeg），不是資料遺失。

#### 一併查明：ffmpeg 為什麼「不肯結束」

驗證過程中在機器上發現 pid 68457 —— **就是 20:56 那次 0 bytes 失敗的
ffmpeg，已存活 2 小時 08 分**，父行程 Hammerspoon，狀態 `STAT=T`。

`T` 代表**已停止（suspended）**。停止中的行程不會處理訊號，SIGINT / SIGTERM
只會排隊等著，什麼都不會發生。它不是「不理我們」，是**沒有在執行、沒辦法理**。

實測確認（對受控行程送訊號）：

```
停住後狀態: TN
送 SIGINT  之後: TN   ← 無效
送 SIGTERM 之後: TN   ← 無效
送 SIGKILL 之後: 已結束
```

**SIGKILL 是唯一能作用在已停止行程上的訊號**，所以 N3 不是額外的保險，
而是這個情境下唯一能收掉它的手段；N2 則保證硬砍不毀資料。兩者互為前提。

它為什麼會被停止，仍未查明（已排除 SIGTTIN：該行程沒有 controlling
terminal、stdin 是 pipe）。但 v4.1.0 讓這個答案不再是必要條件。

#### 已知的粗糙邊緣（不處理）

被 SIGKILL 砍掉的 WAV，結尾會有半個沒寫完的取樣，ffmpeg 讀取時會抱怨
`corrupt input packet in stream 0`，但照常處理完、whisper 也正常讀出。
代價是最後幾毫秒——相對於以前整段消失，這個交換是划算的。

### 升級注意

- **快取會全部失效一次**：variant hash 新增了 normalize 欄位。
- `config.json` 若自訂過 `audio_filter_chain` 且含 `loudnorm`，建議拿掉，
  改用新的 `audio_normalize`（預設 `true`）。留著不會壞，但會重新引入 2.4
  秒的囤積。

---

## [4.0.8] — 錄音診斷

`transcribe.sh` 未變動，維持 2.10.2。純診斷改動，不改變任何控制流程。

### Diagnostics — ffmpeg 的 stderr 不再被丟棄

「錄音檔 0 bytes」在真機上復現四次以上，每次都查不出原因。癥結是**能解釋
原因的訊息從來沒有被記錄**：

```lua
recordTask = hs.task.new(ffmpeg, function(exitCode, _, stderr)
  if exitCode ~= 0 and exitCode ~= 255 and currentState == STATE.RECORDING then
    ... appendErrorLog("... stderr=" .. stderr)   -- 只有這裡會寫 stderr
```

但失敗案例中 ffmpeg 會拖到我們早已進入 `TRANSCRIBING` 之後才結束，
`currentState == STATE.RECORDING` 不成立，stderr 被靜靜丟棄。

現在每次錄音結束都記錄一行：

```
recording: ffmpeg exit=255 size=48272 bytes state=transcribing
```

並且在 exit code 非預期（不是 0/255）**或**檔案小於 `MIN_FILE_BYTES` 時，
additionally 附上 stderr 的尾端 12 行：

```
recording: ffmpeg stderr（尾端 12 行）
    [AVFoundation indev @ 0x600] Selected audio device
    [in#0 @ 0x600] Error opening input: Device or resource busy
```

只在出問題時附 stderr——ffmpeg 每次都會印一大段版本橫幅，無條件記錄會讓
log 迅速膨脹。取尾端而非開頭，因為橫幅在前、錯誤在後。

截取邏輯抽成純函式 `tailLines`，12 條單元測試（nil / 空字串 / 只有空白 /
非字串 / 行數不足 / trim / 空行不計入 / n 非數字 / ffmpeg 形態的輸出）。

### Fixed — 測試套件會在直譯器中途崩潰時誤報 PASS

寫上面那 12 條測試時撞到的：`tailLines` 初版在 `for` 迴圈裡重新指派迴圈
變數，Lua 5.5 起這是 const，直接報錯（Hammerspoon 用 5.4 可以，
但沒有理由寫成只在特定版本能跑）。

真正的問題是**測試套件沒有抓到**：lua 產出了 51 條 PASS 之後才崩潰，
而崩潰偵測只檢查「有沒有產出斷言」（`n_assert -eq 0`），51 > 0 所以
沒觸發，套件回報 `215 passed / RESULT: PASS`——但 12 條新斷言一條都沒跑。

現在額外檢查 exit code：產出了斷言但 exit 非 0 且沒有任何 `FAIL` 行，
即判定為「中途崩潰，其餘斷言未執行」。已雙向驗證（故意重現該 bug 時
會報 `在第 67 條之後崩潰（exit=1）`）。

### Testing

`./tests/run.sh` → **227 passed, 0 failed, 0 skipped**（前一版 215）。

---

## [4.0.7] — 剪貼簿寫入失敗的判定

`transcribe.sh` 未變動，維持 2.10.2。

### Fixed — `pcall` 的回傳值只檢查了一半

v4.0.6 的還原迴圈是：

```lua
local ok = pcall(hs.pasteboard.writeDataForUTI, nil, uti, data, wrote > 0)
if ok then wrote = wrote + 1 end
```

`pcall` 的第一個回傳值只代表「沒有 throw」。`writeDataForUTI` **另外**會
回傳 boolean 表示是否真的寫入成功，這個值被忽略了。寫入失敗（回 `false`
但不報錯）仍會被算成功，後果有兩層：

1. `wrote` 永遠 > 0，`wrote == 0` 的純文字 fallback 不會被觸發
2. **更嚴重**：第一筆失敗卻被計入時，第二筆會用 `add=true`，而此時剪貼簿上
   還是語音轉錄的文字（沒有任何一次成功的 `add=false` 清空過它），
   於是把使用者的原始內容**疊加**到轉錄文字上，而不是取代它

修正為 `local callOk, writeOk = pcall(...)` 並同時檢查兩者。`add` 的依據
維持「已成功寫入幾筆」（`wrote > 0`），不能改用迴圈索引——否則第一筆失敗
後第二筆就會錯誤地疊加。

### Testing

還原迴圈抽成純函式 `restoreClipboardEntries(entries, writeFn)`，writer 由
外部注入。production 傳入 `hs.pasteboard.writeDataForUTI`；測試傳入可控的
假 writer，因此**失敗路徑可以進自動化測試**：

| case | 情境 | 期望 |
|---|---|---|
| A | pcall 成功 + 回 true | 計入 |
| B | pcall 成功 + 回 false | **不可**計入 |
| C | writer throw | **不可**計入 |
| D | 全部失敗 | `wrote = 0`，fallback 可達 |
| — | 第一筆失敗 | 第二筆仍須 `add=false` |
| — | 中間失敗 | 第三筆維持 `add=true`，不重新清空 |

14 條斷言，執行的是從 `ptt_whisper.lua` 抽出的同一份出貨程式碼。
把修正還原成舊寫法後，其中 5 條會失敗（含 `add` 那條），雙向驗證過。

**為什麼失敗路徑只能靠注入測**：實測 `writeDataForUTI` 在這個 Hammerspoon
版本用空 UTI、非法 UTI、不存在的 pasteboard 名稱**都回 `true`**，
無法在真實 runtime 逼出 `false`。

`./tests/run.sh` → **215 passed, 0 failed, 0 skipped**（前一版 201）。
真機 `clipboard-roundtrip.lua` → 5 passed，4 個 UTI 全部還原。

### Docs

- `REAL_MAC_VALIDATION.md` 開頭改為準確的歷史敘述（原本仍寫「開發環境沒有
  runtime」，但這台 Mac 已完成 fresh-install validation），並列出兩處
  test double 與 production API 的對照
- 第 22 項不再要求驗證初次啟動的 `503 loading`——原始碼與實測都證實
  它在初次啟動時不可觀察
- 第 30 項的 `max_context` 敘述更新（預設已是 `-1`）

---

## [4.0.6] — 剪貼簿還原資料遺失

### Fixed — 剪貼簿還原會吃掉多型別內容

貼上語音轉錄後，原本複製的內容消失，`Cmd+V` 貼不出任何東西。

`hs.pasteboard.writeDataForUTI(name, uti, data, add)` 的第 4 個參數 `add`
**預設為 `false`**，也就是每次呼叫都會先清空剪貼簿再寫入。原本的還原迴圈
沒有帶這個參數，跑完只剩下**最後一個** UTI。

真機重現（模擬從文件複製，4 個型別）：

```
【現行】getContents() = nil
【現行】剩下的 UTI = public.html        ← 只剩最後一個
【修正】getContents() = 原本複製的重要內容-ABC123
【修正】剩下的 UTI = 全部 4 個型別
```

單一型別的純文字剪貼簿不受影響（從終端機複製的內容能正常還原），
只有從文件／網頁複製的多型別內容會被吃掉——所以很容易漏掉。

修正：第一次寫入用 `add=false`（等同清空後寫入），之後一律 `add=true` 疊加。
另加保險：若所有 UTI 都寫入失敗，至少把 `public.utf8-plain-text` 救回來，
不要留下空的剪貼簿。

新增 `tests/manual/clipboard-roundtrip.lua`。這一層無法納入 `run.sh`——
它依賴 Hammerspoon 的 `hs.pasteboard`，而該模組只存在於 Hammerspoon runtime。

### Diagnostics — 錄音

0 bytes 錄音在改用「等 ffmpeg 真正結束」之後仍發生一次，但這次 ffmpeg
**超過 2 秒沒回應 SIGINT**，遠超過實測的 0.7~0.9 秒——與先前三次是不同的
狀況。手上沒有足夠資訊判斷原因（程式沒有記錄按鍵時長），因此先加診斷
而不是再猜一次：

```
recording: 按住 16.23s
recording: ffmpeg 已結束（SIGINT 後 0.47s）
```

同時把 0 bytes 的提示由技術訊息改為可操作的說明：
「沒有錄到聲音，請按住久一點再說話」。

---

## [4.0.5] — 真機聽寫實測抓到的問題

實際按住熱鍵講話才會暴露的問題。前面所有自動化測試與 headless 驗證都無法觸及。

### Fixed — Right Option 熱鍵完全沒反應

按住 Right Option 沒有任何反應，log 一行都沒有增加。

`hs.hotkey` 底層是 Carbon 的 `RegisterEventHotKey`，它**不會對單獨按下的
修飾鍵觸發**——macOS 對修飾鍵送的是 `flagsChanged` 事件，不是 keyDown/keyUp。
`hs.hotkey.bind({}, "rightalt", ...)` 會「註冊成功」但永遠不會被呼叫。

改用 `hs.eventtap` 監聽 `flagsChanged`：

- 用 IOKit 的裝置特定遮罩（右 Option = `0x40`）分辨左右。
  `getFlags().alt` 不分左右，左右同時按會誤判
- 非修飾鍵仍走 `hs.hotkey`（對一般按鍵它是正確且更省資源的做法）
- 回傳 `false` 不吞掉事件，其他 App 照常收到該修飾鍵
- `cleanup()` 收掉 eventtap，避免 reload 累積多個 tap

遮罩判斷抽成純函式 `maskIsSet` 並加上 10 條單元測試（含左右同時按住、
含粗粒度 alt 位元、其他修飾鍵不誤判等）。

### Fixed — 短按產生 0 bytes 錄音

三輪真機測試三次命中：

```
[17:08:09] killTask: SIGINT timeout, sent SIGTERM → 錄音檔過小（0 bytes）
[17:18:09] killTask: SIGINT timeout, sent SIGTERM → 錄音檔過小（0 bytes）
[17:27:10] killTask: SIGINT timeout, sent SIGTERM → 錄音檔過小（0 bytes）
```

實測 ffmpeg 收到 SIGINT 後需要 **0.7~0.9 秒**才寫完並收尾 WAV：

```
按住 0.4s → 19174 bytes（實際耗時 1.31s）
按住 0.6s → 18720 bytes（實際耗時 1.27s）
按住 0.4s → 14414 bytes（實際耗時 1.26s）
```

但原本 `KILL_FALLBACK_SEC = 0.5` 會在收尾中途送 SIGTERM 砍掉它，
而 `FFMPEG_FLUSH_SEC = 0.3` 又在寫完之前就去檢查檔案。

修正不是把常數調大猜一個值，而是**等 ffmpeg 行程真正結束再檢查**
（沿用 server 重啟用的 `waitForTaskExit`）。`KILL_FALLBACK_SEC` 一併拉到
2.0 秒，不再打斷正常收尾。

### Docs — README 三處建議修正（皆有真機證據）

- **刪掉「initial_prompt 只放詞彙，不要放句子」。** 這條建議正是中文輸出
  沒有標點的原因：

  | initial_prompt | 中文輸出標點 |
  |---|---|
  | 純詞彙表（無句末標點） | **完全沒有**（3 段皆是） |
  | 自然中文句子含 `，、？。` | **完整**（2 段皆是） |

  英文沒有這個差異（三種 prompt 風格輸出完全相同），推測是中文標點在小模型
  上較弱、更依賴 prompt 的風格引導。

- **新增「詞彙表外的詞會被吸附」。** 實測講 `Typeless`（不在表內）被辨識成
  `Kubernetes`（表內）。把該詞加進 prompt 後即正確辨識。這不是 bug，是
  initial prompt 的固有機制。

- **新增「不要依賴 `lang: auto`」。** 實測講中文被判成英文，且輸出被**翻譯**
  成英文（「我要測試中文語音辨識」→ `I want to test Chinese language.`）。
  明確設 `"lang": "zh"` 後正常。

---

## [4.0.4] / transcribe.sh 2.10.2 — 真機驗證抓到的兩個 blocker

兩個問題都通過了 191 條自動化斷言，只有在真實 Mac 上跑真實 whisper.cpp
才暴露出來。

### Fixed — CLI 路徑輸出重複

每一次 CLI 轉錄，文字都會被輸出**兩次**：

```
This is a PTT Whisper Runtime Test.This is a PTT Whisper Runtime Test.
```

`whisper-cli` 會**同時**把轉錄文字印到 stdout **和**寫進 `-otxt` 指定的
檔案，而 `run_whisper()` 只導走 stderr，stdout 直接漏到腳本輸出，再加上
結尾正常的 `printf "$result"`。

```
whisper-cli stdout : '\n This is a PTT Whisper Runtime Test.'
-otxt 檔案內容      : 'This is a PTT Whisper Runtime Test.'
```

修正：`run_whisper()` 的兩處執行都加 `>/dev/null`。唯一的真實來源是
`${OUT_PREFIX}.txt`。server 路徑不受影響（curl `-o` 寫檔）。

**這個 bug 自初版（`ebfd32b`）就存在**，不是這輪重構引入的。

**為什麼 191 條測試沒抓到**：`fake-whisper-cli` 只寫檔、不印 stdout，
與真實行為偏離。這是測試套件自己的缺陷，已一併修正——fake 現在忠實地
同時印 stdout 與寫檔，並新增 `tests/cases/05-output-integrity.sh`
（6 條斷言，涵蓋 CLI / server / server 失敗退回 CLI 三條路徑）。
移除修正後該組測試會失敗，雙向驗證過。

### Fixed — `max_context: 0` 讓 `initial_prompt` 完全失效

`-mc 0` 會清空 text context，而 initial prompt 的 token 就活在裡面。
兩者都是 v3.7.0 的預設值，**互相抵銷**——被描述為「準確度最大的槓桿」
的功能，在出貨預設值下是關閉的。

真機 A/B（同一段音訊、同一組 prompt）：

| 設定 | 輸出 |
|---|---|
| 有 prompt、無 `-mc` | `Cloud Code … **vLLM** and **Qwen**` ✅ |
| 有 prompt、`-mc 0` | `cloud code … **VLLM** and **Quen**` ❌ |
| 有 prompt、`-mc 64` | `Cloud Code … **vLLM** and **Qwen**` ✅ |

CLI 端 `-mc 0` 甚至更糟：`VLLM and Quint Speech Recognition`。

修正：

- `max_context` 預設由 `0` 改為 `-1`（= 不帶 `-mc`，用 whisper 預設）
- 有效範圍由 `0~224` 改為 `-1~224`；負數一律視為「不帶旗標」
- 同時設定 `initial_prompt` 與 `max_context: 0` 時，載入會發出明確警告，
  Run Diagnostics 的「config.json 驗證」也看得到
- 明確設定 `0` 仍會被尊重（帶 `-mc 0`）——那是使用者的選擇

「關掉 context 能減少重複／拖尾幻覺」這個**原始假設本身仍未被驗證**，
只證明了它的副作用不可接受。README 與 ARCHITECTURE 的措辭已同步修正。

### Docs

- `REAL_MAC_VALIDATION.md` 第 13 項標記為**已驗證**，並修正期待：
  503 `loading` 在初次啟動時不可觀察。whisper.cpp 的 server 先載入模型
  （`server.cpp:726`）、再 `state.store(READY)`（735），HTTP listen 更晚，
  因此啟動期間只會是 connection-refused，狀態直接「啟動中…」→「就緒」。
  503 只在 runtime 呼叫 `/load` 換模型時出現。`classifyHealthResponse`
  兩條路徑都處理正確，`loading` 分支屬防禦性程式碼。

### Testing

`./tests/run.sh` → **191 passed, 0 failed, 0 skipped**（前一版 181）。

---

## [4.0.3] / transcribe.sh 2.10.1 — 測試套件的 merge-gate 語意

### Changed

- **`lua` 成為完整測試套件的必要依賴。** `./tests/run.sh` 在找不到 lua
  直譯器時**失敗並回傳非零 exit code**，不再靜靜地 skip 然後報告成功。
  理由：`classifyHealthResponse` 的實際出貨程式碼若沒有被執行，
  整套 regression suite 不應被視為完整通過。

- **統一規則：預設模式下任何 skip 都算失敗。** 旗標命名為
  `PTT_TEST_ALLOW_MISSING_DEPS`（而非只針對 lua），因為 merge gate 的
  實質要求是「0 skipped」，而 lua 不是唯一會造成 skip 的依賴——
  `ffmpeg` / `ffprobe` 缺席時 8kHz resample 測試也會 skip。

- **opt-out 是機器可辨識的，不只是視覺上不同。**
  `PTT_TEST_ALLOW_MISSING_DEPS=1` 會印出醒目警告方塊，並在結尾輸出
  純文字的 `RESULT: PARTIAL`（完整通過是 `RESULT: PASS`）。
  exit code 維持 0——那是刻意的開發者選擇——但腳本可以 grep 出差別。

### Fixed

- **lua 存在但執行失敗時不再被當成通過。** 若直譯器崩潰（語法錯誤、
  抽取失敗…），一條斷言都不會產出，而原本的實作會顯示「0 failed」——
  看起來完全正常，實際上 43 條斷言一條都沒跑。這比「沒有 lua」更危險。
  現在「有 lua 但產出 0 條斷言」是硬失敗，並印出直譯器輸出。

- **`$VAR` 緊接非 ASCII 字元的寫法。** `"（exit=$lua_rc）"` 會讓 bash 把
  全形括號的位元組吃進變數名，在 `set -u` 下直接 `unbound variable`
  中止腳本。`bash -n` 抓不到這種問題，只有該行真的被執行時才會爆。
  修掉發現的一處，並把掃描加成常駐靜態檢查
  （`tests/lib/shell_var_scan.py`）。

### Docs

- `tests/README.md` 新增依賴表與 merge gate 語意說明。
  明確寫出 `./tests/run.sh` = 完整 merge-gate 測試、
  `PTT_TEST_ALLOW_MISSING_DEPS=1` = partial developer test only，
  不足以作為合併依據。測試套件不會自動安裝任何依賴。

### Testing

`./tests/run.sh` → **181 passed, 0 failed, 0 skipped**（多一條靜態檢查）。

四種情境都實測過：

| 情境 | 結果 |
|---|---|
| 有 lua（正常） | `RESULT: PASS`，exit 0 |
| 無 lua，預設 | `RESULT: FAIL`，exit 1，附安裝與 opt-out 指引 |
| 無 lua，opt-out | `RESULT: PARTIAL`，exit 0，醒目警告方塊 |
| 有 lua 但崩潰 | `RESULT: FAIL`，附直譯器輸出 |

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
