# PTT Whisper v3.5.1 / transcribe.sh v2.7.1 — Changelog

## 修正摘要

根據 Code Review 報告的 3 個 Bug + 5 個改進建議，共計 10 項修正。

---

### ptt_whisper.lua v3.5.0 → v3.5.1

| 編號 | 類型 | 修正內容 |
|------|------|----------|
| R6 | 🔴 Bug Fix | Streaming fallback 改為漸進式降級（連續失敗 3 次才永久切換傳統模式），新增 `handleStreamingFailure()` 輔助函式與 `streamingFailCount` 計數器 |
| R7 | 🟡 改進 | Streaming callback 現在會將 stderr 記錄到 log（截取前 200 字元），便於診斷 whisper.cpp 問題 |
| R8 | 🟡 改進 | `cleanStreamOutput()` 改為合併所有非重複有效行（而非只取最後一行），避免長錄音時遺失前面的轉錄結果 |
| R9 | 🟡 改進 | Config 載入加入 `streaming_step_ms`（100~10000）和 `streaming_length_ms`（1000~30000）範圍驗證，超出範圍時使用預設值並輸出警告 |
| R10 | 🟢 小改進 | Log rotation 的 regex 改為精確匹配 `YYYYMMDD-HHMMSS` 格式（8+6 位數字），避免誤匹配 |

**其他：**
- 幻覺列表加入同步提醒註解（`⚠️ 注意：此列表需與 transcribe.sh 的內建列表保持同步`）
- `cleanup()` 新增 `streamingFailCount` 重置
- 內建幻覺列表補齊缺少的法文 Amara.org 條目（與 bash 端同步）

---

### transcribe.sh v2.7 → v2.7.1

| 編號 | 類型 | 修正內容 |
|------|------|----------|
| R1 | 🔴 Bug Fix | 快取 LRU 清理變數從 `local_cache_files` 重命名為 `cached_files`（消除語意混淆），並加入安全性註解說明 `ls` 解析在本專案 cache key 格式下是安全的 |
| R2 | 🔴 Bug Fix | `run_whisper()` 中 `$tcmd` 加引號為 `"$tcmd"`，符合 `set -euo pipefail` 嚴格模式精神 |
| R3 | 🟡 改進 | 快取 key 區塊加入限制說明註解：cache key 不含 whisper.cpp 版本，升級後建議清除快取 |
| R4 | 🟢 小改進 | `stat` 檔案大小檢查加入跨平台相容性註解（macOS `-f%z` vs Linux `-c%s`） |

**其他：**
- 幻覺過濾區塊加入同步提醒註解（`⚠️ 注意：此內建列表需與 ptt_whisper.lua 的 builtinHallucinations 保持同步`）
