# PTT Whisper v3.6.3 / v2.8.3 — 第三輪 Code Review 修正 Changelog

## 修正總覽

| 編號 | 改動 | 影響範圍 | 預期效果 |
|------|------|---------|---------|
| CR7 | 工作目錄初始化順序修正 | Lua 啟動流程 | 首次啟動時 config.json 能正確讀取 |
| CR8 | lowpass 3kHz → 5kHz | Lua 錄音段 | 保留齒擦音頻帶，英文辨識率提升 |
| CR9 | streamingFailCount 重置策略修正 | Lua streaming | 降級保護不再被單次成功繞過 |
| CR10 | Diagnostics 納入 config 驗證警告 | Lua diagnostics | 設定錯誤一次可見 |
| CR11 | FFmpeg exitCode 255 加註解 | Lua 錄音段 | 提升可維護性 |
| CR7-bash | normalize_text() 效能優化 | Bash 幻覺過濾 | fork 次數 7→2，大列表場景加速 |
| CR8-bash | 文字清理抽為函式 | Bash 文字處理 | 提升可讀性與可維護性 |
| CR9-bash | LRU 快取清理改用 find | Bash 快取管理 | 消除 ls glob 邊界問題 |
| CR10-bash | LC_ALL=C 行為加註解 | Bash locale | 文件化 trade-off 決策 |

---

## CR7 — 工作目錄初始化順序

### 問題

`loadExternalConfig()` 在 `hs.fs.mkdir(PTT_DIR)` **之前**被呼叫。若 `~/.ptt-whisper/` 不存在（首次啟動），config.json 無法讀取。

### 修正

```lua
-- 修正前（v3.6.2）：
loadExternalConfig()          -- ← PTT_DIR 可能不存在
hs.fs.mkdir(PTT_DIR)

-- 修正後（v3.6.3）：
hs.fs.mkdir(PTT_DIR)          -- ← 先確保目錄存在
hs.task.new("/bin/chmod", nil, {"700", PTT_DIR}):start()
lastConfigValidation = loadExternalConfig()
```

---

## CR8 — lowpass 3kHz → 5kHz

### 問題

lowpass 3kHz 切除了齒擦音（sibilant）頻帶（4–8 kHz），導致 /s/, /ʃ/, /f/ 等音素模糊化，對英文語音辨識有負面影響。中文因齒擦音頻率相對集中在較低範圍，影響較小。

### 修正

```lua
-- 修正前：
local AUDIO_FILTER_CHAIN = "highpass=f=200,lowpass=f=3000,loudnorm=I=-16:TP=-1.5"

-- 修正後：
local AUDIO_FILTER_CHAIN = "highpass=f=200,lowpass=f=5000,loudnorm=I=-16:TP=-1.5"
```

### 頻率覆蓋比較

| 頻帶 | 用途 | 3kHz cutoff | 5kHz cutoff |
|------|------|-------------|-------------|
| 200–3000 Hz | 基頻 + 共振峰 | ✅ 保留 | ✅ 保留 |
| 3000–5000 Hz | 齒擦音、清晰度 | ❌ 切除 | ✅ 保留 |
| 5000–8000 Hz | 高頻齒擦、空氣感 | ❌ 切除 | ❌ 切除 |
| >8000 Hz | 電路雜音、嘶聲 | ❌ 切除 | ❌ 切除 |

5kHz 在「過濾雜音」與「保留語音清晰度」之間取得更好的平衡。

---

## CR9 — streamingFailCount 重置策略

### 問題

`streamingFailCount` 在每次 streaming 成功啟動時被重置為 0。這表示即使連續失敗 2 次（threshold=3），只要中間有 1 次成功，計數器就會歸零，導致降級保護形同虛設。

### 修正

移除 `startStreaming()` 中的 `streamingFailCount = 0`，改為只在 `cleanup()`（即 Hammerspoon reload）時重置。

**行為變化：**
- 修正前：失敗 2 → 成功 1 → 失敗 1 → 計數器 = 1（永遠不會觸發降級）
- 修正後：失敗 2 → 成功 1 → 失敗 1 → 計數器 = 3（觸發降級到傳統模式）

使用者可透過 Reload Hammerspoon 恢復 streaming 模式。

---

## CR10 — Diagnostics 納入 Config 驗證

### 改動

`validateConfig()` 的回傳值（warnings 列表）現在被儲存，並在 `runDiagnostics()` 中新增第 13 項檢查：

```
✅ config.json 驗證 — 通過（無警告）
⚠️ config.json 驗證 — 2 項警告：unknown config key 'typo_key' (ignored); streaming_step_ms out of range (100~10000 ms)
```

---

## CR11 — FFmpeg exitCode 255 註解

### 改動

在 `recordTask` 的 callback 中加入註解，說明 macOS 上 FFmpeg 收到 SIGINT 時回傳 255 是預期行為（正常終止錄音），不應被視為錯誤。

---

## Bash — normalize_text() 效能優化

### 問題

原始實作每次呼叫 spawn 7 個子程序（6× sed + 1× tr）。在 `filter_by_hallucination_file()` 中對幻覺列表每行都呼叫一次，50 行列表 = 350 次 fork。

### 修正

合併所有 sed 規則為單一 pipeline：

```bash
# 修正前（7 forks）：
text=$(echo "$text" | sed ...)    # 1
text=$(echo "$text" | sed ...)    # 2
text=$(echo "$text" | sed ...)    # 3
text=$(echo "$text" | sed ...)    # 4
text=$(echo "$text" | sed ...)    # 5
text=$(echo "$text" | sed ...)    # 6
text=$(echo "$text" | tr ...)     # 7

# 修正後（2 forks）：
echo "$text" | sed -E \
  -e '...' -e '...' -e '...' \   # 1
| tr '[:upper:]' '[:lower:]'     # 2
```

50 行列表：350 forks → 100 forks（-71%）。

---

## Bash — LRU 快取清理改用 find

### 問題

`ls -1t "$CACHE_DIR"/*.txt` 在快取目錄為空時，glob 不展開會導致 `ls` 嘗試列出名為 `*.txt` 的檔案。雖有 `|| true` 保護不會報錯，但行為不夠明確。

### 修正

```bash
# 修正前：
cached_files=$(ls -1t "$CACHE_DIR"/*.txt 2>/dev/null || true)

# 修正後（macOS 相容）：
find "$CACHE_DIR" -maxdepth 1 -name '*.txt' -type f \
  -exec stat -f '%m %N' {} + 2>/dev/null \
  | sort -rn | tail -n +"$((CACHE_MAX + 1))" | cut -d' ' -f2- \
  | while IFS= read -r old; do rm -f "$old"; done
```

---

## 向後相容性

所有修正均向後相容：

- lowpass 5kHz 是更寬鬆的設定，不會比 3kHz 更差
- config.json 不需要修改
- streamingFailCount 行為變化只影響極端邊界情況
- 新增的 diagnostics 項目不影響既有項目

---

## 部署步驟

```bash
# 1. 複製檔案
cp ptt_whisper.lua ~/ptt-whisper/
cp transcribe.sh ~/ptt-whisper/
chmod +x ~/ptt-whisper/transcribe.sh

# 2. Reload Hammerspoon

# 3. 驗證
# Menubar → Run Diagnostics
# 確認：
#   - 版本：應顯示 v3.6.3
#   - config.json 驗證：應顯示「通過」或列出具體警告
#   - 濾波器：ON
```

---

## 沿用自 v3.6.2 — OPT1/OPT2 參考

以下為 v3.6.2 引入的兩項優化，v3.6.3 完整保留：

### OPT1 — 聲學濾波器鏈

錄音時的 ffmpeg 加入 `-af` 濾波器鏈：

| 濾波器 | 作用 | 實際效果 |
|--------|------|---------|
| `highpass=f=200` | 切除 200Hz 以下低頻 | 過濾冷氣聲、馬路隆隆聲、風聲 |
| `lowpass=f=5000` | 切除 5kHz 以上高頻 | 過濾電路嘶聲、風扇雜音（保留齒擦音） |
| `loudnorm=I=-16:TP=-1.5` | EBU R128 感知響度正規化 | 防止忽大忽小、防爆音 |

### OPT2 — Q5_0 量化模型

| 指標 | FP16 (ggml-small.bin) | Q5_0 (ggml-small-q5_0.bin) |
|------|----------------------|---------------------------|
| 檔案大小 | ~466 MB | ~181 MB (-61%) |
| 記憶體佔用 | ~500 MB | ~200 MB (-60%) |
| 推理速度 | 1x | 2~3x |
| 準確率 | 基準 | 幾乎無損（<0.5% WER 差異） |

---

## Known Issues（沿用自 v3.6.2）

### whisper.cpp `-nt` (no timestamps) 可能丟字

**狀態**：已知，暫不修正

whisper.cpp issue [#2186](https://github.com/ggerganov/whisper.cpp/issues/2186) 報告 `-nt` 參數在長音訊（>30s）上可能導致部分語句被丟棄。PTT Whisper 的典型錄音時長為 2~15 秒，觸發此 bug 的機率極低。

### FFmpeg 8.0 `af_whisper` 原生整合

**狀態**：追蹤中，暫不採用

Homebrew formula 支援 `--enable-whisper` 或 FFmpeg 8.1 發佈時重新評估。
