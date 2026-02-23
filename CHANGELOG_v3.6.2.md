# PTT Whisper v3.6.2 / v2.8.2 — 錄音品質 + 推理效能優化 Changelog

## 修正總覽

| 編號 | 改動 | 影響範圍 | 預期效果 |
|------|------|---------|---------|
| OPT1 | FFmpeg 錄音加入聲學濾波器鏈 | Lua 錄音段 | 嘈雜環境 WER 顯著降低 |
| OPT2 | 預設 model 改為 Q5_0 量化版 | Lua + Bash 雙端 | 推理速度 2~3x、RAM -50% |

---

## OPT1 — 聲學濾波器鏈

### 改了什麼

錄音時的 ffmpeg 呼叫從：
```
ffmpeg -y -f avfoundation -i :0 -ac 1 -ar 16000 output.wav
```
改為：
```
ffmpeg -y -f avfoundation -i :0 -af "highpass=f=200,lowpass=f=3000,loudnorm=I=-16:TP=-1.5" -ac 1 -ar 16000 output.wav
```

### 三段濾波器的作用

| 濾波器 | 作用 | 實際效果 |
|--------|------|---------|
| `highpass=f=200` | 切除 200Hz 以下低頻 | 過濾冷氣聲、馬路隆隆聲、風聲 |
| `lowpass=f=3000` | 切除 3kHz 以上高頻 | 過濾電路嘶聲、風扇雜音 |
| `loudnorm=I=-16:TP=-1.5` | EBU R128 感知響度正規化 | 防止忽大忽小、防爆音 |

### 可設定性

config.json 新增 `audio_filter_chain` 欄位：

```json
{
  "audio_filter_chain": "highpass=f=200,lowpass=f=3000,loudnorm=I=-16:TP=-1.5"
}
```

- 自定義濾波器：直接修改字串（任何合法的 FFmpeg `-af` 參數）
- 停用濾波器：設為空字串 `""`
- 不設定：使用預設值

Menubar 新增「濾波器：ON/OFF」狀態顯示。

### 不影響 streaming mode

Streaming 模式由 whisper.cpp 自行擷取麥克風（PortAudio/SDL），不經過 ffmpeg 錄音，因此濾波器鏈只對傳統模式生效。

---

## OPT2 — Q5_0 量化模型

### 改了什麼

Lua 端 `resolveModelPath()` 和 Bash 端 MODEL 預設值的優先順序改為：

```
1. WHISPER_MODEL 環境變數（最高優先）
2. ggml-small-q5_0.bin（若存在）  ← 新增
3. ggml-small.bin（fallback）
```

### 為什麼 Q5_0

| 指標 | FP16 (ggml-small.bin) | Q5_0 (ggml-small-q5_0.bin) |
|------|----------------------|---------------------------|
| 檔案大小 | ~466 MB | ~~181 MB (-61%) |
| 記憶體佔用 | ~500 MB | ~200 MB (-60%) |
| 推理速度 | 1x | 2~3x |
| 準確率 | 基準 | 幾乎無損（<0.5% WER 差異） |

Q5_0 將關鍵張量壓縮至 L3 cache 內，把 memory-bound 運算轉為 compute-bound，CPU 利用率大幅提升。

### 如何取得 Q5_0 模型

```bash
cd ~/whisper.cpp

# 方法 1：直接下載（推薦）
./models/download-ggml-model.sh small-q5_0

# 方法 2：用 quantize 工具自行量化
./quantize models/ggml-small.bin models/ggml-small-q5_0.bin q5_0
```

### 向後相容性

- Q5_0 不存在 → 自動 fallback 到 FP16，行為與 v3.6.1 完全一致
- `WHISPER_MODEL` 環境變數仍然是最高優先，不受影響
- config.json 的 `lang_models[].model` 覆寫仍然生效

---

## Known Issues

### whisper.cpp `-nt` (no timestamps) 可能丟字

**狀態**：已知，暫不修正

whisper.cpp issue [#2186](https://github.com/ggerganov/whisper.cpp/issues/2186) 報告 `-nt` 參數在長音訊（>30s）上可能導致部分語句被丟棄。原因是 `-nt` 改變了解碼器的時間上下文處理邏輯。

**影響評估**：PTT Whisper 的典型錄音時長為 2~15 秒，觸發此 bug 的機率極低。目前保留 `-nt` 以維持輸出的簡潔性。

**未來方案**：若出現丟字回報，可改用 `-otxt`（帶 timestamp 的純文字輸出）+ sed strip timestamp。

---

## Roadmap

### FFmpeg 8.0 `af_whisper` 原生整合

**狀態**：追蹤中，暫不採用

FFmpeg 8.0 "Huffman" (2025-08-22) 新增了 `af_whisper` 濾鏡，理論上可以做到：

```bash
ffmpeg -f avfoundation -i :0 -af \
  "highpass=f=200,lowpass=f=3000,loudnorm=I=-16,aresample=16000,whisper=model=ggml-small-q5_0.bin" \
  -f null -
```

單一命令完成錄音 → 濾波 → 推理，砍掉整個 transcribe.sh。

**暫不採用的原因**：
1. Homebrew FFmpeg formula 尚未包含 `--enable-whisper` build option
2. `af_whisper` 不支援 streaming mode
3. 穩定性未經社群充分驗證（8.0.1 為首個 patch release）

**評估時機**：Homebrew formula 支援 或 FFmpeg 8.1 發佈時重新評估。

---

## 部署步驟

```bash
# 1. （推薦）下載 Q5_0 模型
cd ~/whisper.cpp
./models/download-ggml-model.sh small-q5_0

# 2. 複製檔案
cp ptt_whisper.lua ~/ptt-whisper/
cp transcribe.sh ~/ptt-whisper/
chmod +x ~/ptt-whisper/transcribe.sh

# 3. Reload Hammerspoon

# 4. 驗證
# Menubar → Run Diagnostics
# 確認：
#   - Model 檔案：應顯示 ggml-small-q5_0.bin
#   - Menubar：應顯示「濾波器：ON」
```

### 如果遇到問題

- **錄音失敗（ffmpeg exit code 非 0）**：可能是濾波器鏈語法有誤。在 config.json 設 `"audio_filter_chain": ""` 停用濾波器，確認是否恢復
- **推理結果異常**：設 `WHISPER_MODEL=~/whisper.cpp/models/ggml-small.bin` 強制回退到 FP16
