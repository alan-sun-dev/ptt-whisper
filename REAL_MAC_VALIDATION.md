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

## A. 載入與基本功能

- [ ] 1. `hs.reload()` — Hammerspoon Console 無錯誤，出現「PTT Whisper v4.0.6 已載入」
- [ ] 2. Menubar → **Run Diagnostics** — 18 個項目全部檢視，無非預期的 ❌
- [ ] 3. 按住 Right Option 講話、放開 → 文字正確貼到游標處
- [ ] 4. 貼上後原本的剪貼簿內容有被還原
- [ ] 5. 在密碼欄位嘗試 → Secure Input 偵測有中止貼上

## B. CLI backend

- [ ] 6. `server_mode: false` 下正常轉錄
- [ ] 7. Diagnostics「whisper.cpp 旗標」顯示你的 build 實際支援哪些
- [ ] 8. 設 `initial_prompt` 為你的術語表 → 專有名詞辨識有改善
- [ ] 9. 設 `lang_models[<某 App>].prompt` → 在該 App 下 Diagnostics 的
        「Initial prompt」顯示**全域 + 該 App**串接後的結果
- [ ] 10. 下載 VAD model → Diagnostics「VAD」顯示啟用；靜音錄音不再產生幻覺
- [ ] 11. `cache_enabled: true` → 同一段音訊第二次明顯更快，
         `~/.ptt-whisper/cache/` 有檔案（**這條路徑在 v3.7.0 之前從未生效過**）

## C. Server backend（風險最高，尚無任何真實驗證）

- [ ] 12. `server_mode: true` + `hs.reload()` → Menubar「Server：啟動中…」
- [x] 13. ~~**模型載入期間** Menubar 顯示「模型載入中…」~~
         **已驗證：這在初次啟動時不可能發生。** whisper.cpp 的 server 在
         `main()` 裡先 `whisper_init_from_file`、再 `state.store(READY)`，
         HTTP listen 又更晚（`examples/server/server.cpp:726/735`）。
         因此啟動期間 `/health` 只會是 connection-refused，狀態直接
         「啟動中…」→「就緒」。503 `loading` 只在 runtime 呼叫 `/load`
         換模型時才出現。`classifyHealthResponse` 兩條路徑都處理正確，
         `loading` 分支屬防禦性程式碼。
- [ ] 14. 模型載入完成後才變「就緒」，且此時錄音走 server
- [ ] 15. Diagnostics「上次轉錄後端」顯示 `⚡ server`
- [ ] 16. 手動 `kill` 掉 whisper-server → 下次錄音自動退回 CLI，文字仍正確貼出
- [ ] 17. Menubar →「重啟 whisper-server」→ 正常回到就緒
- [ ] 18. **連續快速按 5 次**「重啟 whisper-server」→ 最終狀態穩定為「就緒」，
         沒有殘留的舊狀態文字，`lsof -i :8178` 只有一個行程
         ← P0-2 generation guard 的核心
- [ ] 19. 佔用該埠再 reload（`python3 -m http.server 8178`）→
         顯示「埠 8178 已被占用」並退回 CLI，**不可**誤判成 free
- [ ] 20. `hs.reload()` 數次 → 每次都乾淨收掉舊 server，埠沒有殘留
         （`lsof -i :8178` 在 reload 後短暫應為空）
- [ ] 21. 開快取 + server：確認 Menubar 出現「📦 快取（server 產生）」

### 確認「你這台編出來的 build」與 contract 一致

upstream whisper.cpp 的原始碼已確認：`/health` 就緒回 `200 {"status":"ok"}`、
載入中回 `503 {"status":"loading model"}`；`/inference` 的 multipart parser
確實會解析 `max_context` 與 `no_timestamps` 並套進 whisper inference
parameters。程式碼就是照這份 contract 實作的。

因此以下兩項的目的**不是**再證明 upstream 支不支援，而是確認
**你這台實際編譯出來的 whisper.cpp 版本與這份 contract 是否一致**
（版本落差、build option 差異都可能造成不一致）：

- [ ] 22. `curl -i http://127.0.0.1:8178/health` 在「載入中」與「就緒」
         兩個時點各跑一次，確認 status 與 body 與上述 contract 相符
- [ ] 23. 對照 CLI 模式念同一段話（尤其有設 `initial_prompt` 時），
         確認 server 路徑的輸出與 CLI 一致 —— 若明顯不同，代表你這版的
         `/inference` 對 `max_context` / `no_timestamps` 的處理與預期有落差

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
