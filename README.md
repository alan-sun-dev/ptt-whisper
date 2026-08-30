# 🎤 PTT Whisper

> Push-to-Talk offline dictation for macOS using Hammerspoon + whisper.cpp

按住快捷鍵說話，放開自動轉錄並貼上文字。完全離線、零雲端依賴。

<!-- TODO: 加入 demo GIF -->
<!-- ![demo](docs/screenshots/demo.gif) -->

---

## ✨ 功能特色

- **Push-to-Talk 語音輸入** — 按住 Right Option 錄音，放開即轉錄貼上
- **完全離線** — 使用本地 whisper.cpp 推理，資料不離開你的電腦
- **多語言 / 多 App 切換** — 依前景 App 自動切換語言與模型
- **術語注入** 🆕 — 用 initial prompt 餵入專有名詞、人名、中英混用詞，可依 App 疊加
- **VAD 靜音偵測** 🆕 — 自動砍掉靜音段，加速推理並從源頭減少幻覺
- **常駐 Server 模式** 🆕 — 模型常駐記憶體，省掉每次錄音的載入成本
- **幻覺過濾** — 內建 + 自訂列表，過濾 whisper 常見幻覺輸出
- **智慧剪貼簿** — 貼上後自動還原原始剪貼簿內容（支援多 UTI 型別）
- **Fallback Model** — 主模型逾時或失敗時，自動用較小模型重試
- **轉錄快取** — 相同音訊 + 模型 + 語言 = 直接回傳快取結果
- **自動 Resample** — 非 16kHz 音訊自動轉換，免手動處理
- **一鍵診斷** — Menubar → Run Diagnostics 檢查所有依賴
- **Secure Input 偵測** — 偵測到密碼框自動中止貼上，保護安全

---

## 📦 系統需求

| 項目 | 需求 |
|------|------|
| macOS | 12.0+ (Monterey 以上) |
| [Hammerspoon](https://www.hammerspoon.org/) | 0.9.100+ |
| [whisper.cpp](https://github.com/ggerganov/whisper.cpp) | 已編譯，建議最新版 |
| ffmpeg | `brew install ffmpeg` |
| Model 檔案 | 至少一個 ggml model（建議 `ggml-small-q5_1.bin`）|
| VAD Model | 選用 — `ggml-silero-*.bin`，啟用 VAD 才需要 |
| coreutils | `brew install coreutils`（提供 `gtimeout`）|

---

## 🚀 安裝

### 1. 安裝依賴

```bash
# Hammerspoon（若尚未安裝）
brew install --cask hammerspoon

# ffmpeg + coreutils（coreutils 提供 gtimeout）
brew install ffmpeg coreutils cmake
```

### 2. 建置 whisper.cpp

```bash
git clone https://github.com/ggml-org/whisper.cpp.git ~/whisper.cpp
cd ~/whisper.cpp

cmake -B build
cmake --build build -j --config Release
```

### 3. 下載模型

```bash
cd ~/whisper.cpp

# 日常使用：Q5_1 量化版（推薦）
bash ./models/download-ggml-model.sh small-q5_1

# 可選：tiny 當 fallback（主模型逾時或失敗時自動接手）
bash ./models/download-ggml-model.sh tiny
```

**可選：VAD model**（啟用靜音偵測，建議裝）

```bash
cd ~/whisper.cpp
bash ./models/download-vad-model.sh          # 不帶參數會列出可用的 VAD model
bash ./models/download-vad-model.sh silero-v5.1.2
```

PTT Whisper 是用 glob 掃描 `models/ggml-silero*.bin`，不寫死版本號，
所以下載哪個 silero 版本都能自動認得。裝好之後 `vad_enabled: "auto"`
（預設值）就會自動啟用；沒裝就維持關閉，不會報錯。

**為什麼推薦量化版？**

| | Q5_1 量化版 | FP16 完整版 |
|---|---|---|
| 檔案大小 | ~182 MB | ~466 MB |
| 記憶體佔用 | ~200 MB | ~500 MB |
| 推理速度 | 2~3x | 1x（基準）|
| 準確率 | 幾乎無損（<0.5% WER 差異）| 基準 |

PTT 的錄音通常只有 2~15 秒，量化帶來的精度差異感知不到，但速度差異很明顯。
若你想留一份 FP16 做比對，`bash ./models/download-ggml-model.sh small` 即可，
兩者可以並存。

**模型的選用順序**（`ptt_whisper.lua` 與 `transcribe.sh` 兩端一致）：

```
WHISPER_MODEL 環境變數（最高優先）
  → ggml-small-q5_1.bin
  → ggml-small-q5_0.bin
  → ggml-small-q8_0.bin
  → ggml-small.bin（FP16）
```

放哪個就用哪個，不需要改程式碼。注意 whisper.cpp 的下載腳本對 small
只提供 **q5_1**（q5_0 只有 medium / large 有）；若你偏好 q5_0，需自行量化：

```bash
./build/bin/quantize models/ggml-small.bin models/ggml-small-q5_0.bin q5_0
```

### 4. 安裝 PTT Whisper

```bash
# Clone repo
git clone https://github.com/alan-sun-dev/ptt-whisper.git ~/ptt-whisper

# 部署 transcribe.sh
chmod +x ~/ptt-whisper/transcribe.sh

# 部署共用幻覺過濾列表（Lua 與 Bash 兩端共同載入）
mkdir -p ~/.ptt-whisper
cp ~/ptt-whisper/hallucinations_builtin.txt ~/.ptt-whisper/

# 在 Hammerspoon 載入 Lua 腳本
# 編輯 ~/.hammerspoon/init.lua，加入：
dofile(os.getenv("HOME") .. "/ptt-whisper/ptt_whisper.lua")
```

> 若省略 `hallucinations_builtin.txt` 的部署，兩端會各自退回硬編碼的
> fallback 列表（功能仍正常，但 log 會留下 WARNING，且你對該檔案的
> 修改不會生效）。

### 5. 授予權限

在 **系統設定 → 隱私權與安全性** 中，允許 Hammerspoon 取用：

- ✅ 麥克風
- ✅ 輔助使用（Accessibility）

### 6. Reload Hammerspoon

```
Hammerspoon Console → hs.reload()
```

看到 `🎤 PTT Whisper vX.X.X 已載入` 表示成功！

---

## ⚙️ 設定

首次使用可透過 Menubar → **打開設定檔** 自動建立 `~/.ptt-whisper/config.json`，或手動建立：

```json
{
  "slow_paste_apps": {
    "com.tinyspeck.slackmacgap": 1.0,
    "com.microsoft.teams2": 1.0
  },
  "show_preview_alert": true,

  "cache_enabled": false,
  "fallback_model": "ggml-tiny.bin",

  "audio_filter_chain": "highpass=f=200,lowpass=f=5000,loudnorm=I=-16:TP=-1.5",

  "initial_prompt": "Kubernetes, Terraform, gRPC, PostgreSQL, code review, deploy",
  "vad_enabled": "auto",
  "max_context": 0,
  "whisper_threads": 0,

  "server_mode": false,
  "server_port": 8178,

  "lang_models": {
    "com.tinyspeck.slackmacgap":   { "lang": "en", "model": "ggml-small.en.bin", "prompt": "standup, sprint, PR, rollback" },
    "com.microsoft.teams2":        { "lang": "en", "model": "ggml-small.en.bin" },
    "jp.naver.line.mac":           { "lang": "zh" },
    "_default":                    { "lang": "auto" }
  }
}
```

### 設定欄位說明

| 欄位 | 型別 | 預設值 | 說明 |
|------|------|--------|------|
| `slow_paste_apps` | object | 見上方 | 特定 App 的貼上延遲（秒），避免吃字 |
| `show_preview_alert` | bool | `true` | 轉錄完成時是否顯示預覽 alert |
| `cache_enabled` | bool | `false` | 啟用轉錄結果快取 |
| `fallback_model` | string | `""` | Fallback 模型檔名或完整路徑 |
| `audio_filter_chain` | string | 見下方 | 錄音時的 FFmpeg `-af` 濾波器鏈，設為 `""` 停用 |
| `initial_prompt` | string | `""` | 全域術語表（見「術語注入」）|
| `vad_enabled` | bool 或 `"auto"` | `"auto"` | 靜音偵測。`auto` = 支援且有 model 才啟用 |
| `max_context` | number | `0` | 跨段上下文 token 數，有效 0~224。見下方說明 |
| `whisper_threads` | number | `0` | 推理執行緒數，有效 0~16。`0` = 自動偵測 |
| `server_mode` | bool | `false` | 啟用常駐 whisper-server（見「常駐 Server 模式」）|
| `server_port` | number | `8178` | Server 監聽埠，有效 1024~65535 |
| `lang_models` | object | `{}` | 依 App Bundle ID 切換語言/模型/prompt |

`audio_filter_chain` 預設值為 `highpass=f=200,lowpass=f=5000,loudnorm=I=-16:TP=-1.5`：

| 濾波器 | 作用 |
|--------|------|
| `highpass=f=200` | 切除冷氣、馬路隆隆聲等低頻環境噪音 |
| `lowpass=f=5000` | 切除電路嘶聲、風扇雜音（保留 4~5kHz 齒擦音頻帶）|
| `loudnorm=I=-16:TP=-1.5` | EBU R128 感知響度正規化，防止音量忽大忽小 |

可填入任何合法的 FFmpeg `-af` 參數。改動後用 Menubar → **Run Diagnostics**
確認語法正確（診斷會以 `lavfi` 虛擬音源做 dry-run 驗證）。

#### 關於 `max_context: 0`

預設值 `0` 的理由是：PTT 錄的是獨立短句，不需要跨段上下文，關掉**理論上**
可減少 whisper 的重複與拖尾幻覺。

**這尚未經過真實 whisper.cpp 的 A/B 驗證**，不要當成已證實的最佳值。
要驗證需要涵蓋 2–3 秒 / 5–15 秒 / 20–30 秒，中文、英文、中英混用、
技術術語、口語自我修正等語料，比較 CER/WER、術語命中率、重複、
拖尾幻覺與延遲。若你的實測結果不同，把它調回 whisper 預設即可
（設為空字串或移除該欄位就不會帶 `-mc` 旗標）。

### 環境變數

| 變數 | 預設值 | 說明 |
|------|--------|------|
| `WHISPER_DIR` | `~/whisper.cpp` | whisper.cpp 安裝目錄 |
| `WHISPER_MODEL` | 自動偵測 | 指定模型路徑，覆寫上方的候選清單掃描 |
| `WHISPER_LANG` | `auto` | 預設語言（auto = 自動偵測）|
| `WHISPER_TIMEOUT` | `60` | 轉錄逾時秒數 |
| `WHISPER_AUTO_RESAMPLE` | `true` | 自動 resample 非 16kHz 音訊 |
| `WHISPER_CACHE_MAX` | `50` | 快取保留筆數，有效 5~500（超出自動夾到範圍內）|
| `WHISPER_PROMPT` | `""` | initial prompt（Lua 端會依 config 自動帶入）|
| `WHISPER_PROMPT_MAX_BYTES` | `800` | prompt 長度上限，超過會從尾端截斷 |
| `WHISPER_VAD` | `auto` | `true` / `false` / `auto` |
| `WHISPER_VAD_MODEL` | 自動掃描 | 指定 VAD model 路徑，覆寫 `ggml-silero*.bin` 掃描 |
| `WHISPER_MAX_CONTEXT` | `0` | 對應 whisper 的 `-mc`，留空 = 不帶此旗標 |
| `WHISPER_THREADS` | 自動偵測 | 對應 whisper 的 `-t` |
| `WHISPER_SERVER` | `false` | `true` = 走 HTTP 推理（Lua 端會自動帶入）|
| `WHISPER_SERVER_URL` | `http://127.0.0.1:8178` | whisper-server 位址 |
| `WHISPER_SERVER_MODEL` | `""` | Server 載入的模型路徑，用來判斷能否走 server |

「上次後端」的可能值：`⚡ server`、`📼 CLI`、`📦 快取（server 產生）`、
`📦 快取（CLI 產生）`。快取命中會保留是哪個 backend 產生的，
否則開了 server 又一直命中快取時，會看不出 server 到底有沒有在用。

`WHISPER_CACHE` 與 `WHISPER_FALLBACK_MODEL` 不需手動設定 — Lua 端會依
config.json 的 `cache_enabled` / `fallback_model` 自動帶入。

---

## 🏗️ 架構

錄音之後，所有轉錄都走**同一條後處理管線**：

```
按住熱鍵 → ffmpeg 錄音 → [ ASR backend ] → 統一後處理 → 貼上
                                              │
                          resample · 幻覺過濾 · 標點檢查 · 快取 · fallback model
```

目前有兩個 ASR backend：**CLI**（每次執行 `whisper-cli`）與
**server**（常駐 `whisper-server`）。兩者產出同一份純文字，後處理不需要
區分是哪一條路徑跑的。

> **v4.0.0 移除了 Streaming 模式。** 它是一條繞過上述管線的平行實作，
> 因此幻覺過濾、快取、fallback model、prompt、VAD 都對它無效。
> 未來要重做低延遲串流，必須以 backend 的形式接進這條管線——
> 契約與理由見 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。
> 最後一版實作保存在 `streaming-final` tag。

---

## 🧪 測試

```bash
./tests/run.sh          # 全部
./tests/run.sh 50 80    # 只跑編號開頭符合的
```

不需要真的 whisper.cpp、模型檔或 Hammerspoon —— 推理由 fake 提供。
涵蓋模型解析、推理參數、VAD 降級、快取語意、server backend 的各種失敗路徑、
幻覺過濾與異常輸入。詳見 [tests/README.md](tests/README.md)。

> 這套測試**不驗證 Hammerspoon runtime**。Lua 只做靜態檢查。
> 真機驗證清單見 [REAL_MAC_VALIDATION.md](REAL_MAC_VALIDATION.md)。

---

## 🗂️ 檔案結構

```
ptt-whisper/
├── ptt_whisper.lua              # Hammerspoon 主腳本
├── transcribe.sh                # Bash 轉錄腳本
├── config_example.json          # 設定檔範例
├── hallucinations_builtin.txt   # 共用幻覺過濾列表（需部署到 ~/.ptt-whisper/）
├── CHANGELOG.md                 # 版本更新記錄
├── REAL_MAC_VALIDATION.md       # 真機驗證清單（自動化測不到的部分）
├── LICENSE                      # MIT License
├── README.md
├── docs/
│   └── ARCHITECTURE.md          # 管線、ASR backend 契約、架構債
└── tests/                       # 迴歸測試（不需要真的 whisper.cpp）
    ├── run.sh
    ├── cases/                   # 分主題的測試檔
    ├── fakes/                   # fake whisper-cli / whisper-server
    ├── fixtures/                # 測試用 WAV
    └── lib/                     # 共用工具與靜態檢查
```

### 運行時產生的檔案（`~/.ptt-whisper/`）

```
~/.ptt-whisper/
├── config.json                  # 使用者設定
├── hallucinations_builtin.txt   # 共用幻覺列表（安裝時複製）
├── hallucinations.txt           # 自訂幻覺過濾列表
├── ptt_record.wav               # 暫存錄音檔（錄完即刪）
├── ptt_whisper_err.log          # 錯誤日誌（自動 rotation）
├── ptt_whisper_out.txt          # whisper.cpp 輸出暫存
├── diagnostics.txt              # 最近一次診斷報告
└── cache/                       # 轉錄快取（啟用時）
```

---

## 📖 使用方式

### 基本操作

1. **按住** Right Option（`⌥`）開始錄音（聽到 Tink 音效）
2. **說話**
3. **放開** 按鍵（聽到 Pop 音效）→ 自動轉錄並貼上到當前游標位置

### Menubar 功能

點擊 Menubar 上的 🎤 圖示：

- 📊 查看目前狀態、模式、Session 數
- 🔍 **Run Diagnostics** — 一鍵檢查所有依賴
- 📝 打開 Error Log / 設定檔 / 幻覺過濾列表
- 🔄 Reload Hammerspoon

### Hammerspoon Console API

```lua
PTTWhisper.runDiagnostics()           -- 執行健康檢查
PTTWhisper.listAudioDevices()         -- 列出音訊裝置
PTTWhisper.getLangModelForCurrentApp() -- 查看當前 App 的語言/模型
PTTWhisper.restartServer()            -- 重啟常駐 server
PTTWhisper.stopServer()               -- 停掉常駐 server（之後走 CLI）
```

---

## 🔧 進階設定

### 自訂幻覺過濾

whisper.cpp 在靜音或極短音訊上常會「幻覺」出訓練資料中的字幕句
（`Thank you.`、`謝謝觀看`、`ご視聴ありがとうございました` 之類）。
過濾分兩份列表，都是一行一句、支援 `#` 註解：

| 檔案 | 用途 |
|------|------|
| `~/.ptt-whisper/hallucinations_builtin.txt` | 共用內建列表，隨 repo 提供，升級時覆蓋 |
| `~/.ptt-whisper/hallucinations.txt` | 你的自訂列表，不會被升級覆蓋 |

```
# 我的自訂幻覺列表
感謝收看
歡迎訂閱
```

比對是兩層的：先原文精確比對，再 normalize（全形→半形、去除尾端標點、
轉小寫）後比對，因此不需要為標點與大小寫的變體重複列出。

### 術語注入（Initial Prompt）

whisper 對專有名詞、人名、中英混用詞的辨識率不高——「gRPC」會變成
「G R P C」、「Terraform」會變成「terra form」。initial prompt 是把這些詞
先餵給解碼器當上下文，是**單一改動裡準確度收益最大的一項**。

分兩層設定，兩者會**串接**（而非互相覆蓋）：

```json
{
  "initial_prompt": "Kubernetes, Terraform, gRPC, PostgreSQL",

  "lang_models": {
    "com.tinyspeck.slackmacgap": { "lang": "en", "prompt": "standup, sprint, PR, rollback" }
  }
}
```

在 Slack 裡實際送出的 prompt 是
`Kubernetes, Terraform, gRPC, PostgreSQL standup, sprint, PR, rollback`。
這樣全域術語表在每個 App 都有效，不必逐個 App 重複貼一遍。

**注意事項：**

- prompt 受 whisper 的 `n_text_ctx/2`（約 224 tokens）限制，過長反而會擠掉
  真正的解碼上下文。預設上限 800 bytes（約 266 個中文字 / 130 個英文單字），
  超過會從尾端截斷並在 log 留下 WARNING。
- 只放**詞彙**，不要放句子或指令 — whisper 的 prompt 不是 LLM 的 system prompt，
  寫「請使用繁體中文」不會有效果，語言請用 `lang_models` 指定。
- prompt 會進快取 key，改了 prompt 不會拿到舊結果。

### VAD（靜音偵測）

啟用後 whisper 只處理有語音的片段。兩個好處：短錄音推理更快，
以及**從源頭減少靜音幻覺**（幻覺黑名單是事後補救，VAD 是治本）。

需要 whisper.cpp build 支援 `--vad` 並下載 VAD model（見安裝步驟 3）。
`vad_enabled: "auto"`（預設）會在兩者都具備時自動啟用，缺任一項就靜靜跳過。

若 VAD 執行失敗（例如 model 檔損壞），transcribe.sh 會**先關掉 VAD 用同一個
主模型重試一次**，再考慮降級到 fallback model — 保住轉錄品質優先。

### 常駐 Server 模式

CLI 模式每次放開按鍵都要重新載入模型——small 量化版約 0.3~0.5 秒，這是
**每次錄音都要付的固定成本**，與你講多久無關。常駐 server 把模型留在記憶體，
省掉這一段。

```json
{ "server_mode": true, "server_port": 8178 }
```

需要 whisper.cpp 建置出 `build/bin/whisper-server`（標準 `cmake --build`
就會產生）。Hammerspoon 載入時會自動啟動它，reload 時自動收掉。

**預設是關閉的**，因為這會多一個長駐行程、常駐佔用約一份模型大小的 RAM
（q5_1 約 200MB）。要不要用這個交換，該由你決定，不該在升級後自動出現。

**任何情況出問題都會自動退回 CLI**，不會讓你錄的話消失：

| 情況 | 行為 |
|------|------|
| Server 還沒就緒 / 已掛掉 | 該次錄音走 CLI |
| HTTP 非 200、回應為空 | 退回 CLI 重跑 |
| Server 回 JSON（舊版不支援 `response_format=text`）| 退回 CLI，不會把 JSON 當結果貼出去 |
| 本次模型與 server 載入的不同（例如 `lang_models` 指定 `.en` 模型）| 直接走 CLI，不發請求 |
| 埠已被占用（上次殘留的行程）| 不啟動，整個 session 走 CLI 並提示 |

最後一項是刻意保守：占用該埠的行程載入的是哪個模型無從得知，直接沿用可能
拿到錯的轉錄結果，所以寧可退回 CLI，由你決定要清掉它還是換 `server_port`。

Server 的就緒判定用的是 `GET /health`：`200 + {"status":"ok"}` 才算就緒，
`503` 代表行程活著但模型還在載入。**行程活著不等於模型可用**，所以載入
期間的錄音會自動走 CLI。

**怎麼確認它真的在用？** Menubar 會顯示「Server：就緒」與「上次後端：⚡ server」，
Run Diagnostics 也有對應兩項。若 `server_mode` 開著但上次後端一直是
📼 CLI，診斷會標成警告並要你看 Error Log——這條路徑會靜默降級，沒有這個
顯示你不會發現它其實沒生效。

### 升級 whisper.cpp 後

若啟用了快取，升級 whisper.cpp 或替換模型後建議清除快取：

```bash
rm -rf ~/.ptt-whisper/cache/
```

---

## 🐛 疑難排解

| 問題 | 解法 |
|------|------|
| 聽到音效但沒有文字貼上 | Menubar → Run Diagnostics 檢查依賴 |
| `❌ 找不到 ffmpeg` | `brew install ffmpeg` |
| `❌ 麥克風權限被拒絕` | 系統設定 → 隱私權 → 麥克風 → 允許 Hammerspoon |
| 轉錄結果是亂碼或英文 | 在 `lang_models` 中為該 App 指定正確語言 |
| 貼上到 Slack/Teams 吃字 | 在 `slow_paste_apps` 中加大該 App 的延遲值 |
| 專有名詞老是聽錯 | 在 `initial_prompt` 加入該詞彙，見「術語注入」|
| VAD 沒生效 | Run Diagnostics 看「VAD」項；多半是沒下載 VAD model |
| Server 模式沒生效 | Menubar 看「上次後端」；為 CLI 就查 Error Log 的 `server:` 開頭訊息 |
| 提示「埠已被占用」 | `lsof -i :8178` 找出殘留行程砍掉，或改 `server_port` |
| 改了 prompt 但結果沒變 | 若啟用快取，確認不是命中舊快取（prompt 已納入 cache key，正常不會發生）|

---

## 📋 版本歷史

詳見 [CHANGELOG.md](CHANGELOG.md)

**當前版本：**
- `ptt_whisper.lua` v4.0.1
- `transcribe.sh` v2.10.1

---

## 📄 License

[MIT License](LICENSE) — 自由使用、修改、散布。

---

## 🙏 致謝

- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) — Georgi Gerganov
- [Hammerspoon](https://www.hammerspoon.org/) — macOS 自動化框架
- [FFmpeg](https://ffmpeg.org/) — 音訊錄製與轉換
