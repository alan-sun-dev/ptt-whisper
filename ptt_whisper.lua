-- ============================================================
-- Push-to-Talk Whisper Dictation for Hammerspoon
-- v3.6.4
--
-- v3.6.4 修正（第四輪 Code Review）：
--   CR12.[Fix]  loadExternalConfig 結構化回傳（區分無檔/空檔/解析失敗）
--   CR13.[Fix]  streamingFailCount 改為漸進式衰減（成功 -1，非歸零）
--   CR14.[Feat] Diagnostics 區分 Q5_0 / FP16 模型標籤
--   CR15.[Feat] Diagnostics 新增濾波器鏈 dry-run 驗證
--
-- v3.6.3：CR7~CR11（第三輪 Code Review）
-- v3.6.2：OPT1~OPT2（錄音品質 + 推理效能優化）
-- v3.6.1：CR1~CR6（第二輪 Code Review）
--
-- v3.6.0：P1~P6  v3.5.1：R6~R10  v3.5.0：F4~F7
-- v3.4.1：R2,R4  v3.4.0：F1~F3  v3.3.5：ZP~ZT
-- v3.3.4：ZM~ZO  v3.3.3：ZI~ZL  v3.3.2：ZC~ZH
-- v3.3.1：ZA~ZB  v3.3：Z1~Z9  v3.2：Q~Y  v3.1：L~P
-- v3.0：E~K  v2.1：A~D
--
-- 使用方式：按住 Right Option 錄音，放開後自動轉錄並貼上
-- 依賴：ffmpeg、whisper.cpp 已編譯、~/ptt-whisper/transcribe.sh v2.8.4+
-- ============================================================

-- ── 版本常數 ────────────────────────────────────────────────
local VERSION = "3.6.4"

-- ── 設定區（Config）──────────────────────────────────────────

-- 路徑
local PTT_DIR           = os.getenv("HOME") .. "/.ptt-whisper"
local RECORD_FILE       = PTT_DIR .. "/ptt_record.wav"
local LOG_FILE          = PTT_DIR .. "/ptt_whisper_err.log"
local TRANSCRIBE_SH     = os.getenv("HOME") .. "/ptt-whisper/transcribe.sh"
local CONFIG_FILE       = PTT_DIR .. "/config.json"

-- [P1] 共用幻覺列表路徑（Lua 與 Bash 端皆從此檔案載入）
local BUILTIN_HALLUCINATION_FILE = PTT_DIR .. "/hallucinations_builtin.txt"

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

-- [OPT1] 錄音聲學濾波器鏈（FFmpeg -af 參數）
-- highpass=f=200  : 切除 200Hz 以下環境低頻噪音（冷氣、馬路隆隆聲）
-- lowpass=f=5000  : 切除 5kHz 以上高頻嘶聲（電路雜音、風扇）
--                   保留 4~5kHz 齒擦音頻帶（/s/, /ʃ/, /f/），避免英文辨識劣化
-- loudnorm=I=-16:TP=-1.5 : EBU R128 感知響度正規化（防止忽大忽小）
--   注意：loudnorm 在即時錄音（single-pass）模式下僅做近似正規化，
--   對 PTT 的短音訊（2~15s）已足夠，但不等同於雙 pass 的精確結果
-- 設為 "" 可停用濾波器；config.json 可透過 audio_filter_chain 覆寫
local AUDIO_FILTER_CHAIN = "highpass=f=200,lowpass=f=5000,loudnorm=I=-16:TP=-1.5"

-- UI
local SHOW_PREVIEW_ALERT = true

-- 貼上延遲（單位：秒，有效範圍 0 < delay <= 10）
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
local STREAMING_MODE     = false
local STREAMING_STEP_MS  = 500     -- 每次處理的步長（ms），有效範圍 100~10000
local STREAMING_LENGTH_MS = 5000   -- 每次處理的音訊窗口長度（ms），有效範圍 1000~30000

-- ── [F4] 快取設定 ────────────────────────────────────────────
local CACHE_ENABLED = false

-- ── [F6] Fallback Model ─────────────────────────────────────
local FALLBACK_MODEL = ""

-- ── [R6] Streaming fallback 漸進式降級 ──────────────────────
local STREAMING_FALLBACK_THRESHOLD = 3

-- ── [P2] Streaming 累積上限（bytes）─────────────────────────
local STREAM_ACCUMULATOR_MAX_BYTES = 65536  -- 64KB

-- ── [P6] Whisper binary 搜尋路徑（與 transcribe.sh 保持一致）──
local WHISPER_BIN_CANDIDATES = {
  "/whisper-cli",
  "/build/bin/whisper-cli",
  "/main",
  "/build/bin/main",
}

-- ── [CR3] Config 已知欄位白名單 ─────────────────────────────
local CONFIG_KNOWN_KEYS = {
  slow_paste_apps = true,
  show_preview_alert = true,
  streaming_mode = true,
  streaming_step_ms = true,
  streaming_length_ms = true,
  cache_enabled = true,
  fallback_model = true,
  lang_models = true,
  audio_filter_chain = true,
}

-- ── [CR3] Config 驗證：集中處理型別、範圍、預設值 ────────────
--- 取代散落在 loadExternalConfig 各處的 if-else 驗證邏輯
--- @param config table  已解析的 JSON config
--- @return table  { warnings = string[] }
local function validateConfig(config)
  local warnings = {}
  local function warn(msg)
    table.insert(warnings, msg)
    print("[PTT Whisper] WARNING: " .. msg)
  end

  -- Unknown keys
  for key, _ in pairs(config) do
    if not CONFIG_KNOWN_KEYS[key] then
      warn(string.format("unknown config key '%s' (ignored)", key))
    end
  end

  -- slow_paste_apps: table of { bundleID: delay_seconds }
  -- 單位：秒，有效範圍 0 < delay <= 10
  if config.slow_paste_apps ~= nil then
    if type(config.slow_paste_apps) ~= "table" then
      warn("slow_paste_apps: expected table, got " .. type(config.slow_paste_apps))
    else
      for bid, delay in pairs(config.slow_paste_apps) do
        if type(bid) == "string" and type(delay) == "number" then
          if delay > 0 and delay <= 10 then
            SLOW_PASTE_APPS[bid] = delay
          else
            warn(string.format("slow_paste_apps[%s]=%.1f out of range (0<x<=10 sec)", bid, delay))
          end
        end
      end
    end
  end

  -- show_preview_alert: boolean
  if config.show_preview_alert ~= nil then
    if type(config.show_preview_alert) == "boolean" then
      SHOW_PREVIEW_ALERT = config.show_preview_alert
    else
      warn("show_preview_alert: expected boolean")
    end
  end

  -- lang_models: table of { bundleID: { lang?, model? } }
  if config.lang_models ~= nil then
    if type(config.lang_models) ~= "table" then
      warn("lang_models: expected table")
    else
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
  end

  -- streaming_mode: boolean
  if config.streaming_mode ~= nil then
    if type(config.streaming_mode) == "boolean" then
      STREAMING_MODE = config.streaming_mode
    else
      warn("streaming_mode: expected boolean")
    end
  end

  -- streaming_step_ms: number, 100~10000 (ms)
  if config.streaming_step_ms ~= nil then
    if type(config.streaming_step_ms) == "number"
       and config.streaming_step_ms >= 100
       and config.streaming_step_ms <= 10000 then
      STREAMING_STEP_MS = config.streaming_step_ms
    elseif type(config.streaming_step_ms) == "number" then
      warn("streaming_step_ms out of range (100~10000 ms)")
    end
  end

  -- streaming_length_ms: number, 1000~30000 (ms)
  if config.streaming_length_ms ~= nil then
    if type(config.streaming_length_ms) == "number"
       and config.streaming_length_ms >= 1000
       and config.streaming_length_ms <= 30000 then
      STREAMING_LENGTH_MS = config.streaming_length_ms
    elseif type(config.streaming_length_ms) == "number" then
      warn("streaming_length_ms out of range (1000~30000 ms)")
    end
  end

  -- cache_enabled: boolean
  if config.cache_enabled ~= nil then
    if type(config.cache_enabled) == "boolean" then
      CACHE_ENABLED = config.cache_enabled
    else
      warn("cache_enabled: expected boolean")
    end
  end

  -- fallback_model: string (filename or absolute path)
  if config.fallback_model ~= nil then
    if type(config.fallback_model) == "string" then
      FALLBACK_MODEL = config.fallback_model
    else
      warn("fallback_model: expected string")
    end
  end

  -- [OPT1] audio_filter_chain: string (FFmpeg -af 參數，"" = 停用)
  if config.audio_filter_chain ~= nil then
    if type(config.audio_filter_chain) == "string" then
      AUDIO_FILTER_CHAIN = config.audio_filter_chain
      if config.audio_filter_chain == "" then
        print("[PTT Whisper] INFO: audio_filter_chain disabled by config")
      end
    else
      warn("audio_filter_chain: expected string")
    end
  end

  return { warnings = warnings }
end

-- ── [CR7] 工作目錄初始化（必須在 loadExternalConfig 之前）──────
-- 確保 PTT_DIR 存在，否則首次啟動時 config.json 位於不存在的目錄下無法讀取
hs.fs.mkdir(PTT_DIR)
hs.task.new("/bin/chmod", nil, {"700", PTT_DIR}):start()

-- ── 外部設定檔載入 ──────────────────────────────────────────
-- [CR12] 所有路徑都回傳結構化結果，讓 diagnostics 能區分：
--   nil              → config.json 不存在（正常，首次啟動）
--   { warnings = {"config.json 為空"} }         → 檔案存在但空
--   { warnings = {"config.json JSON 解析失敗"} } → JSON 格式錯誤
--   { warnings = {...} }                         → 正常載入（可能有欄位警告）
local function loadExternalConfig()
  local f = io.open(CONFIG_FILE, "r")
  if not f then return nil end
  local ok, content = pcall(function() return f:read("*a") end)
  f:close()
  if not ok or not content or content == "" then
    if not ok then
      print("[PTT Whisper] WARNING: config.json read error")
      return { warnings = {"config.json 讀取失敗"} }
    end
    return { warnings = {"config.json 為空"} }
  end

  local decodeOk, config = pcall(hs.json.decode, content)
  if not decodeOk or type(config) ~= "table" then
    print("[PTT Whisper] WARNING: config.json parse failed, ignoring")
    return { warnings = {"config.json JSON 解析失敗，已忽略"} }
  end

  -- [CR3] 使用集中式驗證取代散落的 if-else
  -- [CR10] 儲存 warnings 供 diagnostics 使用
  local result = validateConfig(config)
  return result
end

-- [CR10] 儲存最近一次 config 驗證結果
local lastConfigValidation = nil

lastConfigValidation = loadExternalConfig()

-- ── Reload 防護 ─────────────────────────────────────────────
if PTTWhisper and PTTWhisper._cleanup then
  PTTWhisper._cleanup()
end

-- ── 狀態機 ───────────────────────────────────────────────────
local STATE = {
  IDLE         = "idle",
  RECORDING    = "recording",
  TRANSCRIBING = "transcribing",
  STREAMING    = "streaming",
  PASTING      = "pasting",
}
local currentState = STATE.IDLE
local sessionCounter = 0

-- 模組級引用
local recordTask       = nil
local transcribeTask   = nil
local streamTask       = nil
local recordStartAt    = nil
local cachedFFmpegPath = nil
local streamChunks     = {}
local streamChunksSize = 0
local killFallbackTimer = nil
local streamingFailCount = 0
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

-- ── [CR1] 外部命令統一 helper ───────────────────────────────
-- 所有「跑外部命令」的需求統一經由這兩個函式，
-- 不再直接使用 hs.execute + string.format 組裝 shell 字串。
-- 好處：
--   1. 每個參數獨立 shell-escape（single-quote 包裝），杜絕 injection
--   2. 新增功能時不會漏掉某個角落又回到裸 hs.execute
--   3. 方便未來做全域 mock / 測試

--- Shell-escape 單一參數
--- @param s string
--- @return string  single-quoted escaped string
local function shellEscape(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

--- 同步執行外部命令
--- @param bin string  執行檔路徑
--- @param args table|nil  參數陣列
--- @param opts table|nil  { stderr = bool（合併 stderr 到 stdout）}
--- @return string output, boolean status
local function runCommandSync(bin, args, opts)
  opts = opts or {}
  local parts = { shellEscape(bin) }
  for _, arg in ipairs(args or {}) do
    table.insert(parts, shellEscape(arg))
  end
  local cmd = table.concat(parts, " ")
  if opts.stderr then cmd = cmd .. " 2>&1" end
  return hs.execute(cmd)
end

--- 非同步執行外部命令（fire-and-forget 或帶 callback）
--- @param bin string  執行檔路徑
--- @param args table|nil  參數陣列
--- @param callback function|nil  function(exitCode, stdout, stderr)
--- @return hs.task|nil
local function runCommandAsync(bin, args, callback)
  local task = hs.task.new(bin, callback, args or {})
  if task:start() then return task end
  return nil
end

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

--- [CR1] 取得 ffmpeg 路徑
local function findFFmpeg()
  if cachedFFmpegPath then return cachedFFmpegPath end
  for _, path in ipairs({
    "/opt/homebrew/bin/ffmpeg",
    "/usr/local/bin/ffmpeg",
    "/usr/bin/ffmpeg",
  }) do
    if hs.fs.attributes(path) then cachedFFmpegPath = path; return path end
  end
  -- [CR1] fallback: which（經由 runCommandSync 安全包裝）
  local found = runCommandSync("/usr/bin/which", {"ffmpeg"}, {stderr = true})
  found = (found or ""):gsub("%s+$", "")
  if found ~= "" and found:sub(1, 1) == "/" then
    cachedFFmpegPath = found; return found
  end
  return nil
end

--- [P6] 取得 whisper.cpp 二進位路徑
local cachedWhisperBin = nil
local function findWhisperBin()
  if cachedWhisperBin then return cachedWhisperBin end
  local whisperDir = os.getenv("WHISPER_DIR")
                     or (os.getenv("HOME") .. "/whisper.cpp")
  for _, rel in ipairs(WHISPER_BIN_CANDIDATES) do
    local path = whisperDir .. rel
    if hs.fs.attributes(path) then
      cachedWhisperBin = path
      return path
    end
  end
  return nil
end

--- 解析 model 路徑
--- [OPT2] 預設優先使用 Q5_0 量化版（速度 2~3x, RAM -50%, 準確率幾乎無損）
---        若 Q5_0 不存在則自動 fallback 到原始 FP16 版本
local function resolveModelPath(modelName)
  local whisperDir = os.getenv("WHISPER_DIR")
                     or (os.getenv("HOME") .. "/whisper.cpp")
  local path
  if not modelName or modelName == "" then
    -- 優先使用 env var
    local envModel = os.getenv("WHISPER_MODEL")
    if envModel then
      path = envModel
    else
      -- [OPT2] 優先 Q5_0，fallback 到 FP16
      local q5Path = whisperDir .. "/models/ggml-small-q5_0.bin"
      local fpPath = whisperDir .. "/models/ggml-small.bin"
      if hs.fs.attributes(q5Path) then
        path = q5Path
      else
        path = fpPath
      end
    end
  elseif modelName:sub(1, 1) == "/" then
    path = modelName
  else
    path = whisperDir .. "/models/" .. modelName
  end
  if hs.fs.attributes(path) then return path end
  return nil
end

--- [CR1] 列出音訊裝置（改用 runCommandSync，不再拼 shell 字串）
local function listAudioDevices()
  local ffmpeg = findFFmpeg()
  if not ffmpeg then print("❌ ffmpeg not found"); return end
  local output = runCommandSync(ffmpeg,
    {"-f", "avfoundation", "-list_devices", "true", "-i", ""},
    {stderr = true})
  print("=== AVFoundation Audio Devices ===")
  print(output or "(no output)")
  print("==================================")
end

PTTWhisper.findFFmpeg       = findFFmpeg
PTTWhisper.findWhisperBin   = findWhisperBin
PTTWhisper.resolveModelPath = resolveModelPath
PTTWhisper.listAudioDevices = listAudioDevices

--- [P3] 安全終止 task
local function killTask(task)
  if not task then return end
  pcall(function()
    if task:isRunning() then
      task:interrupt()
      killFallbackTimer = hs.timer.doAfter(KILL_FALLBACK_SEC, function()
        killFallbackTimer = nil
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

--- [P3] 取消 killTask 的 SIGTERM fallback timer
local function cancelKillFallbackTimer()
  if killFallbackTimer then
    killFallbackTimer:stop()
    killFallbackTimer = nil
  end
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

-- ── [CR2] 幻覺過濾：兩層比對（exact → normalized）──────────

local hallucinationSet = {}       -- exact match set
local hallucinationNormSet = {}   -- normalized match set

--- [CR2] Normalize 文字以進行模糊幻覺比對
--- 策略：trim → 壓連續空白 → 全形標點轉半形 → 移除尾部標點
--- 設計原則：足夠寬鬆以捕捉 "Thanks ." / "謝謝。" 等變體，
---           但不過度激進以至於誤殺合法語句
--- @param text string
--- @return string  normalized text（lowercase）
local function normalizeForMatch(text)
  if not text or text == "" then return "" end
  -- trim
  text = text:match("^%s*(.-)%s*$")
  -- 壓連續空白為單一空白
  text = text:gsub("%s+", " ")
  -- 全形標點 → 半形
  local fullToHalf = {
    ["。"] = ".", ["！"] = "!", ["？"] = "?",
    ["，"] = ",", ["；"] = ";", ["："] = ":",
    ["、"] = ",",
    ["（"] = "(", ["）"] = ")",
    -- 全形空白 U+3000
    ["\xe3\x80\x80"] = " ",
  }
  for full, half in pairs(fullToHalf) do
    text = text:gsub(full, half)
  end
  -- 移除尾部半形標點
  text = text:gsub("[%.!?,;:]+$", "")
  -- 再次 trim
  text = text:match("^%s*(.-)%s*$")
  -- lowercase（讓 "THANK YOU" 也能匹配）
  text = text:lower()
  return text
end

--- 從檔案載入幻覺列表（同時建立 exact 和 normalized 兩份 set）
--- @param path string
--- @return number  載入的條目數
local function loadHallucinationsFromFile(path)
  local f = io.open(path, "r")
  if not f then return 0 end
  local count = 0
  for line in f:lines() do
    line = line:match("^%s*(.-)%s*$")  -- trim
    if line ~= "" and line:sub(1, 1) ~= "#" then
      -- 第一層：原始文字精確比對
      hallucinationSet[line] = true
      -- 第二層：normalized 比對
      local norm = normalizeForMatch(line)
      if norm ~= "" then
        hallucinationNormSet[norm] = true
      end
      count = count + 1
    end
  end
  f:close()
  return count
end

-- 載入共用內建幻覺列表
local builtinCount = loadHallucinationsFromFile(BUILTIN_HALLUCINATION_FILE)
if builtinCount == 0 then
  appendErrorLog("WARNING: hallucinations_builtin.txt not found or empty, using hardcoded fallback")
  local fallbackList = {
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
  for _, h in ipairs(fallbackList) do
    hallucinationSet[h] = true
    local norm = normalizeForMatch(h)
    if norm ~= "" then hallucinationNormSet[norm] = true end
  end
end

-- 載入使用者自定義幻覺列表
loadHallucinationsFromFile(PTT_DIR .. "/hallucinations.txt")

--- [CR2] 幻覺過濾（兩層比對）
--- 第一層：exact match（零誤殺）
--- 第二層：normalized match（捕捉標點/空白/大小寫/全半形變體）
--- @param text string
--- @return string  過濾後文字（空字串 = 幻覺）
local function filterHallucinations(text)
  if not text or text == "" then return "" end
  text = text:match("^%s*(.-)%s*$")
  if text == "" then return "" end
  -- 第一層：精確匹配
  if hallucinationSet[text] then return "" end
  -- 第二層：normalized 匹配
  local norm = normalizeForMatch(text)
  if norm ~= "" and hallucinationNormSet[norm] then return "" end
  -- 純標點檢查
  local stripped = text:gsub("[%p%s]", "")
  if stripped == "" then return "" end
  return text
end

-- [CR5] 匯出供外部測試使用
PTTWhisper.normalizeForMatch    = normalizeForMatch
PTTWhisper.filterHallucinations = filterHallucinations

--- [F5][R8] 清理 whisper.cpp --stream 的輸出
local function cleanStreamOutput(raw)
  if not raw or raw == "" then return "" end
  local cleaned = raw:gsub("\27%[[%d;]*[A-Za-z]", "")
  cleaned = cleaned:gsub("\r", "\n")
  cleaned = cleaned:gsub("%[%d+:%d+:%d+%.%d+%s*%-%->%s*%d+:%d+:%d+%.%d+%]", "")
  cleaned = cleaned:gsub("%[BLANK_AUDIO%]", "")
  cleaned = cleaned:gsub("%[[Ss]ilence%]", "")
  cleaned = cleaned:gsub("%[[Mm]usic%]", "")

  local lines = {}
  for line in cleaned:gmatch("[^\n]+") do
    local trimmed = line:match("^%s*(.-)%s*$")
    if trimmed ~= "" then table.insert(lines, trimmed) end
  end
  if #lines == 0 then return "" end

  local unique = {}
  for _, line in ipairs(lines) do
    if line ~= unique[#unique] then table.insert(unique, line) end
  end
  return table.concat(unique, " ")
end

-- ── [P2] Streaming 累積器 ───────────────────────────────────
local function resetStreamAccumulator()
  streamChunks = {}
  streamChunksSize = 0
end

local function appendStreamChunk(data)
  if not data or data == "" then return true end
  local dataLen = #data
  if streamChunksSize + dataLen > STREAM_ACCUMULATOR_MAX_BYTES then
    if streamChunksSize < STREAM_ACCUMULATOR_MAX_BYTES then
      appendErrorLog(string.format(
        "streaming: accumulator reached limit (%d bytes), discarding further output",
        STREAM_ACCUMULATOR_MAX_BYTES))
    end
    return false
  end
  table.insert(streamChunks, data)
  streamChunksSize = streamChunksSize + dataLen
  return true
end

local function flushStreamAccumulator()
  local result = table.concat(streamChunks)
  resetStreamAccumulator()
  return result
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

  -- [OPT1] 組裝 ffmpeg 錄音參數（含可選的聲學濾波器鏈）
  local recordArgs = { "-y", "-f", "avfoundation", "-i", AUDIO_DEVICE }
  if AUDIO_FILTER_CHAIN ~= "" then
    table.insert(recordArgs, "-af")
    table.insert(recordArgs, AUDIO_FILTER_CHAIN)
  end
  for _, v in ipairs({ "-ac", "1", "-ar", "16000", RECORD_FILE }) do
    table.insert(recordArgs, v)
  end

  recordTask = hs.task.new(ffmpeg, function(exitCode, _, stderr)
    cancelKillFallbackTimer()
    -- [CR11] FFmpeg 收到 SIGINT（正常終止錄音）時在 macOS 回傳 255，
    -- 這是預期行為而非錯誤，因此 255 與 0 一樣不觸發錯誤處理。
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
  end, recordArgs)

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

    -- [CR1] 使用 runCommandAsync
    runCommandAsync("/bin/chmod", {"600", RECORD_FILE})

    local taskArgs = { TRANSCRIBE_SH, RECORD_FILE }
    if langOverride or modelOverride then
      table.insert(taskArgs, langOverride or "")
      table.insert(taskArgs, modelOverride or "")
    end

    local env = {
      PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
      HOME = os.getenv("HOME"),
    }
    if CACHE_ENABLED then env.WHISPER_CACHE = "true" end
    if FALLBACK_MODEL ~= "" then env.WHISPER_FALLBACK_MODEL = FALLBACK_MODEL end
    for _, k in ipairs({"WHISPER_DIR", "WHISPER_MODEL", "WHISPER_LANG",
                        "WHISPER_TIMEOUT", "WHISPER_AUTO_RESAMPLE"}) do
      local v = os.getenv(k)
      if v then env[k] = v end
    end

    transcribeTask = hs.task.new("/bin/bash", function(exitCode, stdout, stderr)
      cancelKillFallbackTimer()
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

-- ── [R6] Streaming 降級 ─────────────────────────────────────
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

local function startStreaming()
  if currentState ~= STATE.IDLE then
    hs.alert.show("⚠️ 忙碌中，請稍候...", 1)
    return
  end

  local whisperBin = findWhisperBin()
  if not whisperBin then
    appendErrorLog("streaming: whisper.cpp not found, falling back")
    startRecording()
    return
  end

  local langOverride, modelOverride, appName = getLangModelForCurrentApp()
  local modelPath = resolveModelPath(modelOverride)
  if not modelPath then
    appendErrorLog("streaming: model not found, falling back")
    startRecording()
    return
  end

  sessionCounter = sessionCounter + 1
  local sid = sessionCounter
  resetStreamAccumulator()

  currentState  = STATE.STREAMING
  recordStartAt = hs.timer.secondsSinceEpoch()
  updateMenubar("🔴", "PTT Whisper — Streaming...")

  local args = {
    "--stream",
    "-m", modelPath,
    "-nt",
    "--step", tostring(STREAMING_STEP_MS),
    "--length", tostring(STREAMING_LENGTH_MS),
    "-nc",
  }
  if langOverride and langOverride ~= "" then
    table.insert(args, "-l")
    table.insert(args, langOverride)
  end

  appendErrorLog(string.format(
    "streaming: start app=%s lang=%s model=%s",
    appName, langOverride or "(auto)", modelPath))

  streamTask = hs.task.new(
    whisperBin,
    function(exitCode, stdout, stderr)
      cancelKillFallbackTimer()
      hs.timer.doAfter(0, function()
        if not streamTask then return end
        streamTask = nil
        if currentState == STATE.STREAMING and sid == sessionCounter then
          if streamChunksSize == 0 and exitCode ~= 0 and exitCode ~= 255 then
            currentState = STATE.IDLE
            handleStreamingFailure("unexpected exit=" .. tostring(exitCode))
          end
        end
      end)
    end,
    function(task, stdout, stderr)
      if stdout and stdout ~= "" then appendStreamChunk(stdout) end
      if stderr and stderr ~= "" then
        appendErrorLog("streaming stderr: " .. stderr:sub(1, 200))
      end
      return true
    end,
    args
  )

  if streamTask:start() then
    playSound(SOUND_REC_START)
    -- [CR9] streamingFailCount 不在此處重置——
    -- [CR13] 成功時改為漸進式衰減（見 stopStreaming），避免歸零繞過降級保護
  else
    streamTask = nil; recordStartAt = nil
    currentState = STATE.IDLE
    local switched = handleStreamingFailure("whisper.cpp --stream failed to start")
    if not switched then startRecording() end
  end
end

local function stopStreaming()
  if currentState ~= STATE.STREAMING then return end
  local sid = sessionCounter

  local duration = recordStartAt
                   and (hs.timer.secondsSinceEpoch() - recordStartAt) or 0
  recordStartAt = nil

  if streamTask then killTask(streamTask); streamTask = nil end
  playSound(SOUND_REC_STOP)

  if duration < MIN_RECORD_SEC then
    currentState = STATE.IDLE
    resetStreamAccumulator()
    updateMenubar("🎤", string.format(
      "PTT Whisper v%s — 誤觸忽略（%.2fs）", VERSION, duration))
    return
  end

  hs.timer.doAfter(0.15, function()
    if sid ~= sessionCounter then resetStreamAccumulator(); return end

    local rawOutput = flushStreamAccumulator()
    local text = cleanStreamOutput(rawOutput)
    text = filterHallucinations(text)

    appendErrorLog(string.format(
      "streaming: duration=%.1fs raw_len=%d result_len=%d",
      duration, #rawOutput, #text))

    if text == "" then
      abortToIdle("Ready", { alert = "🤔 未偵測到語音", icon = "🎤" })
      return
    end

    -- [CR13] Streaming 成功產出文字 → failCount 遞減 1（floor 0）
    -- 漸進式衰減：不會被單次成功歸零繞過降級保護，
    -- 但也不會讓偶發性的歷史失敗永久累積
    -- 範例：fail 2 → success 1 → fail 1 → count=2（不觸發降級）
    --       fail 2 → success 0 → fail 1 → count=3（觸發降級）
    if streamingFailCount > 0 then
      streamingFailCount = streamingFailCount - 1
      appendErrorLog(string.format(
        "streaming: success, failCount decayed to %d/%d",
        streamingFailCount, STREAMING_FALLBACK_THRESHOLD))
    end

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

-- ── [F7][CR1] 健康檢查 / 自我診斷 ──────────────────────────

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
    local ver = runCommandSync(path, {"-version"}, {stderr = true})
    local firstLine = (ver or ""):match("^([^\n]+)") or ""
    return firstLine:gsub("%s+$", "")
  end)

  -- 2. ffprobe
  check("ffprobe", function()
    local found = runCommandSync("/usr/bin/which", {"ffprobe"}, {stderr = true})
    found = (found or ""):gsub("%s+$", "")
    if found == "" or found:sub(1, 1) ~= "/" then
      return "!找不到 ffprobe（通常與 ffmpeg 一起安裝）"
    end
    return found
  end)

  -- 3. whisper.cpp
  check("whisper.cpp", function()
    local path = findWhisperBin()
    if not path then return "!找不到 whisper.cpp — 請檢查 ~/whisper.cpp/" end
    local output = runCommandSync(path, {"--help"}, {stderr = true})
    local firstLine = (output or ""):match("^([^\n]+)") or ""
    return path .. " — " .. firstLine:gsub("%s+$", "")
  end)

  -- 4. --stream 支援
  check("--stream 支援", function()
    local path = findWhisperBin()
    if not path then return "!whisper.cpp 未安裝" end
    local helpText = runCommandSync(path, {"--help"}, {stderr = true})
    if helpText and helpText:find("%-%-stream") then return "支援" end
    return "!此 build 不支援 --stream"
  end)

  -- 5. [CR14] Model 檔案（含 Q5_0/FP16 標籤）
  check("Model 檔案", function()
    local modelPath = resolveModelPath(nil)
    if not modelPath then return "!預設 model 不存在" end
    local attr = hs.fs.attributes(modelPath)
    local sizeMB = attr and math.floor((attr.size or 0) / 1024 / 1024) or 0
    -- [CR14] 標記模型類型，讓使用者一眼可辨是否正在使用量化版本
    local tag
    if modelPath:find("q5_0") then
      tag = "Q5_0"
    elseif modelPath:find("q5_1") then
      tag = "Q5_1"
    elseif modelPath:find("q8_0") then
      tag = "Q8_0"
    else
      tag = "FP16"
    end
    return string.format("%s (%dMB) [%s]", modelPath, sizeMB, tag)
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
    local f = io.open(TRANSCRIBE_SH, "r")
    if f then
      f:read("*l"); f:read("*l")
      local line3 = f:read("*l")
      f:close()
      if line3 and line3:match("v%d+%.%d+") then
        return line3:match("(transcribe%.sh%s+v[%d%.]+)") or TRANSCRIBE_SH
      end
    end
    return TRANSCRIBE_SH
  end)

  -- 8. 麥克風權限
  check("麥克風權限", function()
    local ffmpeg = findFFmpeg()
    if not ffmpeg then return "!無法測試（ffmpeg 不存在）" end
    local testFile = PTT_DIR .. "/diag_test.wav"
    local output = runCommandSync(ffmpeg,
      {"-y", "-f", "avfoundation", "-i", AUDIO_DEVICE,
       "-ac", "1", "-ar", "16000", "-t", "0.1", testFile},
      {stderr = true})
    local exists = hs.fs.attributes(testFile) ~= nil
    os.remove(testFile)
    if exists then return "正常" end
    if output and output:find("[Pp]ermission") then
      return "!麥克風權限被拒絕 — 請在 系統設定 → 隱私權 中允許 Hammerspoon"
    end
    return "!測試失敗 — " .. (output or ""):sub(1, 80)
  end)

  -- 9. 磁碟空間
  check("磁碟空間", function()
    local output = runCommandSync("/bin/df", {"-h", os.getenv("HOME")})
    local lastLine = ""
    for line in (output or ""):gmatch("[^\n]+") do lastLine = line end
    local avail = lastLine:match("%S+%s+%S+%s+%S+%s+(%S+)")
    if not avail or avail == "" then return "!無法取得" end
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
    local gt = runCommandSync("/usr/bin/which", {"gtimeout"}, {stderr = true})
    gt = (gt or ""):gsub("%s+$", "")
    if gt ~= "" and gt:sub(1, 1) == "/" then return "gtimeout — " .. gt end
    local t = runCommandSync("/usr/bin/which", {"timeout"}, {stderr = true})
    t = (t or ""):gsub("%s+$", "")
    if t ~= "" and t:sub(1, 1) == "/" then return "timeout — " .. t end
    return "!找不到 — brew install coreutils"
  end)

  -- 12. 共用幻覺列表
  check("hallucinations_builtin.txt", function()
    local attr = hs.fs.attributes(BUILTIN_HALLUCINATION_FILE)
    if not attr then return "!不存在（使用硬編碼 fallback）" end
    local count = 0
    local f = io.open(BUILTIN_HALLUCINATION_FILE, "r")
    if f then
      for line in f:lines() do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" and line:sub(1, 1) ~= "#" then count = count + 1 end
      end
      f:close()
    end
    return string.format("%d 條規則（+ normalized 兩層比對）", count)
  end)

  -- 13. [CR10] Config 驗證結果
  -- [CR12] 現在能區分「無設定檔」vs「空檔」vs「JSON 壞掉」vs「正常+警告」
  check("config.json 驗證", function()
    if not lastConfigValidation then return "無設定檔（正常，使用預設值）" end
    local w = lastConfigValidation.warnings
    if not w or #w == 0 then return "通過（無警告）" end
    return "!" .. #w .. " 項警告：" .. table.concat(w, "; ")
  end)

  -- 14. [CR15] 濾波器鏈 dry-run 驗證
  -- 使用 FFmpeg 的 lavfi 虛擬音源做一次快速 dry-run，
  -- 驗證 -af 參數語法是否合法，避免實際錄音時才發現錯誤
  check("濾波器鏈", function()
    if AUDIO_FILTER_CHAIN == "" then return "已停用" end
    local ffmpeg = findFFmpeg()
    if not ffmpeg then return "!無法測試（ffmpeg 不存在）" end
    local output, status = runCommandSync(ffmpeg,
      {"-f", "lavfi", "-i", "anullsrc=r=16000:cl=mono",
       "-af", AUDIO_FILTER_CHAIN,
       "-t", "0.01", "-f", "null", "-"},
      {stderr = true})
    if status then
      return "語法正確 — " .. AUDIO_FILTER_CHAIN
    end
    -- 從 stderr 擷取第一個 Error 行
    local errLine = (output or ""):match("[Ee]rror[^\n]*") or "語法錯誤"
    return "!" .. errLine
  end)

  -- 組裝報告
  local header = string.format(
    "=== PTT Whisper v%s Diagnostics ===\n%s\nMode: %s",
    VERSION, os.date("%Y-%m-%d %H:%M:%S"),
    STREAMING_MODE and "Streaming" or "Traditional")

  local report = header .. "\n\n" .. table.concat(results, "\n")
  local status = allOk and "\n\n🎉 所有檢查通過！" or "\n\n⚠️ 部分項目需要處理"
  report = report .. status

  print(report)
  local diagFile = PTT_DIR .. "/diagnostics.txt"
  local f = io.open(diagFile, "w")
  if f then f:write(report .. "\n"); f:close() end

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
  cancelKillFallbackTimer()
  recordTask     = nil
  transcribeTask = nil
  streamTask     = nil
  currentState   = STATE.IDLE
  recordStartAt  = nil
  resetStreamAccumulator()
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

-- ── 主入口 ──────────────────────────────────────────────────
local function onKeyDown()
  if STREAMING_MODE then startStreaming() else startRecording() end
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

-- [CR1] 安全開啟檔案
local function safeOpenFile(filepath)
  runCommandAsync("/usr/bin/open", {filepath})
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
      { title = "濾波器：" .. (AUDIO_FILTER_CHAIN ~= "" and "ON" or "OFF"),
        disabled = true },
      { title = langModelMenuLabel(), disabled = true },
      { title = "-" },
      { title = "🔍 Run Diagnostics", fn = function() runDiagnostics() end },
      { title = "-" },
      { title = "列出音訊裝置（Console）", fn = function()
          listAudioDevices()
          hs.alert.show("裝置列表已輸出至 Console", 2)
        end
      },
      { title = "打開 Error Log", fn = function() safeOpenFile(LOG_FILE) end },
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
              f:write('  "audio_filter_chain": "highpass=f=200,lowpass=f=5000,loudnorm=I=-16:TP=-1.5",\n')
              f:write('  "lang_models": {\n')
              f:write('    "_default": { "lang": "auto" }\n')
              f:write('  }\n')
              f:write('}\n')
              f:close()
            end
          end
          safeOpenFile(CONFIG_FILE)
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
          safeOpenFile(hallFile)
        end
      },
      { title = "-" },
      { title = "Reload Hammerspoon", fn = function() cleanup(); hs.reload() end },
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
