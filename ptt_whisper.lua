-- ============================================================
-- Push-to-Talk Whisper Dictation for Hammerspoon
-- v3.5.1
--
-- v3.5.1 修正（Code Review 修正）：
--   R6. [Fix] Streaming fallback 改為漸進式降級（連續失敗 N 次才切換）
--   R7. [Fix] Streaming callback 記錄 stderr 到 log
--   R8. [Fix] cleanStreamOutput 合併所有非重複行（避免遺失多句結果）
--   R9. [Fix] Config 載入加入 streaming 參數範圍驗證
--   R10.[Fix] Log rotation regex 更精確匹配日期格式
--
-- v3.5.0 新功能（第九輪 — 中期架構優化）：
--   F4. [Feature] 轉錄結果快取（bash 端實作，Lua 傳 env var）
--   F5. [Feature] Streaming 即時轉錄模式
--        whisper.cpp --stream 邊錄邊轉，體感延遲 <0.5s
--        新增 STATE.STREAMING 狀態、streamingCallback 累積文字
--        config.json 的 streaming_mode 開關（預設 false）
--   F6. [Feature] 錯誤恢復 — Fallback Model（bash 端實作，Lua 傳 env var）
--   F7. [Feature] 健康檢查 / 自我診斷
--        Menubar → Run Diagnostics 一鍵檢查所有依賴
--
-- v3.4.1：R2,R4  v3.4.0：F1~F3  v3.3.5：ZP~ZT
-- v3.3.4：ZM~ZO  v3.3.3：ZI~ZL  v3.3.2：ZC~ZH
-- v3.3.1：ZA~ZB  v3.3：Z1~Z9  v3.2：Q~Y  v3.1：L~P
-- v3.0：E~K  v2.1：A~D
--
-- 使用方式：按住 Right Option 錄音，放開後自動轉錄並貼上
-- 依賴：ffmpeg、whisper.cpp 已編譯、~/ptt-whisper/transcribe.sh v2.7.1+
-- ============================================================

-- ── 版本常數 ────────────────────────────────────────────────
local VERSION = "3.5.1"

-- ── 設定區（Config）──────────────────────────────────────────

-- 路徑
local PTT_DIR           = os.getenv("HOME") .. "/.ptt-whisper"
local RECORD_FILE       = PTT_DIR .. "/ptt_record.wav"
local LOG_FILE          = PTT_DIR .. "/ptt_whisper_err.log"
local TRANSCRIBE_SH     = os.getenv("HOME") .. "/ptt-whisper/transcribe.sh"
local CONFIG_FILE       = PTT_DIR .. "/config.json"

-- 熱鍵
local HOTKEY_MODS       = {}
local HOTKEY_KEY        = "rightalt"

-- 時間閾值
local MIN_RECORD_SEC    = 0.3
local MIN_FILE_BYTES    = 1000
local FFMPEG_FLUSH_SEC  = 0.3
local PASTE_RESTORE_SEC = 0.6
local KILL_FALLBACK_SEC = 0.5

-- Log
local MAX_LOG_SIZE      = 512 * 1024
local MAX_LOG_FILES     = 5

-- 音訊
local AUDIO_DEVICE      = ":0"
local SOUND_REC_START   = "Tink"
local SOUND_REC_STOP    = "Pop"

-- UI
local SHOW_PREVIEW_ALERT = true

-- 貼上延遲
local SLOW_PASTE_APPS = {
  ["com.tinyspeck.slackmacgap"] = 1.0,
  ["com.microsoft.teams"]       = 1.0,
  ["com.microsoft.teams2"]      = 1.0,
  ["us.zoom.xos"]               = 0.9,
  ["com.microsoft.Outlook"]     = 0.8,
}

-- 多語言 model 切換
local LANG_MODELS = {}

-- ── [F5] Streaming 模式設定 ─────────────────────────────────
-- ⚠️ 實驗性功能：需要 whisper.cpp 支援 --stream 旗標
-- 啟用後按住熱鍵時 whisper.cpp 直接從麥克風擷取並即時轉錄，
-- 放開後幾乎立刻輸出結果。體感延遲從 2-3s 降至 <0.5s。
--
-- 限制：
--   1. Streaming 模式使用 whisper.cpp 自己的音訊擷取（PortAudio/SDL），
--      AUDIO_DEVICE 設定不適用（只能用系統預設麥克風）
--   2. 若 whisper.cpp build 不支援 --stream，會 graceful fallback 到傳統模式
--   3. 大型 model（large-v3）在 streaming 模式下可能延遲較高
local STREAMING_MODE     = false
local STREAMING_STEP_MS  = 500     -- 每次處理的步長（ms），有效範圍 100~10000
local STREAMING_LENGTH_MS = 5000   -- 每次處理的音訊窗口長度（ms），有效範圍 1000~30000

-- ── [F4] 快取設定 ────────────────────────────────────────────
-- 傳統模式下透過 env var 傳給 transcribe.sh v2.7
-- Streaming 模式不支援快取（音訊不寫入檔案）
local CACHE_ENABLED = false

-- ── [F6] Fallback Model ─────────────────────────────────────
-- 傳統模式：透過 env var 傳給 transcribe.sh
-- Streaming 模式：Lua 端自行 retry
-- 格式：檔名（如 "ggml-tiny.bin"）或完整路徑
local FALLBACK_MODEL = ""

-- ── [R6] Streaming fallback 漸進式降級 ──────────────────────
-- 連續失敗達到閾值才永久切換為傳統模式（避免暫時性問題導致永久降級）
local STREAMING_FALLBACK_THRESHOLD = 3

-- ── 外部設定檔載入 ──────────────────────────────────────────
local function loadExternalConfig()
  local f = io.open(CONFIG_FILE, "r")
  if not f then return end
  local ok, content = pcall(function() return f:read("*a") end)
  f:close()
  if not ok or not content or content == "" then return end

  local decodeOk, config = pcall(hs.json.decode, content)
  if not decodeOk or type(config) ~= "table" then
    print("[PTT Whisper] WARNING: config.json parse failed, ignoring")
    return
  end

  if type(config.slow_paste_apps) == "table" then
    for bid, delay in pairs(config.slow_paste_apps) do
      if type(bid) == "string" and type(delay) == "number" then
        SLOW_PASTE_APPS[bid] = delay
      end
    end
  end
  if type(config.show_preview_alert) == "boolean" then
    SHOW_PREVIEW_ALERT = config.show_preview_alert
  end
  if type(config.lang_models) == "table" then
    for bid, entry in pairs(config.lang_models) do
      if type(bid) == "string" and type(entry) == "table" then
        local parsed = {}
        if type(entry.lang) == "string" and entry.lang ~= "" then
          parsed.lang = entry.lang
        end
        if type(entry.model) == "string" and entry.model ~= "" then
          parsed.model = entry.model
        end
        if parsed.lang or parsed.model then
          LANG_MODELS[bid] = parsed
        end
      end
    end
  end
  -- [F5] streaming_mode
  if type(config.streaming_mode) == "boolean" then
    STREAMING_MODE = config.streaming_mode
  end
  -- [R9] 加入範圍驗證，避免極端值導致 whisper.cpp 行為異常
  if type(config.streaming_step_ms) == "number"
     and config.streaming_step_ms >= 100
     and config.streaming_step_ms <= 10000 then
    STREAMING_STEP_MS = config.streaming_step_ms
  elseif type(config.streaming_step_ms) == "number" then
    print("[PTT Whisper] WARNING: streaming_step_ms out of range (100~10000), using default")
  end
  if type(config.streaming_length_ms) == "number"
     and config.streaming_length_ms >= 1000
     and config.streaming_length_ms <= 30000 then
    STREAMING_LENGTH_MS = config.streaming_length_ms
  elseif type(config.streaming_length_ms) == "number" then
    print("[PTT Whisper] WARNING: streaming_length_ms out of range (1000~30000), using default")
  end
  -- [F4] cache
  if type(config.cache_enabled) == "boolean" then
    CACHE_ENABLED = config.cache_enabled
  end
  -- [F6] fallback_model
  if type(config.fallback_model) == "string" then
    FALLBACK_MODEL = config.fallback_model
  end
end

loadExternalConfig()

-- ── 工作目錄初始化 ──────────────────────────────────────────
hs.fs.mkdir(PTT_DIR)
hs.execute(string.format([[chmod 700 "%s"]], PTT_DIR))

-- ── Reload 防護 ─────────────────────────────────────────────
if PTTWhisper and PTTWhisper._cleanup then
  PTTWhisper._cleanup()
end

-- ── 狀態機 ───────────────────────────────────────────────────
local STATE = {
  IDLE         = "idle",
  RECORDING    = "recording",
  TRANSCRIBING = "transcribing",
  STREAMING    = "streaming",      -- [F5] 邊錄邊轉
  PASTING      = "pasting",
}
local currentState = STATE.IDLE
local sessionCounter = 0

-- 模組級引用
local recordTask       = nil
local transcribeTask   = nil
local streamTask       = nil       -- [F5]
local recordStartAt    = nil
local cachedFFmpegPath = nil
local streamAccumulator = ""       -- [F5] 累積 streaming 輸出

-- [R6] Streaming 連續失敗計數器
local streamingFailCount = 0
-- 記住使用者原始設定，以便區分「使用者關閉」與「自動降級」
local streamingModeUserSetting = STREAMING_MODE

-- ── Menubar ─────────────────────────────────────────────────
local menubarItem = hs.menubar.new()

local function updateMenubar(icon, tooltip)
  if menubarItem then
    menubarItem:setTitle(icon)
    menubarItem:setTooltip(tooltip or "PTT Whisper")
  end
end

-- ── 全域 API ────────────────────────────────────────────────
PTTWhisper = PTTWhisper or {}

-- ── 工具函式 ─────────────────────────────────────────────────

--- UTF-8 safe substring
local function utf8Sub(s, maxChars)
  if not s or s == "" then return "", false end
  local ok, utf8Lib = pcall(require, "utf8")
  if not ok then
    local charCount, bytePos, len = 0, 1, #s
    while bytePos <= len and charCount < maxChars do
      local b = s:byte(bytePos)
      if     b < 0x80 then bytePos = bytePos + 1
      elseif b < 0xE0 then bytePos = bytePos + 2
      elseif b < 0xF0 then bytePos = bytePos + 3
      else                  bytePos = bytePos + 4 end
      charCount = charCount + 1
    end
    if bytePos <= len then return s:sub(1, bytePos - 1), true end
    return s, false
  end
  local totalChars = utf8Lib.len(s)
  if not totalChars then
    local safeLen = math.min(#s, maxChars * 3)
    return s:sub(1, safeLen), (#s > safeLen)
  end
  if totalChars <= maxChars then return s, false end
  local endByte = utf8Lib.offset(s, maxChars + 1)
  if endByte then return s:sub(1, endByte - 1), true end
  return s, false
end

--- Append error log
local function appendErrorLog(msg)
  local attr = hs.fs.attributes(LOG_FILE)
  if attr and (attr.size or 0) > MAX_LOG_SIZE then
    local ts = os.date("%Y%m%d-%H%M%S")
    os.rename(LOG_FILE, LOG_FILE .. "." .. ts)
    local logFiles = {}
    for file in hs.fs.dir(PTT_DIR) do
      -- [R10] 更精確匹配日期格式 YYYYMMDD-HHMMSS
      if file:match("^ptt_whisper_err%.log%.%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d$") then
        table.insert(logFiles, file)
      end
    end
    table.sort(logFiles)
    while #logFiles > MAX_LOG_FILES do
      os.remove(PTT_DIR .. "/" .. table.remove(logFiles, 1))
    end
  end
  local logFile = io.open(LOG_FILE, "a")
  if logFile then
    logFile:write(os.date("[%Y-%m-%d %H:%M:%S] ") .. msg .. "\n")
    logFile:close()
  end
end

--- 取得 ffmpeg 路徑
local function findFFmpeg()
  if cachedFFmpegPath then return cachedFFmpegPath end
  for _, path in ipairs({
    "/opt/homebrew/bin/ffmpeg",
    "/usr/local/bin/ffmpeg",
    "/usr/bin/ffmpeg",
  }) do
    if hs.fs.attributes(path) then cachedFFmpegPath = path; return path end
  end
  local found = hs.execute("which ffmpeg 2>/dev/null"):gsub("%s+$", "")
  if found ~= "" then cachedFFmpegPath = found; return found end
  return nil
end

--- [F5][F7] 取得 whisper.cpp 二進位路徑
local cachedWhisperBin = nil
local function findWhisperBin()
  if cachedWhisperBin then return cachedWhisperBin end
  local whisperDir = os.getenv("WHISPER_DIR")
                     or (os.getenv("HOME") .. "/whisper.cpp")
  for _, rel in ipairs({
    "/whisper-cli",
    "/build/bin/whisper-cli",
    "/main",
    "/build/bin/main",
  }) do
    local path = whisperDir .. rel
    if hs.fs.attributes(path) then
      cachedWhisperBin = path
      return path
    end
  end
  return nil
end

--- [F5][F7] 解析 model 路徑
--- @param modelName string|nil  檔名或完整路徑（nil = 使用預設）
--- @return string|nil  完整路徑（nil = 找不到）
local function resolveModelPath(modelName)
  local whisperDir = os.getenv("WHISPER_DIR")
                     or (os.getenv("HOME") .. "/whisper.cpp")
  local path
  if not modelName or modelName == "" then
    path = os.getenv("WHISPER_MODEL")
           or (whisperDir .. "/models/ggml-small.bin")
  elseif modelName:sub(1, 1) == "/" then
    path = modelName
  else
    path = whisperDir .. "/models/" .. modelName
  end
  if hs.fs.attributes(path) then return path end
  return nil
end

--- 列出音訊裝置
local function listAudioDevices()
  local ffmpeg = findFFmpeg()
  if not ffmpeg then print("❌ ffmpeg not found"); return end
  local cmd = string.format([["%s" -f avfoundation -list_devices true -i '' 2>&1]], ffmpeg)
  local output = hs.execute(cmd)
  print("=== AVFoundation Audio Devices ===")
  print(output or "(no output)")
  print("==================================")
end

PTTWhisper.findFFmpeg       = findFFmpeg
PTTWhisper.findWhisperBin   = findWhisperBin
PTTWhisper.resolveModelPath = resolveModelPath
PTTWhisper.listAudioDevices = listAudioDevices

--- 安全終止 task
local function killTask(task)
  if not task then return end
  pcall(function()
    if task:isRunning() then
      task:interrupt()
      hs.timer.doAfter(KILL_FALLBACK_SEC, function()
        pcall(function()
          if task:isRunning() then
            task:terminate()
            appendErrorLog("killTask: SIGINT timeout, sent SIGTERM")
          end
        end)
      end)
    end
  end)
end

--- 播放音效
local function playSound(name)
  if not name then return end
  pcall(function()
    local s = hs.sound.getByName(name)
    if s then s:play() end
  end)
end

--- 根據前景 app 決定貼上延遲
local function getPasteDelay()
  local ok, app = pcall(hs.application.frontmostApplication)
  if ok and app then
    local bid = app:bundleID()
    if bid and SLOW_PASTE_APPS[bid] then return SLOW_PASTE_APPS[bid] end
  end
  return PASTE_RESTORE_SEC
end

--- 根據前景 app 取得語言/模型
local function getLangModelForCurrentApp()
  local ok, app = pcall(hs.application.frontmostApplication)
  if not ok or not app then return nil, nil, "(unknown)" end
  local bid = app:bundleID() or ""
  local appName = app:name() or bid
  local entry = LANG_MODELS[bid] or LANG_MODELS["_default"]
  if not entry then return nil, nil, appName end
  local lang = entry.lang
  if lang == "auto" then lang = nil end
  return lang, entry.model, appName
end

PTTWhisper.getLangModelForCurrentApp = getLangModelForCurrentApp

--- 保存/還原剪貼簿
local function saveClipboard()
  local saved = {}
  local ok, types = pcall(hs.pasteboard.contentTypes)
  if ok and types then
    for _, ctype in ipairs(types) do
      local dataOk, data = pcall(hs.pasteboard.readDataForUTI, nil, ctype)
      if dataOk and data then table.insert(saved, { uti = ctype, data = data }) end
    end
  end
  if #saved == 0 then
    local text = hs.pasteboard.getContents()
    if text then table.insert(saved, { uti = "__plaintext_fallback__", data = text }) end
  end
  return saved
end

local function restoreClipboard(saved)
  if not saved or #saved == 0 then return end
  if #saved == 1 and saved[1].uti == "__plaintext_fallback__" then
    hs.pasteboard.setContents(saved[1].data)
    return
  end
  hs.pasteboard.clearContents()
  for _, entry in ipairs(saved) do
    pcall(hs.pasteboard.writeDataForUTI, nil, entry.uti, entry.data)
  end
end

-- ── 統一失敗出口 ────────────────────────────────────────────
local function abortToIdle(reason, opts)
  opts = opts or {}
  currentState = STATE.IDLE
  updateMenubar(opts.icon or "⚠️", "PTT Whisper — " .. reason)
  if opts.log then appendErrorLog(opts.log) end
  if opts.alert then hs.alert.show(opts.alert, opts.alertDur or 2) end
  if opts.saved then restoreClipboard(opts.saved) end
end

--- 貼上文字 → 延遲還原剪貼簿 → IDLE
local function pasteText(text, savedClipboard, sid, previewTooltip)
  if hs.eventtap.isSecureInputEnabled() then
    abortToIdle("Secure Input — Aborted", {
      log = "pasteText: aborted due to Secure Input",
      alert = "⚠️ 偵測到 Secure Input（密碼框），已中止貼上",
      alertDur = 3, saved = savedClipboard, icon = "🎤",
    })
    return
  end
  hs.pasteboard.setContents(text)
  hs.timer.doAfter(0.05, function()
    if sid ~= sessionCounter then
      appendErrorLog("pasteText: session mismatch")
      restoreClipboard(savedClipboard)
      return
    end
    hs.eventtap.keyStroke({"cmd"}, "v", 2000)
    hs.timer.doAfter(getPasteDelay(), function()
      restoreClipboard(savedClipboard)
      currentState = STATE.IDLE
      if previewTooltip then
        updateMenubar("🎤", previewTooltip)
      else
        updateMenubar("🎤", "PTT Whisper v" .. VERSION .. " — Ready")
      end
    end)
  end)
end

--- 檢查錄音檔
local function isRecordFileValid()
  local attr = hs.fs.attributes(RECORD_FILE)
  if not attr then return false, "錄音檔不存在" end
  if (attr.size or 0) < MIN_FILE_BYTES then
    return false, string.format("錄音檔過小（%d bytes）", attr.size or 0)
  end
  return true, nil
end

--- 檢查 transcribe.sh
local function isTranscribeScriptReady()
  local attr = hs.fs.attributes(TRANSCRIBE_SH)
  if not attr then return false, "找不到 transcribe.sh：\n" .. TRANSCRIBE_SH end
  local perms = attr.permissions or ""
  local ownerExec = perms:sub(3, 3)
  if ownerExec ~= "x" and ownerExec ~= "s" then
    return false, "transcribe.sh 不可執行\n請執行 chmod +x " .. TRANSCRIBE_SH
  end
  return true, nil
end

-- ── [F5] Streaming 模式幻覺過濾 ─────────────────────────────
-- Streaming 模式不經 bash 腳本，需要 Lua 端自行過濾
-- 內建列表 + 外部 hallucinations.txt
-- ⚠️ 注意：此列表需與 transcribe.sh 的內建列表保持同步

local builtinHallucinations = {
  "Thank you.", "Thank you!", "Thank you",
  "Thanks.", "Thanks for watching.", "Thanks for watching!",
  "Thanks for listening.",
  "Thank you for watching.", "Thank you for watching!",
  "Thank you for listening.",
  "Please subscribe.", "Subscribe.", "Like and subscribe.",
  "Bye.", "Bye bye.", "Bye-bye.", "Goodbye.", "Good bye.",
  "...", "..", ".", ",",
  "Subtitles by the Amara.org community",
  "Subtitles by the Amara.org community.",
  "Sous-titres réalisés para la communauté d'Amara.org",
  "ご視聴ありがとうございました", "ご視聴ありがとうございました。",
  "謝謝觀看", "謝謝觀看。", "謝謝觀看！",
  "謝謝收看", "謝謝收看。", "謝謝收聽", "謝謝收聽。",
  "謝謝", "謝謝。", "感謝觀看", "感謝觀看。",
  "字幕由Amara.org社區提供",
  "請訂閱", "請訂閱。", "再見", "再見。",
}

-- 建立 lookup set 以提高比對速度
local hallucinationSet = {}
for _, h in ipairs(builtinHallucinations) do hallucinationSet[h] = true end

-- 載入外部幻覺列表
local function loadExternalHallucinations()
  local path = PTT_DIR .. "/hallucinations.txt"
  local f = io.open(path, "r")
  if not f then return end
  for line in f:lines() do
    line = line:match("^%s*(.-)%s*$")  -- trim
    if line ~= "" and line:sub(1, 1) ~= "#" then
      hallucinationSet[line] = true
    end
  end
  f:close()
end
loadExternalHallucinations()

--- 對文字做幻覺過濾
--- @param text string
--- @return string  過濾後文字（空字串 = 幻覺）
local function filterHallucinations(text)
  if not text or text == "" then return "" end
  -- trim
  text = text:match("^%s*(.-)%s*$")
  if text == "" then return "" end
  -- 精確匹配
  if hallucinationSet[text] then return "" end
  -- 純標點檢查
  local stripped = text:gsub("[%p%s]", "")
  if stripped == "" then return "" end
  return text
end

--- [F5][R8] 清理 whisper.cpp --stream 的輸出
--- 移除 ANSI escape codes、timestamp 標記，合併所有非重複有效行
local function cleanStreamOutput(raw)
  if not raw or raw == "" then return "" end
  -- 移除 ANSI escape codes
  local cleaned = raw:gsub("\27%[[%d;]*[A-Za-z]", "")
  -- 移除 carriage returns（--stream 用 \r 覆寫行）
  cleaned = cleaned:gsub("\r", "\n")
  -- 移除 timestamp 格式 [HH:MM:SS.mmm --> HH:MM:SS.mmm]
  cleaned = cleaned:gsub("%[%d+:%d+:%d+%.%d+%s*%-%->%s*%d+:%d+:%d+%.%d+%]", "")
  -- 移除 whisper tag 標記
  cleaned = cleaned:gsub("%[BLANK_AUDIO%]", "")
  cleaned = cleaned:gsub("%[[Ss]ilence%]", "")
  cleaned = cleaned:gsub("%[[Mm]usic%]", "")

  -- 取所有非空行
  local lines = {}
  for line in cleaned:gmatch("[^\n]+") do
    local trimmed = line:match("^%s*(.-)%s*$")
    if trimmed ~= "" then
      table.insert(lines, trimmed)
    end
  end

  if #lines == 0 then return "" end

  -- [R8] 合併所有非重複行（--stream 可能重複輸出已確認的文字）
  -- 僅去除「連續」重複：--stream 的重複是相鄰行重複輸出，
  -- 全域去重會誤刪使用者實際口述的合法重複語句
  local unique = {}
  for _, line in ipairs(lines) do
    if line ~= unique[#unique] then
      table.insert(unique, line)
    end
  end
  return table.concat(unique, " ")
end

-- ── 傳統模式主流程 ──────────────────────────────────────────

local function startRecording()
  if currentState ~= STATE.IDLE then
    if currentState == STATE.TRANSCRIBING then
      hs.alert.show("⚠️ 轉錄中，請稍候...", 1)
    elseif currentState == STATE.PASTING then
      hs.alert.show("⚠️ 貼上中，請稍候...", 1)
    elseif currentState == STATE.STREAMING then
      hs.alert.show("⚠️ 串流轉錄中...", 1)
    end
    return
  end

  local ffmpeg = findFFmpeg()
  if not ffmpeg then
    hs.alert.show("❌ 找不到 ffmpeg，請執行 brew install ffmpeg")
    return
  end
  local scriptOk, scriptErr = isTranscribeScriptReady()
  if not scriptOk then
    hs.alert.show("❌ " .. scriptErr)
    return
  end

  sessionCounter = sessionCounter + 1
  os.remove(RECORD_FILE)

  currentState  = STATE.RECORDING
  recordStartAt = hs.timer.secondsSinceEpoch()
  updateMenubar("🔴", "PTT Whisper — Recording...")

  recordTask = hs.task.new(ffmpeg, function(exitCode, _, stderr)
    if exitCode ~= 0 and exitCode ~= 255 and currentState == STATE.RECORDING then
      hs.timer.doAfter(0, function()
        recordTask = nil
        abortToIdle("Recording Failed", {
          log   = "ffmpeg failed: exit=" .. tostring(exitCode)
                  .. " stderr=" .. (stderr or ""),
          alert = "❌ 錄音失敗，請檢查麥克風權限",
          alertDur = 3,
        })
      end)
    end
  end, {
    "-y", "-f", "avfoundation", "-i", AUDIO_DEVICE,
    "-ac", "1", "-ar", "16000", RECORD_FILE,
  })

  if recordTask:start() then
    playSound(SOUND_REC_START)
  else
    recordTask = nil; recordStartAt = nil
    abortToIdle("Start Failed", { alert = "❌ ffmpeg 啟動失敗" })
  end
end

local function stopRecordingAndTranscribe()
  if currentState ~= STATE.RECORDING then return end
  local sid = sessionCounter
  local duration = recordStartAt
                   and (hs.timer.secondsSinceEpoch() - recordStartAt) or 0
  recordStartAt = nil
  killTask(recordTask)
  recordTask = nil
  playSound(SOUND_REC_STOP)

  if duration < MIN_RECORD_SEC then
    currentState = STATE.IDLE
    updateMenubar("🎤", string.format(
      "PTT Whisper v%s — 誤觸忽略（%.2fs）", VERSION, duration))
    return
  end

  currentState = STATE.TRANSCRIBING
  updateMenubar("⏳", "PTT Whisper — Transcribing...")
  local savedClipboard = saveClipboard()
  local langOverride, modelOverride, appName = getLangModelForCurrentApp()

  hs.timer.doAfter(FFMPEG_FLUSH_SEC, function()
    if sid ~= sessionCounter then return end
    if currentState ~= STATE.TRANSCRIBING then return end

    local valid, errMsg = isRecordFileValid()
    if not valid then
      abortToIdle(errMsg, { log = "skipped: " .. errMsg,
                            alert = "⚠️ " .. errMsg .. "，跳過轉錄" })
      return
    end

    hs.execute(string.format([[chmod 600 "%s" 2>/dev/null]], RECORD_FILE))

    -- 組裝 transcribe.sh 參數
    local taskArgs = { TRANSCRIBE_SH, RECORD_FILE }
    if langOverride or modelOverride then
      table.insert(taskArgs, langOverride or "")
      table.insert(taskArgs, modelOverride or "")
    end

    -- [F4][F6] 透過環境變數傳遞快取/fallback 設定給 transcribe.sh
    local env = {
      PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
      HOME = os.getenv("HOME"),
    }
    if CACHE_ENABLED then env.WHISPER_CACHE = "true" end
    if FALLBACK_MODEL ~= "" then env.WHISPER_FALLBACK_MODEL = FALLBACK_MODEL end
    -- 保留使用者的 WHISPER_DIR 等設定
    for _, k in ipairs({"WHISPER_DIR", "WHISPER_MODEL", "WHISPER_LANG",
                        "WHISPER_TIMEOUT", "WHISPER_AUTO_RESAMPLE"}) do
      local v = os.getenv(k)
      if v then env[k] = v end
    end

    transcribeTask = hs.task.new("/bin/bash", function(exitCode, stdout, stderr)
      hs.timer.doAfter(0, function()
        transcribeTask = nil
        if sid ~= sessionCounter then return end
        if currentState ~= STATE.TRANSCRIBING then return end

        if exitCode ~= 0 then
          abortToIdle("Transcribe Failed", {
            log = "exit=" .. tostring(exitCode) .. " stderr=" .. (stderr or ""),
            alert = "❌ 轉錄失敗 (exit " .. tostring(exitCode) .. ")",
            alertDur = 3,
          })
          return
        end

        local text = (stdout or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if text == "" then
          abortToIdle("Ready", { alert = "🤔 未偵測到語音", icon = "🎤" })
          return
        end

        currentState = STATE.PASTING
        updateMenubar("📋", "PTT Whisper — Pasting...")
        local previewTooltip = nil
        if SHOW_PREVIEW_ALERT then
          local preview, truncated = utf8Sub(text, 20)
          hs.alert.show("✅ " .. preview .. (truncated and "…" or ""), 2)
        else
          local preview, truncated = utf8Sub(text, 30)
          previewTooltip = "✅ " .. preview .. (truncated and "…" or "")
        end
        pasteText(text, savedClipboard, sid, previewTooltip)
      end)
    end, taskArgs)

    transcribeTask:setEnvironment(env)

    if not transcribeTask:start() then
      transcribeTask = nil
      abortToIdle("Script Failed", { alert = "❌ transcribe.sh 啟動失敗" })
    end
  end)
end

-- ── [R6] Streaming 降級輔助函式 ─────────────────────────────
--- 記錄 streaming 失敗，達到閾值才永久切換傳統模式
--- @param reason string  失敗原因（寫入 log）
--- @return boolean  true = 已達閾值並切換, false = 僅計數
local function handleStreamingFailure(reason)
  streamingFailCount = streamingFailCount + 1
  appendErrorLog(string.format(
    "streaming: %s (fail_count=%d/%d)",
    reason, streamingFailCount, STREAMING_FALLBACK_THRESHOLD))

  if streamingFailCount >= STREAMING_FALLBACK_THRESHOLD then
    STREAMING_MODE = false
    appendErrorLog("streaming: reached failure threshold, permanently switching to traditional mode")
    hs.alert.show(string.format(
      "⚠️ Streaming 連續失敗 %d 次，已切換傳統模式\nReload 可恢復",
      streamingFailCount), 3)
    return true
  else
    hs.alert.show(string.format(
      "⚠️ Streaming 失敗（%d/%d），本次使用傳統模式",
      streamingFailCount, STREAMING_FALLBACK_THRESHOLD), 2)
    return false
  end
end

-- ── [F5] Streaming 模式主流程 ───────────────────────────────

--- 啟動 whisper.cpp --stream 直接擷取麥克風
local function startStreaming()
  if currentState ~= STATE.IDLE then
    hs.alert.show("⚠️ 忙碌中，請稍候...", 1)
    return
  end

  local whisperBin = findWhisperBin()
  if not whisperBin then
    -- Fallback：whisper.cpp 找不到，改用傳統模式
    appendErrorLog("streaming: whisper.cpp not found, falling back to traditional mode")
    startRecording()
    return
  end

  -- 解析 model（考慮 lang_models 覆寫）
  local langOverride, modelOverride, appName = getLangModelForCurrentApp()
  local modelPath = resolveModelPath(modelOverride)
  if not modelPath then
    appendErrorLog("streaming: model not found, falling back to traditional mode")
    startRecording()
    return
  end

  sessionCounter = sessionCounter + 1
  local sid = sessionCounter
  streamAccumulator = ""

  currentState  = STATE.STREAMING
  recordStartAt = hs.timer.secondsSinceEpoch()
  updateMenubar("🔴", "PTT Whisper — Streaming...")

  -- 組裝 whisper.cpp --stream 參數
  local args = {
    "--stream",
    "-m", modelPath,
    "-nt",                                             -- no timestamps
    "--step", tostring(STREAMING_STEP_MS),
    "--length", tostring(STREAMING_LENGTH_MS),
    "-nc",                                             -- no colors
  }
  if langOverride and langOverride ~= "" then
    table.insert(args, "-l")
    table.insert(args, langOverride)
  end

  appendErrorLog(string.format(
    "streaming: start app=%s lang=%s model=%s",
    appName, langOverride or "(auto)", modelPath))

  -- 使用 4 參數形式的 hs.task.new：含 streaming callback
  streamTask = hs.task.new(
    whisperBin,
    -- termination callback
    function(exitCode, stdout, stderr)
      hs.timer.doAfter(0, function()
        -- 如果 stopStreaming 已處理（設 streamTask = nil），直接跳過
        if not streamTask then return end
        -- 只有非預期終止才進入此處
        streamTask = nil
        if currentState == STATE.STREAMING and sid == sessionCounter then
          if streamAccumulator == "" and exitCode ~= 0 and exitCode ~= 255 then
            -- [R6] 漸進式降級：記錄失敗，達閾值才永久切換
            currentState = STATE.IDLE
            handleStreamingFailure("unexpected exit=" .. tostring(exitCode))
          end
        end
      end)
    end,
    -- [R7] streaming callback：記錄 stdout 並 log stderr
    function(task, stdout, stderr)
      if stdout and stdout ~= "" then
        streamAccumulator = streamAccumulator .. stdout
      end
      if stderr and stderr ~= "" then
        appendErrorLog("streaming stderr: " .. stderr:sub(1, 200))
      end
      -- 回傳 true 表示繼續接收
      return true
    end,
    args
  )

  if streamTask:start() then
    playSound(SOUND_REC_START)
    -- [R6] 成功啟動，重置失敗計數
    streamingFailCount = 0
  else
    streamTask = nil
    recordStartAt = nil
    -- [R6] Fallback 到傳統模式（漸進式降級）
    currentState = STATE.IDLE
    local switched = handleStreamingFailure("whisper.cpp --stream failed to start")
    -- 僅在未達閾值永久切換時，才 fallback 本次到傳統模式
    -- 若已永久切換，使用者已看到降級 alert，不再自動啟動錄音
    -- （避免 keyUp 已過導致錄音啟動後無人停止的 race condition）
    if not switched then
      startRecording()
    end
  end
end

--- 停止 streaming，處理累積文字，貼上
local function stopStreaming()
  if currentState ~= STATE.STREAMING then return end
  local sid = sessionCounter

  local duration = recordStartAt
                   and (hs.timer.secondsSinceEpoch() - recordStartAt) or 0
  recordStartAt = nil

  -- 終止 whisper.cpp --stream
  -- 設 streamTask = nil 使 termination callback 跳過後續處理
  -- （正常停止由本函式 stopStreaming 接管；termination callback 僅處理非預期終止）
  if streamTask then
    killTask(streamTask)
    streamTask = nil
  end
  playSound(SOUND_REC_STOP)

  if duration < MIN_RECORD_SEC then
    currentState = STATE.IDLE
    streamAccumulator = ""
    updateMenubar("🎤", string.format(
      "PTT Whisper v%s — 誤觸忽略（%.2fs）", VERSION, duration))
    return
  end

  -- 給 whisper.cpp 一點時間 flush 最後的輸出
  hs.timer.doAfter(0.15, function()
    if sid ~= sessionCounter then
      streamAccumulator = ""
      return
    end

    -- 清理 + 過濾 streaming 輸出
    local rawOutput = streamAccumulator
    streamAccumulator = ""

    local text = cleanStreamOutput(rawOutput)
    text = filterHallucinations(text)

    appendErrorLog(string.format(
      "streaming: duration=%.1fs raw_len=%d result_len=%d",
      duration, #rawOutput, #text))

    if text == "" then
      abortToIdle("Ready", { alert = "🤔 未偵測到語音", icon = "🎤" })
      return
    end

    -- 進入 PASTING
    currentState = STATE.PASTING
    updateMenubar("📋", "PTT Whisper — Pasting...")
    local savedClipboard = saveClipboard()
    local previewTooltip = nil
    if SHOW_PREVIEW_ALERT then
      local preview, truncated = utf8Sub(text, 20)
      hs.alert.show("✅ " .. preview .. (truncated and "…" or ""), 2)
    else
      local preview, truncated = utf8Sub(text, 30)
      previewTooltip = "✅ " .. preview .. (truncated and "…" or "")
    end
    pasteText(text, savedClipboard, sid, previewTooltip)
  end)
end

-- ── [F7] 健康檢查 / 自我診斷 ───────────────────────────────

local function runDiagnostics()
  local results = {}
  local allOk = true

  local function check(name, fn)
    local ok, result = pcall(fn)
    if not ok then
      table.insert(results, string.format("❌ %s — ERROR: %s", name, tostring(result)))
      allOk = false
    elseif result == true then
      table.insert(results, string.format("✅ %s", name))
    elseif type(result) == "string" then
      -- result 是警告或資訊
      if result:sub(1, 1) == "!" then
        table.insert(results, string.format("⚠️ %s — %s", name, result:sub(2)))
        allOk = false
      else
        table.insert(results, string.format("✅ %s — %s", name, result))
      end
    else
      table.insert(results, string.format("❌ %s — FAILED", name))
      allOk = false
    end
  end

  -- 1. ffmpeg
  check("ffmpeg", function()
    local path = findFFmpeg()
    if not path then return "!找不到 ffmpeg — brew install ffmpeg" end
    local ver = hs.execute(string.format([["%s" -version 2>&1 | head -1]], path))
    return (ver or ""):gsub("%s+$", "")
  end)

  -- 2. ffprobe
  check("ffprobe", function()
    local found = hs.execute("which ffprobe 2>/dev/null"):gsub("%s+$", "")
    if found == "" then return "!找不到 ffprobe（通常與 ffmpeg 一起安裝）" end
    return found
  end)

  -- 3. whisper.cpp
  check("whisper.cpp", function()
    local path = findWhisperBin()
    if not path then return "!找不到 whisper.cpp — 請檢查 ~/whisper.cpp/" end
    -- 測試 --help 是否能正常執行
    local output = hs.execute(string.format([["%s" --help 2>&1 | head -1]], path))
    return path .. " — " .. ((output or ""):gsub("%s+$", ""))
  end)

  -- 4. whisper.cpp --stream 支援
  check("--stream 支援", function()
    local path = findWhisperBin()
    if not path then return "!whisper.cpp 未安裝" end
    local helpText = hs.execute(string.format([["%s" --help 2>&1]], path))
    if helpText and helpText:find("%-%-stream") then
      return "支援"
    else
      return "!此 build 不支援 --stream"
    end
  end)

  -- 5. Model 檔案
  check("Model 檔案", function()
    local modelPath = resolveModelPath(nil)
    if not modelPath then return "!預設 model 不存在" end
    local attr = hs.fs.attributes(modelPath)
    local sizeMB = attr and math.floor((attr.size or 0) / 1024 / 1024) or 0
    return string.format("%s (%dMB)", modelPath, sizeMB)
  end)

  -- 6. Fallback model
  if FALLBACK_MODEL ~= "" then
    check("Fallback Model", function()
      local path = resolveModelPath(FALLBACK_MODEL)
      if not path then return "!" .. FALLBACK_MODEL .. " 不存在" end
      return path
    end)
  end

  -- 7. transcribe.sh
  check("transcribe.sh", function()
    local ok, err = isTranscribeScriptReady()
    if not ok then return "!" .. err end
    -- 讀取版本（從檔案頭取）
    local f = io.open(TRANSCRIBE_SH, "r")
    if f then
      local line1 = f:read("*l"); local line2 = f:read("*l")
      local line3 = f:read("*l")
      f:close()
      if line3 and line3:match("v%d+%.%d+") then
        return line3:match("(transcribe%.sh%s+v[%d%.]+)")
              or TRANSCRIBE_SH
      end
    end
    return TRANSCRIBE_SH
  end)

  -- 8. 麥克風權限
  check("麥克風權限", function()
    local ffmpeg = findFFmpeg()
    if not ffmpeg then return "!無法測試（ffmpeg 不存在）" end
    -- 嘗試短暫錄音測試權限
    local testFile = PTT_DIR .. "/diag_test.wav"
    local cmd = string.format(
      [["%s" -y -f avfoundation -i %s -ac 1 -ar 16000 -t 0.1 "%s" 2>&1]],
      ffmpeg, AUDIO_DEVICE, testFile)
    local output, status = hs.execute(cmd)
    os.remove(testFile)
    if status then return "正常" end
    if output and output:find("[Pp]ermission") then
      return "!麥克風權限被拒絕 — 請在 系統設定 → 隱私權 中允許 Hammerspoon"
    end
    return "!測試失敗 — " .. (output or ""):sub(1, 80)
  end)

  -- 9. 磁碟空間
  check("磁碟空間", function()
    local output = hs.execute([[df -h ~ | tail -1 | awk '{print $4}']])
    local avail = (output or ""):gsub("%s+$", "")
    if avail == "" then return "!無法取得" end
    return avail .. " 可用"
  end)

  -- 10. PTT_DIR 權限
  check("PTT_DIR 權限", function()
    local attr = hs.fs.attributes(PTT_DIR)
    if not attr then return "!" .. PTT_DIR .. " 不存在" end
    return PTT_DIR .. " — " .. (attr.permissions or "unknown")
  end)

  -- 11. timeout 指令
  check("timeout 指令", function()
    local gt = hs.execute("which gtimeout 2>/dev/null"):gsub("%s+$", "")
    if gt ~= "" then return "gtimeout — " .. gt end
    local t = hs.execute("which timeout 2>/dev/null"):gsub("%s+$", "")
    if t ~= "" then return "timeout — " .. t end
    return "!找不到 — brew install coreutils"
  end)

  -- 組裝報告
  local header = string.format(
    "=== PTT Whisper v%s Diagnostics ===\n%s\nMode: %s",
    VERSION, os.date("%Y-%m-%d %H:%M:%S"),
    STREAMING_MODE and "Streaming" or "Traditional")

  local report = header .. "\n\n" .. table.concat(results, "\n")
  local status = allOk and "\n\n🎉 所有檢查通過！" or "\n\n⚠️ 部分項目需要處理"
  report = report .. status

  -- 寫入 console + 檔案
  print(report)
  local diagFile = PTT_DIR .. "/diagnostics.txt"
  local f = io.open(diagFile, "w")
  if f then f:write(report .. "\n"); f:close() end

  -- 顯示摘要 alert
  local failCount = 0
  for _, r in ipairs(results) do
    if r:match("^❌") or r:match("^⚠") then failCount = failCount + 1 end
  end

  if failCount == 0 then
    hs.alert.show("🎉 所有 " .. #results .. " 項檢查通過！\n詳見 Console", 3)
  else
    hs.alert.show("⚠️ " .. failCount .. "/" .. #results
                  .. " 項需要處理\n詳見 Console 或 diagnostics.txt", 4)
  end

  return report
end

PTTWhisper.runDiagnostics = runDiagnostics

-- ── Cleanup ─────────────────────────────────────────────────
local function cleanup()
  if recordTask then pcall(function() recordTask:terminate() end) end
  if transcribeTask then pcall(function() transcribeTask:terminate() end) end
  if streamTask then pcall(function() streamTask:terminate() end) end
  recordTask     = nil
  transcribeTask = nil
  streamTask     = nil
  currentState   = STATE.IDLE
  recordStartAt  = nil
  streamAccumulator = ""
  streamingFailCount = 0
  os.remove(RECORD_FILE)
  if menubarItem then menubarItem:delete(); menubarItem = nil end
end

PTTWhisper._cleanup = cleanup

local previousShutdownCallback = hs.shutdownCallback
hs.shutdownCallback = function()
  cleanup()
  if previousShutdownCallback then previousShutdownCallback() end
end

-- ── 主入口：根據模式分發 ────────────────────────────────────
local function onKeyDown()
  if STREAMING_MODE then
    startStreaming()
  else
    startRecording()
  end
end

local function onKeyUp()
  if currentState == STATE.STREAMING then
    stopStreaming()
  elseif currentState == STATE.RECORDING then
    stopRecordingAndTranscribe()
  end
end

-- ── Menubar 選單 ────────────────────────────────────────────
local hotkeyLabel = (#HOTKEY_MODS > 0)
                    and (table.concat(HOTKEY_MODS, "+") .. "+" .. HOTKEY_KEY)
                    or  HOTKEY_KEY

local function langModelMenuLabel()
  local count = 0
  for _ in pairs(LANG_MODELS) do count = count + 1 end
  if count == 0 then return "語言切換：未設定" end
  local dflt = LANG_MODELS["_default"]
  local dfltLabel = dflt and ("預設=" .. (dflt.lang or "auto")) or "無預設"
  return string.format("語言切換：%d 規則（%s）", count, dfltLabel)
end

if menubarItem then
  menubarItem:setTitle("🎤")
  menubarItem:setTooltip("PTT Whisper v" .. VERSION .. " — Ready")
  menubarItem:setMenu(function()
    return {
      { title = "PTT Whisper v" .. VERSION, disabled = true },
      { title = "-" },
      { title = "狀態：" .. currentState, disabled = true },
      { title = "模式：" .. (STREAMING_MODE and "⚡ Streaming" or "📼 Traditional"),
        disabled = true },
      { title = "Session：#" .. sessionCounter, disabled = true },
      { title = "裝置：" .. AUDIO_DEVICE, disabled = true },
      { title = "熱鍵：" .. hotkeyLabel, disabled = true },
      { title = "快取：" .. (CACHE_ENABLED and "ON" or "OFF"), disabled = true },
      { title = "Fallback：" .. (FALLBACK_MODEL ~= "" and FALLBACK_MODEL or "無"),
        disabled = true },
      { title = langModelMenuLabel(), disabled = true },
      { title = "-" },
      -- [F7] 診斷
      { title = "🔍 Run Diagnostics", fn = function()
          runDiagnostics()
        end
      },
      { title = "-" },
      { title = "列出音訊裝置（Console）", fn = function()
          listAudioDevices()
          hs.alert.show("裝置列表已輸出至 Console", 2)
        end
      },
      { title = "打開 Error Log", fn = function()
          hs.execute(string.format([[open "%s" 2>/dev/null]], LOG_FILE))
        end
      },
      { title = "打開設定檔", fn = function()
          if not hs.fs.attributes(CONFIG_FILE) then
            local f = io.open(CONFIG_FILE, "w")
            if f then
              f:write('{\n')
              f:write('  "slow_paste_apps": {},\n')
              f:write('  "show_preview_alert": true,\n')
              f:write('  "streaming_mode": false,\n')
              f:write('  "cache_enabled": false,\n')
              f:write('  "fallback_model": "",\n')
              f:write('  "lang_models": {\n')
              f:write('    "_default": { "lang": "auto" }\n')
              f:write('  }\n')
              f:write('}\n')
              f:close()
            end
          end
          hs.execute(string.format([[open "%s" 2>/dev/null]], CONFIG_FILE))
        end
      },
      { title = "打開幻覺過濾列表", fn = function()
          local hallFile = PTT_DIR .. "/hallucinations.txt"
          if not hs.fs.attributes(hallFile) then
            local f = io.open(hallFile, "w")
            if f then
              f:write("# PTT Whisper 幻覺過濾列表（一行一句，# = 註解）\n")
              f:close()
            end
          end
          hs.execute(string.format([[open "%s" 2>/dev/null]], hallFile))
        end
      },
      { title = "-" },
      { title = "Reload Hammerspoon", fn = function()
          cleanup()
          hs.reload()
        end
      },
    }
  end)
end

-- ── 熱鍵綁定 ────────────────────────────────────────────────
hs.hotkey.bind(HOTKEY_MODS, HOTKEY_KEY, onKeyDown, onKeyUp)

-- ── 啟動提示 ────────────────────────────────────────────────
local modeLabel = STREAMING_MODE and "⚡Streaming" or "📼Traditional"
hs.alert.show(string.format(
  "🎤 PTT Whisper v%s 已載入\n%s — 按住 %s 開始錄音",
  VERSION, modeLabel, hotkeyLabel), 2)
print(string.format(
  "PTT Whisper v%s loaded [%s] — run PTTWhisper.runDiagnostics() for health check",
  VERSION, modeLabel))
