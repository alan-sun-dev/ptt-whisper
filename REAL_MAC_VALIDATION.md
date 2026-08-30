# 真機驗證清單（v4.0.x）

**狀態：A / B / C 三段已於 2026-08-30 在真實 Mac 上完成驗證。**

歷史脈絡：這份清單最初寫成時，開發環境沒有 Hammerspoon runtime 也沒有
whisper.cpp runtime，因此所有 Hammerspoon 相關行為都只能靠靜態檢查。
後來在同一台 Mac 上做了 fresh install（Hammerspoon 1.1.1 + 自行編譯的
whisper.cpp），把 A/B/C 全部跑完——過程中抓到五個自動化測試完全測不到的
問題（見 CHANGELOG v4.0.4 ~ v4.0.7）。

`./tests/run.sh` 驗證的是 `transcribe.sh` 的行為，以及從 `ptt_whisper.lua`
抽出的純函式（`classifyHealthResponse`、`maskIsSet`、
`restoreClipboardEntries`，由 lua 直譯器實際執行）。它使用 fake whisper-cli
與 fake whisper-server，**不是** runtime 驗證——整份 `ptt_whisper.lua` 的
載入與非同步行為仍然只有真機能證明。

測試中有兩處注入了 test double，production 走的是真正的 Hammerspoon API：

| 純函式 | 測試注入 | production |
|---|---|---|
| `classifyHealthResponse` | 自寫的嚴格 JSON parser | `hs.json.decode` |
| `restoreClipboardEntries` | 假的 writer（可回 false／throw） | `hs.pasteboard.writeDataForUTI` |

第二項的失敗路徑**只能**靠注入驗證：實測 `writeDataForUTI` 在這個
Hammerspoon 版本用空 UTI、非法 UTI、不存在的 pasteboard 名稱都回 `true`，
無法在真實 runtime 逼出 `false`。

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

- [x] 22. `/health` **ready** 契約實測：`HTTP/1.1 200 OK` ·
       `Content-Type: application/json` · `{"status":"ok"}` — 與 contract 相符。

       **`503 loading` 不需要、也無法在初次啟動時驗證。** 原始碼證實
       whisper.cpp 的 server 先 `whisper_init_from_file`（`server.cpp:726`）、
       再 `state.store(READY)`（735），HTTP listen 更晚，所以啟動期間
       `/health` 只會是 connection-refused。實測用 1.5GB 模型也抓不到 503。
       `loading` 分支是為 runtime 呼叫 `/load` 換模型的路徑而存在的
       defensive code，其分類邏輯已由自動化測試覆蓋。

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

- [ ] 30. `max_context` 的抗幻覺效果 A/B。**預設已於 v4.0.4 改為 `-1`
         （不帶 `-mc`，使用 whisper 預設）**，因為真機實測證實 `-mc 0` 會讓
         `initial_prompt` 完全失效——那個副作用不可接受。

         但「關掉 context 能減少重複／拖尾幻覺」這個**原始假設本身仍未被
         驗證**。若要重新評估，需涵蓋 2–3 秒 / 5–15 秒 / 20–30 秒，
         中文、英文、中英混用、技術術語、口語自我修正等語料，
         同時觀察術語命中率的損失。不阻塞 merge。

---

任何一項不如預期，把 `~/.ptt-whisper/ptt_whisper_err.log` 的相關片段
與 Diagnostics 報告一起給我。
