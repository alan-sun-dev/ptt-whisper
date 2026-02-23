# 🎤 PTT Whisper

> Push-to-Talk offline dictation for macOS using Hammerspoon + whisper.cpp

按住快捷鍵說話，放開自動轉錄並貼上文字。完全離線、零雲端依賴。

<!-- TODO: 加入 demo GIF -->
<!-- ![demo](docs/screenshots/demo.gif) -->

---

## ✨ 功能特色

- **Push-to-Talk 語音輸入** — 按住 Right Option 錄音，放開即轉錄貼上
- **完全離線** — 使用本地 whisper.cpp 推理，資料不離開你的電腦
- **Streaming 模式** ⚡ — 邊錄邊轉，體感延遲 < 0.5 秒（實驗性）
- **多語言 / 多 App 切換** — 依前景 App 自動切換語言與模型
- **幻覺過濾** — 內建 + 自訂列表，過濾 whisper 常見幻覺輸出
- **智慧剪貼簿** — 貼上後自動還原原始剪貼簿內容（支援多 UTI 型別）
- **Fallback Model** — 主模型逾時或失敗時，自動用較小模型重試
- **轉錄快取** — 相同音訊 + 模型 + 語言 = 直接回傳快取結果
- **自動 Resample** — 非 16kHz 音訊自動轉換，免手動處理
- **漸進式降級** — Streaming 連續失敗 N 次才永久切換傳統模式
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
| Model 檔案 | 至少一個 ggml model（建議 `ggml-small.bin`）|
| coreutils | `brew install coreutils`（提供 `gtimeout`）|

---

## 🚀 安裝

### 1. 安裝依賴

```bash
# Hammerspoon（若尚未安裝）
brew install --cask hammerspoon

# ffmpeg + coreutils
brew install ffmpeg coreutils cmake

# whisper.cpp
git clone https://github.com/ggml-org/whisper.cpp.git ~/whisper.cpp
cd ~/whisper.cpp

# 建置（基本版，傳統模式用）
cmake -B build
cmake --build build -j --config Release

# 若需要 Streaming 模式，改用以下（需要 SDL2）：
# brew install sdl2
# cmake -B build -DWHISPER_SDL2=ON
# cmake --build build -j --config Release

# 下載模型（擇一）
# FP16 完整版（推薦，多語言）
bash ./models/download-ggml-model.sh small

# 量化版（二擇一）：
# 方案 A：直接下載 Q5_1（推薦，最簡單）
bash ./models/download-ggml-model.sh small-q5_1

# 方案 B：自行量化為 Q5_0（與程式碼預設檔名一致）
./build/bin/quantize models/ggml-small.bin models/ggml-small-q5_0.bin q5_0

# 可選：tiny 做 fallback
bash ./models/download-ggml-model.sh tiny
```
---

建議兩個都裝，各有用途：
bashcd ~/whisper.cpp

# 量化版（日常使用）
bash ./models/download-ggml-model.sh small-q5_1

# FP16 完整版（備用）
bash ./models/download-ggml-model.sh small
理由很簡單：
Q5_1 量化版FP16 完整版檔案大小~182 MB~466 MB記憶體佔用~200 MB~500 MB推理速度2-3x 更快1x 基準準確率幾乎無損基準適合場景PTT 日常使用fallback / 比對用
PTT 的錄音只有 2-15 秒，量化版的微小精度差異根本感知不到，但速度差很明顯。

不過有一個問題要處理：你的程式碼預設找的是 ggml-small-q5_0.bin，但下載腳本提供的是 q5_1。有兩個選法：
方案 A（改程式碼，推薦）：把程式碼中的 q5_0 改為 q5_1，這樣直接下載就能用，不用手動量化。
方案 B（自己量化）：先下載 FP16，再用 build 出來的工具自行產生 q5_0：

方案 B（自己量化）：先下載 FP16，再用 build 出來的工具自行產生 q5_0：
bash./build/bin/quantize models/ggml-small.bin models/ggml-small-q5_0.bin q5_0

**另外需要考慮的程式碼層面影響：**

如果選方案 A（下載 `small-q5_1`），則 `ptt_whisper.lua` 和 `transcribe.sh` 中的 fallback 檔名需要同步修改：
```
ggml-small-q5_0.bin → ggml-small-q5_1.bin

### 2. 安裝 PTT Whisper

```bash
# Clone repo
git clone https://github.com/alan-sun-dev/ptt-whisper.git ~/ptt-whisper

# 部署 transcribe.sh
chmod +x ~/ptt-whisper/transcribe.sh

# 在 Hammerspoon 載入 Lua 腳本
# 編輯 ~/.hammerspoon/init.lua，加入：
dofile(os.getenv("HOME") .. "/ptt-whisper/ptt_whisper.lua")
```

### 3. 授予權限

在 **系統設定 → 隱私權與安全性** 中，允許 Hammerspoon 取用：

- ✅ 麥克風
- ✅ 輔助使用（Accessibility）

### 4. Reload Hammerspoon

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

  "streaming_mode": false,
  "streaming_step_ms": 500,
  "streaming_length_ms": 5000,

  "cache_enabled": false,
  "fallback_model": "ggml-tiny.bin",

  "lang_models": {
    "com.tinyspeck.slackmacgap":   { "lang": "en", "model": "ggml-small.en.bin" },
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
| `streaming_mode` | bool | `false` | 啟用 Streaming 即時轉錄（實驗性）|
| `streaming_step_ms` | number | `500` | Streaming 步長，有效 100~10000 |
| `streaming_length_ms` | number | `5000` | Streaming 音訊窗口長度，有效 1000~30000 |
| `cache_enabled` | bool | `false` | 啟用轉錄結果快取 |
| `fallback_model` | string | `""` | Fallback 模型檔名或完整路徑 |
| `lang_models` | object | `{}` | 依 App Bundle ID 切換語言/模型 |

### 環境變數

| 變數 | 預設值 | 說明 |
|------|--------|------|
| `WHISPER_DIR` | `~/whisper.cpp` | whisper.cpp 安裝目錄 |
| `WHISPER_MODEL` | `$WHISPER_DIR/models/ggml-small.bin` | 預設模型路徑 |
| `WHISPER_LANG` | `auto` | 預設語言（auto = 自動偵測）|
| `WHISPER_TIMEOUT` | `60` | 轉錄逾時秒數 |
| `WHISPER_AUTO_RESAMPLE` | `true` | 自動 resample 非 16kHz 音訊 |

---

## 🗂️ 檔案結構

```
ptt-whisper/
├── ptt_whisper.lua          # Hammerspoon 主腳本
├── transcribe.sh            # Bash 轉錄腳本
├── config_example.json      # 設定檔範例
├── CHANGELOG.md             # 版本更新記錄
├── LICENSE                  # MIT License
├── README.md
└── docs/
    └── screenshots/         # 截圖與 demo GIF
        ├── menubar.png
        ├── diagnostics.png
        └── demo.gif
```

### 運行時產生的檔案（`~/.ptt-whisper/`）

```
~/.ptt-whisper/
├── config.json              # 使用者設定
├── hallucinations.txt       # 自訂幻覺過濾列表
├── ptt_record.wav           # 暫存錄音檔（錄完即刪）
├── ptt_whisper_err.log      # 錯誤日誌（自動 rotation）
├── ptt_whisper_out.txt      # whisper.cpp 輸出暫存
├── diagnostics.txt          # 最近一次診斷報告
└── cache/                   # 轉錄快取（啟用時）
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
```

---

## 🔧 進階設定

### 自訂幻覺過濾

編輯 `~/.ptt-whisper/hallucinations.txt`，一行一句：

```
# 我的自訂幻覺列表
感謝收看
歡迎訂閱
```

### Streaming 模式

> ⚠️ 實驗性功能，需要 whisper.cpp build 支援 `--stream` 旗標

在 `config.json` 中設定 `"streaming_mode": true`。Streaming 模式下 whisper.cpp 直接從麥克風擷取並即時轉錄，體感延遲從 2-3 秒降至 < 0.5 秒。

限制：只能使用系統預設麥克風、不支援快取、大型模型延遲較高。

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
| Streaming 模式不工作 | 確認 whisper.cpp build 含 SDL/PortAudio，執行 `whisper-cli --help` 確認有 `--stream` |
| 轉錄結果是亂碼或英文 | 在 `lang_models` 中為該 App 指定正確語言 |
| 貼上到 Slack/Teams 吃字 | 在 `slow_paste_apps` 中加大該 App 的延遲值 |

---

## 📋 版本歷史

詳見 [CHANGELOG.md](CHANGELOG.md)

**當前版本：**
- `ptt_whisper.lua` v3.5.1
- `transcribe.sh` v2.7.1

---

## 📄 License

[MIT License](LICENSE) — 自由使用、修改、散布。

---

## 🙏 致謝

- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) — Georgi Gerganov
- [Hammerspoon](https://www.hammerspoon.org/) — macOS 自動化框架
- [FFmpeg](https://ffmpeg.org/) — 音訊錄製與轉換
