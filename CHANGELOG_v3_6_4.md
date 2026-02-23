# PTT Whisper v3.6.4 / v2.8.4 — 第四輪 Code Review 修正 Changelog

## 修正總覽

| 編號 | 改動 | 影響範圍 | 預期效果 |
|------|------|---------|---------|
| CR12 | loadExternalConfig 結構化回傳 | Lua config 載入 | Diagnostics 能區分「無檔」/「空檔」/「JSON 壞掉」 |
| CR13 | streamingFailCount 漸進式衰減 | Lua streaming | 不過度累積歷史失敗，也不被單次成功繞過 |
| CR14 | Diagnostics 區分 Q5_0 / FP16 | Lua diagnostics | 使用者一眼辨識量化版本 |
| CR15 | Diagnostics 濾波器鏈 dry-run | Lua diagnostics | 語法錯誤在診斷時即可發現 |
| CR12-bash | LRU stat 跨平台 fallback | Bash 快取管理 | macOS + Linux 皆可正確清理快取 |
| CR13-bash | 幻覺比對批次 normalize | Bash 幻覺過濾 | fork 從 O(N) 降為 O(1)（50 行：~100 → ~7 forks） |

---

## CR12 — loadExternalConfig 結構化回傳

### 問題

`loadExternalConfig()` 在三種情況下都回傳 `nil`：
1. config.json 不存在（正常，首次啟動）
2. config.json 存在但為空
3. config.json JSON 解析失敗

Diagnostics 無法區分這三種情況，統一顯示「無設定檔或未載入」。

### 修正

每個 early return 路徑都回傳結構化結果：

```lua
-- 不存在 → nil（正常）
if not f then return nil end

-- 空檔 → { warnings = {"config.json 為空"} }
if not content or content == "" then
  return { warnings = {"config.json 為空"} }
end

-- JSON 壞掉 → { warnings = {"config.json JSON 解析失敗，已忽略"} }
if not decodeOk then
  return { warnings = {"config.json JSON 解析失敗，已忽略"} }
end

-- 正常 → { warnings = [...] }（可能有欄位級警告）
return validateConfig(config)
```

Diagnostics 顯示範例：
- `✅ config.json 驗證 — 無設定檔（正常，使用預設值）`
- `✅ config.json 驗證 — 通過（無警告）`
- `⚠️ config.json 驗證 — 1 項警告：config.json JSON 解析失敗，已忽略`

---

## CR13 — streamingFailCount 漸進式衰減

### 問題

v3.6.3 的 `streamingFailCount` 在成功時**完全不衰減**（除了 reload 歸零）。這導致跨越數小時的偶發性失敗會永久累積：

```
早上：失敗 1 次 → 正常使用一整天 → 晚上：失敗 2 次 → 觸發降級
```

### 修正

在 `stopStreaming()` 中，當 streaming 成功產出文字時，將 `streamingFailCount` 遞減 1（floor 0）：

```lua
-- 成功時遞減（非歸零），漸進式衰減
if streamingFailCount > 0 then
  streamingFailCount = streamingFailCount - 1
end
```

### 行為比較

| 場景 | v3.6.2（歸零） | v3.6.3（不衰減） | v3.6.4（遞減 1） |
|------|---------------|-----------------|-----------------|
| fail 2 → success 1 → fail 1 | count=1 ❌ | count=3 ⚠️ | count=2 ✅ |
| fail 2 → success 0 → fail 1 | count=1 ❌ | count=3 ✅ | count=3 ✅ |
| fail 1 → success 5 → fail 2 | count=0 ❌ | count=3 ⚠️ | count=2 ✅ |

✅ = 合理行為，❌ = 保護被繞過，⚠️ = 過度敏感

---

## CR14 — Diagnostics 區分 Q5_0 / FP16

### 改動

`runDiagnostics()` 的 Model 檔案檢查新增模型類型標籤：

```
✅ Model 檔案 — ~/whisper.cpp/models/ggml-small-q5_0.bin (181MB) [Q5_0]
✅ Model 檔案 — ~/whisper.cpp/models/ggml-small.bin (466MB) [FP16]
```

支援的標籤：`Q5_0`、`Q5_1`、`Q8_0`、`FP16`（fallback）。

---

## CR15 — Diagnostics 濾波器鏈 dry-run 驗證

### 改動

新增第 14 項診斷檢查，使用 FFmpeg 的 `lavfi` 虛擬音源做快速 dry-run：

```lua
ffmpeg -f lavfi -i "anullsrc=r=16000:cl=mono" \
  -af "highpass=f=200,lowpass=f=5000,loudnorm=I=-16:TP=-1.5" \
  -t 0.01 -f null -
```

- 成功：`✅ 濾波器鏈 — 語法正確 — highpass=f=200,lowpass=f=5000,...`
- 失敗：`⚠️ 濾波器鏈 — Error: ...`（擷取第一個 Error 行）
- 停用：`✅ 濾波器鏈 — 已停用`

這能在 `Run Diagnostics` 時就發現語法錯誤，不必等到實際錄音時才知道。

---

## CR12-bash — LRU stat 跨平台 fallback

### 問題

LRU 快取清理使用 `stat -f '%m %N'`，這是 macOS/BSD 語法。Linux 上會靜默失敗（`2>/dev/null`），導致快取永遠不被清理、無限增長。

### 修正

加入平台偵測 + fallback：

```bash
if stat -f '%m %N' /dev/null &>/dev/null; then
  # macOS / BSD
  find ... -exec stat -f '%m %N' {} + ...
else
  # Linux / GNU
  find ... -exec stat -c '%Y %n' {} + ...
fi
```

偵測方式：用 `stat -f '%m %N' /dev/null` 做探測，macOS 成功、Linux 失敗，自然走入正確分支。

---

## CR13-bash — 幻覺比對批次 normalize

### 問題

`filter_by_hallucination_file()` 對幻覺列表每行都呼叫 `normalize_text()`，每次呼叫 fork 2 次（sed + tr）。50 行列表 = 100 forks。

### 修正

重構為批次處理架構：

```
舊版（逐行）：                    新版（批次）：
┌─────────────────────┐          ┌─────────────────────┐
│ for each line:      │          │ 1. sed 清理列表 (1 fork)  │
│   normalize (2 fork)│ N×2     │ 2. grep exact  (1 fork)  │
│   compare           │          │ 3. normalize text (2 forks) │
│ done                │          │ 4. sed+tr normalize列表 (2 forks) │
│                     │          │ 5. grep normalized (1 fork) │
│ Total: 2N+2 forks   │          │ Total: 7 forks (constant) │
└─────────────────────┘          └─────────────────────┘
```

50 行列表：102 → 7 forks（**-93%**）。

### 正確性保證

批次 normalize 的 sed 規則與 `normalize_text()` 函式**完全一致**（同一份規則複製）。`grep -Fxq` 做精確全行比對，語義與逐行 `[[ "$a" == "$b" ]]` 相同。

暫存檔在函式內建立並清理，EXIT trap 也包含 glob 清理作為最後防線。

---

## 向後相容性

所有修正均向後相容：

- loadExternalConfig 回傳值變化只影響 diagnostics 顯示文字
- streamingFailCount 衰減策略對正常使用無感
- Diagnostics 新增項目不影響既有項目
- stat fallback 不改變 macOS 上的行為
- 幻覺比對結果與舊版完全一致（僅效能改善）

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
#   - 版本：應顯示 v3.6.4
#   - Model 檔案：應顯示 [Q5_0] 或 [FP16] 標籤
#   - 濾波器鏈：應顯示「語法正確」
#   - config.json 驗證：應顯示具體狀態
```
