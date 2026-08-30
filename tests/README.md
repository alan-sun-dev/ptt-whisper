# 測試

```bash
./tests/run.sh          # 全部
./tests/run.sh 50 80    # 只跑編號開頭符合的檔案
```

不需要真的 whisper.cpp、模型檔或 Hammerspoon。所有推理都由 fake 提供。

## 這套測試涵蓋什麼

| 檔案 | 範圍 |
|---|---|
| `cases/10-model-resolution.sh` | 模型候選掃描順序、`WHISPER_MODEL` 覆寫、位置參數覆寫、全部缺失的錯誤處理 |
| `cases/20-inference-params.sh` | `-t` / `-mc` / `--prompt`、UTF-8 prompt 截斷、參數範圍驗證、舊 build 能力偵測 |
| `cases/30-vad.sh` | auto/true/false、model 缺失、build 不支援、VAD 失敗重試、fallback model |
| `cases/40-cache.sh` | 開關、命中、prompt/VAD/max_context 改變 cache identity、LRU 上限、`md5` PATH 迴歸 |
| `cases/50-server.sh` | `/inference` 成功、HTTP 失敗、連線失敗、空回應、JSON 回應、模型不符、`last_backend`、multipart 字面值安全 |
| `cases/60-hallucination.sh` | exact / normalized / 純標點 / 正常文字保留 / 自訂列表 / 無共用列表的 fallback |
| `cases/70-bad-input.sh` | 缺檔、過小檔、非法環境變數、8kHz 自動 resample |
| `cases/80-health-scenarios.sh` | `/health` 六種情境的契約，以及 Lua readiness 分類器 |

`run.sh` 另外會跑靜態檢查：`bash -n`、JSON 合法性、Lua 區塊平衡、
以及設定欄位在 Lua 白名單 / README / `config_example.json` 三方的一致性。

## Fakes

- `fakes/fake-whisper-cli` — 可設定能力集（`FAKE_CAPS`）、可設定失敗條件
  （`FAKE_FAIL_ON_VAD` / `FAKE_FAIL_MODELS`），把收到的參數記錄下來供斷言。
- `fakes/fake-whisper-server.py` — `/health` 與 `/inference` 的行為可分別設定；
  `/health` 支援 `ok` / `loading` / `notfound` / `foreign` / `malformed` / `error`。

測試刻意使用與 `ptt_whisper.lua` 完全相同的 `PATH`
（含 `/sbin`），否則像「`md5` 找不到導致快取靜默失效」這種只在真實 runtime
出現的 bug 永遠測不出來。

## 尚未被測到的部分

**這套測試驗證的是 `transcribe.sh` 與 Lua 的純函式，不是 Hammerspoon runtime。**

以下項目**沒有**自動化覆蓋，必須在真實 Mac 上驗證
（見 repo 根目錄的 `REAL_MAC_VALIDATION.md`）：

- Hammerspoon 載入、熱鍵綁定、錄音、剪貼簿貼上、Secure Input 偵測
- `hs.task` 的 server 生命週期：啟動、`/health` 輪詢、terminate、重啟
- generation guard 在真實非同步時序下的行為
- 與**真正的** `whisper-server` 的 HTTP 契約
  （`/health` 回應格式、`/inference` 是否真的吃 `max_context`、`no_timestamps`）
- 真實模型的轉錄品質、`-mc 0` 與預設 context 的 A/B 比較

若本機沒有 lua 直譯器，`80-health-scenarios.sh` 的 Lua 分類器單元測試會被
**略過**並明確標示。安裝任一 lua（`brew install lua`）後會自動執行。
