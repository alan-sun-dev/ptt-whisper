# 真機驗證清單（v4.0.x）

開發環境**沒有** Hammerspoon runtime，也**沒有** whisper.cpp runtime。

`./tests/run.sh` 驗證的是 `transcribe.sh` 的行為，以及 Lua 的**純函式**
（`classifyHealthResponse` 由 lua 直譯器實際執行，43 條斷言）。
它使用 fake whisper-cli 與 fake whisper-server，**不是** runtime 驗證。

整份 `ptt_whisper.lua` 只做過區塊平衡與定義順序的靜態檢查——那不等於
「能在 Hammerspoon 裡載入」，更不等於「非同步行為正確」。

另外，`classifyHealthResponse` 在測試中注入的是一份嚴格的 JSON decoder
test double；production 走的是 `hs.json.decode`。**這個替換本身沒有被
自動化驗證過**，所以第 13 項同時也是在驗證 `hs.json.decode` 的行為
（尤其是它對非法 JSON 會 raise error、被 `pcall` 接住這件事）。

以下必須在真實 Mac 上人工完成。合併 PR 前請逐項確認。

## ✅ A / B / C 已於 2026-08-30 在真機完成驗證

環境：macOS 26.6.2 arm64 · Hammerspoon 1.1.1 · whisper.cpp `c4ac001` ·
`ggml-small-q5_1` + `ggml-silero-v5.1.2` · PTT Whisper v4.0.6

### A. 載入與基本功能

- [x] 1. `hs.reload()` — `ptt_whisper.lua LOADED OK`，13 個 API 就位，無錯誤
- [x] 2. Run Diagnostics — **15 PASS / 2 WARNING / 0 FAIL**
       （WARNING：`gtimeout` 未安裝〔已補〕、config 含已移除的 streaming 欄位
       〔向後相容測試，行為正確〕）
- [x] 3. 按住 Right Option → 文字正確貼上
       ← 需要 **v4.0.5** 的修正才成立。`hs.hotkey` 對單獨修飾鍵永遠不會觸發
- [x] 4. 貼上後原剪貼簿還原
       ← 需要 **v4.0.6** 的修正才成立。**必須用有格式的內容測**：
       純文字剪貼簿即使在有 bug 的版本也會通過，會得到假的通過
- [x] 5. Secure Input 偵測 —— `pasteText: aborted due to Secure Input`，
       轉錄完成但正確拒絕貼上

### B. CLI backend

- [x] 6. `server_mode: false` 正常轉錄
- [x] 7. Diagnostics「whisper.cpp 旗標」— 全部支援
       （`--threads --max-context --prompt --vad`）
- [x] 8. `initial_prompt` 有效 —— `VLLM and Quen` → `vLLM and Qwen`
- [x] 9. per-app prompt 串接正確
- [x] 10. VAD 啟用 —— `whisper_full: VAD is enabled, processing speech segments only`
- [x] 11. `cache_enabled` 真的產生快取檔 ← 這條路徑在 v3.7.0 之前從未生效過

### C. Server backend

- [x] 12–14. `server_mode: true` → 啟動 → 就緒，錄音走 server
- [x] 15. 「上次轉錄後端」顯示 `⚡ server`
- [x] 16. `kill` whisper-server → 自動退回 CLI，文字仍正確
- [x] 17–18. **連續重啟 ×5** → generation 1→11、恰好 1 個 listener、1 個行程
- [x] 19. **埠被占用**（`python3 -m http.server 8178`）→ 偵測到 `HTTP 404`
       判為占用、拒絕啟動、退回 CLI
- [x] 20. **`hs.reload()` ×4** → 每次換新 pid、舊的被收掉、無 orphan
- [x] 21. 快取 + server → `📦 快取（server 產生）`

### 已釐清的 upstream 契約

- [x] 22. `/health` ready 實測：`HTTP/1.1 200 OK` ·
       `Content-Type: application/json` · `{"status":"ok"}`
       **與 contract 相符**
- [x] 23. `/inference` 實測接受 `response_format` / `no_timestamps` /
       `prompt` / `max_context`（`max_context=abc` → HTTP 500，
       但 `transcribe.sh` 已先驗證不會送出）

---

## D. 語音品質

- [ ] 24. 中文
- [ ] 25. 英文
- [ ] 26. 中英混用（技術術語）
- [ ] 27. 純靜音 → 不應貼出任何幻覺文字
- [ ] 28. 背景噪音環境
- [ ] 29. 2 秒 / 10 秒 / 30 秒三種長度

## E. 待你決定的實驗（不阻塞 merge）

- [ ] 30. `max_context: 0` vs whisper 預設的 A/B。目前預設 `0` 是理論推導，
         **尚未經真實語料驗證**（見 README「關於 max_context: 0」）。
         建議語料：2–3s / 5–15s / 20–30s × 中文 / 英文 / 中英混用 /
         技術術語 / 口語自我修正。觀察 CER·WER、術語命中率、重複、
         拖尾幻覺、延遲

---

任何一項不如預期，把 `~/.ptt-whisper/ptt_whisper_err.log` 的相關片段
與 Diagnostics 報告一起給我。
