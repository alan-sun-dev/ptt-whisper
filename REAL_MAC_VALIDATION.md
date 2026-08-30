# 真機驗證清單（v4.0.x）

開發環境**沒有** Hammerspoon runtime，也**沒有** whisper.cpp runtime。

`./tests/run.sh` 驗證的是 `transcribe.sh` 的行為與 Lua 的純函式，
使用 fake whisper-cli 與 fake whisper-server。它**不是** runtime 驗證。
Lua 只做了區塊平衡與定義順序的靜態檢查——那不等於「能載入」，
更不等於「行為正確」。

以下必須在真實 Mac 上人工完成。合併 PR 前請逐項確認。

## A. 載入與基本功能

- [ ] 1. `hs.reload()` — Hammerspoon Console 無錯誤，出現「PTT Whisper v4.0.1 已載入」
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
- [ ] 13. **模型載入期間** Menubar 顯示「模型載入中…」而**不是**「就緒」
         ← P0-1 的核心。若這裡直接跳到「就緒」，表示 `/health` 的回應
         格式與 `classifyHealthResponse` 的假設不符，請把實際回應貼給我
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

### 需要回報給我的事實

- [ ] 22. **whisper-server 的 `/health` 實際回應**（status + body 原文）
         — `curl -i http://127.0.0.1:8178/health` 在載入中與就緒兩個時點各一次
- [ ] 23. **`/inference` 是否真的吃下 `max_context` 與 `no_timestamps`**
         — 對照 CLI 模式念同一段話（尤其有設 `initial_prompt` 時），
         輸出是否一致。server 有可能靜默忽略這些欄位

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
