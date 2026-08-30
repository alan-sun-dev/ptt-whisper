-- ============================================================
-- Push-to-Talk Whisper Dictation for Hammerspoon
-- v4.0.3
--
-- v4.0.3：測試套件的 merge-gate 語意（lua 成為必要依賴）
--
-- v4.0.2 強化：
--   S1.[Fix]  /health 分類改用 JSON 解析，不再 substring 推斷
--             （{"status_message":"ok"} 之類會被誤判成 ready）
--   S2.[Fix]  occupancy 偵測不再重用 readiness 分類器，避免連帶收緊
--
-- v4.0.1 強化：
--   H1.[Fix]  readiness 改用 GET /health（行程活著 ≠ 模型可用）
--   H2.[Fix]  占用偵測與就緒偵測拆開，兩者語意不同
--   H3.[Fix]  serverGeneration 守衛所有非同步 callback，消除 stale race
--   H4.[Fix]  重啟改為等待舊行程真正結束，而非 sleep 固定秒數
--   H5.[Fix]  快取 identity 改以「實際完成推理的 backend」為準
--   H6.[Test] 加入 ./tests/run.sh 常駐迴歸測試套件
--
-- v4.0.0 移除（breaking）：
--   RM1.[Remove] Streaming 模式整套移除。它是一條繞過統一後處理管線的
--                平行實作，幻覺過濾／快取／fallback／prompt／VAD 對它皆無效。
--                最後一版保存於 git tag `streaming-final`。
--                未來的串流必須是統一管線下的 ASR backend，
--                契約見 docs/ARCHITECTURE.md
--
-- v3.8.0（常駐 server）：
--   SV1.[Feat] whisper-server 常駐模式，省掉每次錄音的模型載入成本
--              預設關閉；任何失敗都自動退回 CLI 路徑
--
-- v3.7.0：P3（initial prompt、VAD、threads、max-context）、
--         P3-1（PATH 補 /sbin，修好從未生效的快取）
-- v3.6.5：MC1~MC2（模型候選掃描、WHISPER_CACHE_MAX 轉發）
--
-- 完整版本歷史見 CHANGELOG.md
--
-- v3.6.4：CR12~CR15（第四輪 Code Review）
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
-- 依賴：ffmpeg、whisper.cpp 已編譯、~/ptt-whisper/transcribe.sh v2.10.1+
-- ============================================================

-- ── 版本常數 ────────────────────────────────────────────────
local VERSION = "4.0.3"

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

-- ── [F4] 快取設定 ────────────────────────────────────────────
local CACHE_ENABLED = false

-- ── [F6] Fallback Model ─────────────────────────────────────
local FALLBACK_MODEL = ""

-- ── [P3] 推理參數 ───────────────────────────────────────────
-- initial prompt：注入術語 / 人名 / 中英混用詞，提升專有名詞辨識率。
-- 全域 prompt 之後會再串接 lang_models[bid].prompt（見 getPromptForApp）。
local INITIAL_PROMPT = ""

-- VAD：砍掉靜音段，短錄音提速明顯，也能從源頭減少靜音幻覺。
-- "auto" = whisper.cpp 支援且找得到 VAD model 才啟用
local VAD_ENABLED = "auto"

-- max-context：PTT 是獨立短句，不需跨段上下文；0 可減少重複／拖尾幻覺
local MAX_CONTEXT = 0

-- 執行緒數：0 = 交給 transcribe.sh 自動偵測（Apple Silicon 取效能核心數）
local WHISPER_THREADS = 0

-- ── [SV1] 常駐 whisper-server ───────────────────────────────
-- CLI 模式每次錄音都要重新載入模型（small 約 0.3~0.5s）。常駐 server 把模型
-- 留在記憶體，省掉這段固定成本。預設關閉：這會多一個長駐行程（約佔用一份
-- 模型大小的 RAM），是否值得應該由使用者自己決定，不該升級後自動出現。
local SERVER_MODE = false
local SERVER_PORT = 8178
local SERVER_HOST = "127.0.0.1"
-- 模型載入可能要好幾秒，啟動後輪詢 /health 到就緒為止
local SERVER_READY_TIMEOUT_SEC = 20
local SERVER_POLL_INTERVAL_SEC = 0.4
-- 重啟時等待舊行程真正結束的上限
local SERVER_STOP_TIMEOUT_SEC  = 5

local WHISPER_SERVER_BIN_CANDIDATES = {
  "/build/bin/whisper-server",
  "/whisper-server",
  "/build/bin/server",
  "/server",
}

-- ── [P6] Whisper binary 搜尋路徑（與 transcribe.sh 保持一致）──
local WHISPER_BIN_CANDIDATES = {
  "/whisper-cli",
  "/build/bin/whisper-cli",
  "/main",
  "/build/bin/main",
}

-- ── [MC1] 預設模型候選清單（與 transcribe.sh 保持一致）──────
-- 量化版優先：速度 2~3x、RAM 減半、準確率幾乎無損（<0.5% WER 差異）。
-- q5_1 排在 q5_0 之前：whisper.cpp 的 download-ggml-model.sh 對 small
-- 只提供 q5_1（q5_0 僅 medium/large 有），q5_0 需自行 quantize。
local DEFAULT_MODEL_CANDIDATES = {
  "ggml-small-q5_1.bin",
  "ggml-small-q5_0.bin",
  "ggml-small-q8_0.bin",
  "ggml-small.bin",
}

-- ── [CR3] Config 已知欄位白名單 ─────────────────────────────
local CONFIG_KNOWN_KEYS = {
  slow_paste_apps = true,
  show_preview_alert = true,
  cache_enabled = true,
  fallback_model = true,
  lang_models = true,
  audio_filter_chain = true,
  initial_prompt = true,
  vad_enabled = true,
  max_context = true,
  whisper_threads = true,
  server_mode = true,
  server_port = true,
}

-- ── [RM1] 已移除的設定欄位 ─────────────────────────────────
-- 舊 config.json 留著這些欄位不會壞，但要明確告訴使用者它們已經沒有作用，
-- 而不是用一句籠統的 "unknown config key" 帶過。
local REMOVED_CONFIG_KEYS = {
  streaming_mode      = "Streaming 模式已於 v4.0.0 移除",
  streaming_step_ms   = "Streaming 模式已於 v4.0.0 移除",
  streaming_length_ms = "Streaming 模式已於 v4.0.0 移除",
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

  -- Unknown / removed keys
  for key, _ in pairs(config) do
    if REMOVED_CONFIG_KEYS[key] then
      warn(string.format("config key '%s' 已移除且不再有作用：%s"
        .. "（見 CHANGELOG.md 與 docs/ARCHITECTURE.md）",
        key, REMOVED_CONFIG_KEYS[key]))
    elseif not CONFIG_KNOWN_KEYS[key] then
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
          -- [P3] per-app prompt：會接在全域 initial_prompt 之後
          if type(entry.prompt) == "string" and entry.prompt ~= "" then
            parsed.prompt = entry.prompt
          end
          if parsed.lang or parsed.model or parsed.prompt then
            LANG_MODELS[bid] = parsed
          end
        end
      end
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

  -- [P3] initial_prompt: string
  if config.initial_prompt ~= nil then
    if type(config.initial_prompt) == "string" then
      INITIAL_PROMPT = config.initial_prompt
    else
      warn("initial_prompt: expected string")
    end
  end

  -- [P3] vad_enabled: boolean 或 "auto"
  if config.vad_enabled ~= nil then
    if type(config.vad_enabled) == "boolean" then
      VAD_ENABLED = config.vad_enabled and "true" or "false"
    elseif config.vad_enabled == "auto" then
      VAD_ENABLED = "auto"
    else
      warn("vad_enabled: expected boolean or \"auto\"")
    end
  end

  -- [P3] max_context: number, 0~224（whisper 的 n_text_ctx/2）
  if config.max_context ~= nil then
    if type(config.max_context) == "number"
       and config.max_context >= 0
       and config.max_context <= 224 then
      MAX_CONTEXT = math.floor(config.max_context)
    else
      warn("max_context: expected number in 0~224")
    end
  end

  -- [P3] whisper_threads: number, 0~16（0 = 自動偵測）
  if config.whisper_threads ~= nil then
    if type(config.whisper_threads) == "number"
       and config.whisper_threads >= 0
       and config.whisper_threads <= 16 then
      WHISPER_THREADS = math.floor(config.whisper_threads)
    else
      warn("whisper_threads: expected number in 0~16 (0 = auto)")
    end
  end

  -- [SV1] server_mode: boolean
  if config.server_mode ~= nil then
    if type(config.server_mode) == "boolean" then
      SERVER_MODE = config.server_mode
    else
      warn("server_mode: expected boolean")
    end
  end

  -- [SV1] server_port: number, 1024~65535
  if config.server_port ~= nil then
    if type(config.server_port) == "number"
       and config.server_port >= 1024
       and config.server_port <= 65535 then
      SERVER_PORT = math.floor(config.server_port)
    else
      warn("server_port: expected number in 1024~65535")
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
  PASTING      = "pasting",
}
local currentState = STATE.IDLE
local sessionCounter = 0

-- 模組級引用
local recordTask       = nil
local transcribeTask   = nil
local recordStartAt    = nil
local cachedFFmpegPath = nil
local killFallbackTimer = nil

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
--- [MC1] 未指定 model 時，依 DEFAULT_MODEL_CANDIDATES 順序掃描：
---        量化版（q5_1 → q5_0 → q8_0）優先，全都沒有才用 FP16
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
      -- [MC1] 依偏好順序掃描候選模型，量化版優先
      for _, name in ipairs(DEFAULT_MODEL_CANDIDATES) do
        local candidate = whisperDir .. "/models/" .. name
        if hs.fs.attributes(candidate) then
          path = candidate
          break
        end
      end
      -- 全部候選皆不存在時仍指向 FP16 路徑，
      -- 讓下方的存在性檢查回傳 nil、由呼叫端輸出明確錯誤
      path = path or (whisperDir .. "/models/ggml-small.bin")
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

--- 根據前景 app 取得語言/模型/prompt
--- @return string|nil lang, string|nil model, string appName, string|nil prompt
local function getLangModelForCurrentApp()
  local ok, app = pcall(hs.application.frontmostApplication)
  if not ok or not app then return nil, nil, "(unknown)", nil end
  local bid = app:bundleID() or ""
  local appName = app:name() or bid
  local entry = LANG_MODELS[bid] or LANG_MODELS["_default"]
  if not entry then return nil, nil, appName, nil end
  local lang = entry.lang
  if lang == "auto" then lang = nil end
  return lang, entry.model, appName, entry.prompt
end

--- [P3] 組出這次要用的 initial prompt
--- 全域 initial_prompt 是通用術語表（你的名字、公司、常用中英混用詞），
--- per-app prompt 是該 App 的領域術語 —— 兩者「串接」而非互相覆蓋，
--- 這樣全域術語表在每個 App 都有效，不必逐個 App 重複貼一遍。
--- @param appPrompt string|nil
--- @return string  空字串 = 不帶 --prompt
local function buildPrompt(appPrompt)
  local parts = {}
  if INITIAL_PROMPT ~= "" then table.insert(parts, INITIAL_PROMPT) end
  if appPrompt and appPrompt ~= "" then table.insert(parts, appPrompt) end
  return table.concat(parts, " ")
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

-- ── [SV1] whisper-server 生命週期 ───────────────────────────
-- 狀態不變式：
--   serverGeneration —— 每次 start / stop / 非預期結束都會 +1。
--                       所有非同步 callback（process exit、health 探測、
--                       poll timer、restart 等待）都在排程時 capture 當下的
--                       generation，觸發時若已不相符就直接 return，
--                       絕不碰任何 server 全域狀態。
--   serverTask       —— 目前這一代的行程；nil = 沒有我們啟動的 server
--   serverReady      —— /health 回報模型已載入完成（不只是「port 有回應」）
--   serverStatusText —— 永遠對應「目前 generation」的狀態
local serverTask       = nil
local serverReady      = false
local serverModelPath  = nil
local serverStatusText = "未啟用"
local serverGeneration = 0

local function bumpGeneration()
  serverGeneration = serverGeneration + 1
  return serverGeneration
end

local function serverBaseURL()
  return string.format("http://%s:%d", SERVER_HOST, SERVER_PORT)
end

--- 找 whisper-server 執行檔（與 findWhisperBin 同樣的搜尋策略）
local function findWhisperServerBin()
  local whisperDir = os.getenv("WHISPER_DIR")
                     or (os.getenv("HOME") .. "/whisper.cpp")
  for _, suffix in ipairs(WHISPER_SERVER_BIN_CANDIDATES) do
    local path = whisperDir .. suffix
    local attr = hs.fs.attributes(path)
    if attr and attr.mode == "file" then return path end
  end
  return nil
end

-- [TESTABLE:classifyHealthResponse] ← tests/test-lua-units.lua 會抽出這段獨立執行
--- 把 GET /health 的結果分類。純函式，不碰任何全域狀態。
---
--- whisper.cpp server 的正式契約：
---   ready   HTTP 200  {"status":"ok"}
---   loading HTTP 503  {"status":"loading model"}
---
--- 決策表：
---   連線失敗（status nil 或 < 100）                    → "unavailable"
---   200 + 合法 JSON object + status == "ok"            → "ready"
---   503 + 合法 JSON object + status == "loading model" → "loading"
---   其他一切（含 200 非 JSON、200 無關 JSON、
---            503 無關 JSON、404、500…）                → "foreign"
---
--- 刻意不做 substring 判斷：像 {"status_message":"not ok"} 或純文字
--- "status check ok" 都同時含有 status 與 ok，會造成 false-positive ready。
---
--- 關鍵區分：
---   「行程活著」（loading / foreign）  ≠  「模型可用」（ready）
---   「port 空著」（unavailable）      ≠  「port 被別的服務占用」（foreign）
---
--- @param status number|nil  HTTP status；nil 或 < 100 代表連線失敗
--- @param body string|nil    回應內容
--- @param decode function|nil JSON decoder，預設 hs.json.decode。
---        參數化的唯一目的：讓 tests/test-lua-units.lua 能在沒有 Hammerspoon
---        的環境下直接執行「這一份」程式碼，而不是複製一份實作去測。
--- @return string state, string detail
local function classifyHealthResponse(status, body, decode)
  if status == nil or status < 100 then
    return "unavailable", "connection failed"
  end

  local detail = (body or ""):sub(1, 120)

  -- 只有 200 與 503 在契約內，其餘一律 foreign（有東西在聽，但不是 whisper-server）
  if status ~= 200 and status ~= 503 then
    return "foreign", "HTTP " .. tostring(status)
  end

  decode = decode or (rawget(_G, "hs") and hs.json and hs.json.decode)
  if not decode then
    return "foreign", "no JSON decoder available"
  end

  -- hs.json.decode 遇到非法 JSON 會 raise error（不是回傳 nil），必須包 pcall
  local parsed
  local ok
  ok, parsed = pcall(decode, body or "")
  if not ok or type(parsed) ~= "table" then
    return "foreign",
      "HTTP " .. tostring(status) .. " body 不是合法 JSON object: " .. detail
  end

  -- 陣列在 Lua 裡也是 table，所以「是 table」不夠；status 必須是字串
  local st = parsed.status
  if type(st) ~= "string" then
    return "foreign",
      "HTTP " .. tostring(status) .. " JSON 沒有 status 字串: " .. detail
  end

  if status == 200 and st == "ok" then
    return "ready", detail
  end
  if status == 503 and st == "loading model" then
    return "loading", detail
  end
  return "foreign",
    "HTTP " .. tostring(status) .. " status=\"" .. st .. "\""
end
-- [/TESTABLE]

--- Readiness 探測：專門回答「whisper 模型能不能用」
--- @param callback function(state: string, detail: string)
local function probeServerReadiness(callback)
  hs.http.asyncGet(serverBaseURL() .. "/health", nil, function(status, body)
    callback(classifyHealthResponse(status, body))
  end)
end

--- Endpoint 占用探測：專門回答「這個 port 上是不是已經有東西在聽」
--- 與 readiness 刻意分開：任何 HTTP 回應（含 404、500）都代表被占用，
--- 不能因為 /health 回 404 就誤判成「port 是空的」而去啟動並 bind 失敗。
--- @param callback function(occupied: boolean, detail: string)
local function probeEndpointOccupancy(callback)
  hs.http.asyncGet(serverBaseURL() .. "/health", nil, function(status)
    -- 任何 HTTP 回應（含 404 / 500 / 非 JSON）都代表 port 上有人在聽。
    -- 這裡刻意「不」重用 classifyHealthResponse：readiness 收緊成
    -- 「必須是 whisper-server 的 JSON 契約」之後，若 occupancy 跟著收緊，
    -- 回 404 的其他 HTTP 服務就會被誤判成「port 是空的」，
    -- 接著我們啟動 whisper-server 並 bind 失敗。兩者語意必須各自獨立。
    local occupied = (status ~= nil and status >= 100)
    callback(occupied, occupied and ("HTTP " .. tostring(status)) or "no listener")
  end)
end

--- 停止 server。先 bump generation，讓所有在途 callback 立刻失效，
--- 再終止行程 —— 順序不能顛倒，否則 terminate 觸發的 exit callback
--- 會用舊 generation 通過檢查。
--- @return userdata|nil 被停掉的 task（供 restart 等待其真正結束）
local function stopServer(statusText)
  bumpGeneration()
  local task = serverTask
  serverTask      = nil
  serverReady     = false
  serverModelPath = nil
  serverStatusText = statusText or "已停止"
  if task then
    pcall(function()
      if task:isRunning() then task:terminate() end
    end)
  end
  return task
end

--- 等待行程真正結束（而不是 sleep 固定秒數然後祈禱）
local function waitForTaskExit(task, deadline, callback)
  if not task then callback(true); return end
  local running = false
  pcall(function() running = task:isRunning() end)
  if not running then callback(true); return end
  if hs.timer.secondsSinceEpoch() >= deadline then callback(false); return end
  hs.timer.doAfter(SERVER_POLL_INTERVAL_SEC, function()
    waitForTaskExit(task, deadline, callback)
  end)
end

--- 偵測效能核心數（與 transcribe.sh 的策略一致）
local function detectPerfCores()
  local out = runCommandSync("/usr/sbin/sysctl", {"-n", "hw.perflevel0.physicalcpu"})
  local n = tonumber((out or ""):match("%d+"))
  if not n then
    out = runCommandSync("/usr/sbin/sysctl", {"-n", "hw.physicalcpu"})
    n = tonumber((out or ""):match("%d+"))
  end
  if not n or n < 1 then n = 4 end
  if n > 16 then n = 16 end
  return n
end

local startServer  -- forward declaration（restart 會用到）

--- 輪詢 /health 直到模型就緒，或超過 deadline。
--- gen 是這一代的 generation；每個進入點與 callback 都先比對，
--- 不相符就結束 —— 這同時保證「重複 restart 不會累積多個 poll loop」。
local function pollUntilReady(gen, deadline)
  if gen ~= serverGeneration then return end
  if not serverTask then return end

  probeServerReadiness(function(state, detail)
    if gen ~= serverGeneration then return end

    if state == "ready" then
      serverReady = true
      serverStatusText = "就緒"
      appendErrorLog("server: ready at " .. serverBaseURL()
                     .. " model=" .. tostring(serverModelPath))
      updateMenubar("🎤", "PTT Whisper v" .. VERSION .. " — Server 就緒")
      return
    end

    if state == "loading" then
      serverStatusText = "模型載入中…"
    elseif state == "foreign" then
      -- 我們啟動的行程活著，但 /health 回的不是就緒的 whisper-server 格式。
      -- 啟動早期可能如此，因此繼續輪詢，但絕不標成 ready。
      serverStatusText = "等待有效的 /health 回應…"
      appendErrorLog("server: unexpected /health — " .. tostring(detail))
    else
      serverStatusText = "等待行程接受連線…"
    end

    if hs.timer.secondsSinceEpoch() >= deadline then
      appendErrorLog(string.format(
        "server: not ready within %ds (last state=%s), falling back to CLI",
        SERVER_READY_TIMEOUT_SEC, state))
      stopServer("啟動逾時（改用 CLI）")
      hs.alert.show("⚠️ whisper-server 啟動逾時，改用 CLI 模式", 3)
      return
    end

    hs.timer.doAfter(SERVER_POLL_INTERVAL_SEC, function()
      pollUntilReady(gen, deadline)
    end)
  end)
end

startServer = function()
  if not SERVER_MODE then return end
  if serverTask then return end

  local bin = findWhisperServerBin()
  if not bin then
    serverStatusText = "找不到 whisper-server"
    appendErrorLog("server: whisper-server binary not found, using CLI")
    return
  end

  local modelPath = resolveModelPath(nil)
  if not modelPath then
    serverStatusText = "找不到 model"
    appendErrorLog("server: model not found, using CLI")
    return
  end

  local gen = bumpGeneration()
  serverStatusText = "檢查埠…"

  -- 先確認 port 沒被占用。這是「占用偵測」，與「模型就緒偵測」是兩件事：
  -- 佔著這個 port 的可能是別的 HTTP 服務，也可能是上次沒收乾淨的殘留行程。
  -- 兩種情況我們都無從得知它載入的是哪個模型，貿然使用可能拿到錯的結果，
  -- 因此一律不啟動、退回 CLI，由使用者決定要清掉它還是換 server_port。
  probeEndpointOccupancy(function(occupied, detail)
    if gen ~= serverGeneration then return end

    if occupied then
      serverStatusText = string.format("埠 %d 已被占用（改用 CLI）", SERVER_PORT)
      appendErrorLog(string.format(
        "server: port %d already occupied [%s], refusing to start; using CLI",
        SERVER_PORT, tostring(detail)))
      hs.alert.show(string.format(
        "⚠️ 埠 %d 已被占用，改用 CLI 模式", SERVER_PORT), 3)
      return
    end

    local args = {
      "-m", modelPath,
      "--host", SERVER_HOST,
      "--port", tostring(SERVER_PORT),
      "-t", tostring(WHISPER_THREADS > 0 and WHISPER_THREADS or detectPerfCores()),
    }

    -- VAD：同樣先確認這個 build 支援才帶上
    if VAD_ENABLED ~= "false" then
      local helpText = runCommandSync(bin, {"--help"}, {stderr = true}) or ""
      if helpText:find("%-%-vad") then
        local whisperDir = os.getenv("WHISPER_DIR")
                           or (os.getenv("HOME") .. "/whisper.cpp")
        local out = runCommandSync("/bin/ls", {whisperDir .. "/models"}) or ""
        for line in out:gmatch("[^\n]+") do
          if line:match("^ggml%-silero.*%.bin$") then
            table.insert(args, "--vad")
            table.insert(args, "--vad-model")
            table.insert(args, whisperDir .. "/models/" .. line)
            break
          end
        end
      end
    end

    serverModelPath = modelPath
    serverReady     = false
    serverStatusText = "啟動中…"

    local task
    task = hs.task.new(bin, function(exitCode, _, stderr)
      hs.timer.doAfter(0, function()
        -- 舊 server 的 exit callback 絕不能改到新 server 的狀態
        if gen ~= serverGeneration then return end
        appendErrorLog("server: exited unexpectedly exit=" .. tostring(exitCode)
                       .. " stderr=" .. (stderr or ""):sub(1, 200))
        serverTask  = nil
        serverReady = false
        serverStatusText = "已結束（exit " .. tostring(exitCode) .. "）"
        -- bump 讓同代的 poll loop 立刻停止
        bumpGeneration()
      end)
    end, function(_, _, stderr)
      if stderr and stderr ~= "" then
        appendErrorLog("server stderr: " .. stderr:sub(1, 200))
      end
      return true
    end, args)

    serverTask = task

    if task:start() then
      appendErrorLog("server: starting " .. bin .. " model=" .. modelPath
                     .. " gen=" .. gen)
      pollUntilReady(gen, hs.timer.secondsSinceEpoch() + SERVER_READY_TIMEOUT_SEC)
    else
      if gen ~= serverGeneration then return end
      serverTask = nil
      serverStatusText = "啟動失敗"
      appendErrorLog("server: failed to start, using CLI")
    end
  end)
end

--- [SV1] 讀 transcribe.sh 寫下的後端標記。
--- server 模式會靜默退回 CLI，沒有這個顯示使用者無從得知它到底有沒有在用。
--- 值可能是 server / cli / cache:server / cache:cli
--- 快取命中會保留是哪個 backend 的 namespace，否則開了 server 卻一直命中
--- 快取時，使用者看不出 server 到底有沒有在用。
local function lastBackendLabel()
  local f = io.open(PTT_DIR .. "/last_backend.txt", "r")
  if not f then return "尚無記錄" end
  local v = (f:read("*l") or ""):match("^%s*(.-)%s*$")
  f:close()
  local cached = v:match("^cache:(.+)$")
  if cached then
    return "📦 快取（" .. (cached == "server" and "server" or "CLI") .. " 產生）"
  end
  if v == "server" then return "⚡ server" end
  if v == "cli" then return "📼 CLI" end
  return "尚無記錄"
end

--- 重啟：等舊行程真正結束再啟動，而不是 sleep 固定秒數然後祈禱。
local function restartServer()
  local task = stopServer("重啟中…")
  local gen = serverGeneration
  waitForTaskExit(task, hs.timer.secondsSinceEpoch() + SERVER_STOP_TIMEOUT_SEC,
    function(exited)
      -- 等待期間若又有人 stop/start，這次重啟就作廢
      if gen ~= serverGeneration then return end
      if not exited then
        appendErrorLog(string.format(
          "server: previous process still running after %ds; starting anyway "
          .. "(port bind may fail, will fall back to CLI)", SERVER_STOP_TIMEOUT_SEC))
      end
      startServer()
    end)
end

PTTWhisper.startServer   = startServer
PTTWhisper.stopServer    = stopServer
PTTWhisper.restartServer = restartServer
PTTWhisper.serverState   = function()
  return {
    generation = serverGeneration,
    ready      = serverReady,
    status     = serverStatusText,
    model      = serverModelPath,
    running    = serverTask ~= nil,
  }
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

-- ── 傳統模式主流程 ──────────────────────────────────────────

local function startRecording()
  if currentState ~= STATE.IDLE then
    if currentState == STATE.TRANSCRIBING then
      hs.alert.show("⚠️ 轉錄中，請稍候...", 1)
    elseif currentState == STATE.PASTING then
      hs.alert.show("⚠️ 貼上中，請稍候...", 1)
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
  local langOverride, modelOverride, appName, appPrompt = getLangModelForCurrentApp()
  local promptText = buildPrompt(appPrompt)

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
      -- [P3-1] 必須包含 /sbin：macOS 的 md5 在 /sbin/md5，
      -- 少了它 transcribe.sh 算不出 AUDIO_HASH，cache_enabled 會靜默失效
      PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
      HOME = os.getenv("HOME"),
    }
    if CACHE_ENABLED then env.WHISPER_CACHE = "true" end
    if FALLBACK_MODEL ~= "" then env.WHISPER_FALLBACK_MODEL = FALLBACK_MODEL end
    -- [P3] 推理參數
    if promptText ~= "" then env.WHISPER_PROMPT = promptText end
    env.WHISPER_VAD = VAD_ENABLED
    env.WHISPER_MAX_CONTEXT = tostring(MAX_CONTEXT)
    -- 0 = 不指定，交給 transcribe.sh 依 CPU 自動偵測
    if WHISPER_THREADS > 0 then
      env.WHISPER_THREADS = tostring(WHISPER_THREADS)
    end
    -- [SV1] 只在 server 真的就緒時才叫 transcribe.sh 走 server；
    -- 沒就緒就完全不提，讓它照原本的 CLI 路徑跑
    if SERVER_MODE and serverTask and serverReady then
      env.WHISPER_SERVER = "true"
      env.WHISPER_SERVER_URL = serverBaseURL()
      if serverModelPath then
        env.WHISPER_SERVER_MODEL = serverModelPath
      end
    end
    -- [MC2] WHISPER_CACHE_MAX 也要轉發，否則這個旋鈕只在直接執行
    -- transcribe.sh 時有效，從 Hammerspoon 走完全接不到（永遠是預設 50）
    for _, k in ipairs({"WHISPER_DIR", "WHISPER_MODEL", "WHISPER_LANG",
                        "WHISPER_TIMEOUT", "WHISPER_AUTO_RESAMPLE",
                        "WHISPER_CACHE_MAX", "WHISPER_VAD_MODEL",
                        "WHISPER_PROMPT_MAX_BYTES"}) do
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

  -- 4. [CR14] Model 檔案（含 Q5_0/FP16 標籤）
  check("Model 檔案", function()
    local modelPath = resolveModelPath(nil)
    if not modelPath then return "!預設 model 不存在" end
    local attr = hs.fs.attributes(modelPath)
    local sizeMB = attr and math.floor((attr.size or 0) / 1024 / 1024) or 0
    -- [CR14][MC1] 標記模型類型，讓使用者一眼可辨是否正在使用量化版本
    -- 通用比對檔名尾端的量化後綴（q5_1 / q5_0 / q8_0 / q4_k_m ...），
    -- 比對不到就是未量化的 FP16
    local suffix = modelPath:match("%-(q[%w_]+)%.bin$")
    local tag = suffix and suffix:upper() or "FP16"
    return string.format("%s (%dMB) [%s]", modelPath, sizeMB, tag)
  end)

  -- 5. Fallback model
  if FALLBACK_MODEL ~= "" then
    check("Fallback Model", function()
      local path = resolveModelPath(FALLBACK_MODEL)
      if not path then return "!" .. FALLBACK_MODEL .. " 不存在" end
      return path
    end)
  end

  -- 6. transcribe.sh
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

  -- 7. 麥克風權限
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

  -- 8. 磁碟空間
  check("磁碟空間", function()
    local output = runCommandSync("/bin/df", {"-h", os.getenv("HOME")})
    local lastLine = ""
    for line in (output or ""):gmatch("[^\n]+") do lastLine = line end
    local avail = lastLine:match("%S+%s+%S+%s+%S+%s+(%S+)")
    if not avail or avail == "" then return "!無法取得" end
    return avail .. " 可用"
  end)

  -- 9. PTT_DIR 權限
  check("PTT_DIR 權限", function()
    local attr = hs.fs.attributes(PTT_DIR)
    if not attr then return "!" .. PTT_DIR .. " 不存在" end
    return PTT_DIR .. " — " .. (attr.permissions or "unknown")
  end)

  -- 10. timeout 指令
  check("timeout 指令", function()
    local gt = runCommandSync("/usr/bin/which", {"gtimeout"}, {stderr = true})
    gt = (gt or ""):gsub("%s+$", "")
    if gt ~= "" and gt:sub(1, 1) == "/" then return "gtimeout — " .. gt end
    local t = runCommandSync("/usr/bin/which", {"timeout"}, {stderr = true})
    t = (t or ""):gsub("%s+$", "")
    if t ~= "" and t:sub(1, 1) == "/" then return "timeout — " .. t end
    return "!找不到 — brew install coreutils"
  end)

  -- 11. 共用幻覺列表
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

  -- 12. [CR10] Config 驗證結果
  -- [CR12] 現在能區分「無設定檔」vs「空檔」vs「JSON 壞掉」vs「正常+警告」
  check("config.json 驗證", function()
    if not lastConfigValidation then return "無設定檔（正常，使用預設值）" end
    local w = lastConfigValidation.warnings
    if not w or #w == 0 then return "通過（無警告）" end
    return "!" .. #w .. " 項警告：" .. table.concat(w, "; ")
  end)

  -- 13. [CR15] 濾波器鏈 dry-run 驗證
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

  -- 14. [P3] whisper.cpp 旗標支援度
  check("whisper.cpp 旗標", function()
    local path = findWhisperBin()
    if not path then return "!whisper.cpp 未安裝" end
    local helpText = runCommandSync(path, {"--help"}, {stderr = true}) or ""
    local supported, missing = {}, {}
    for _, flag in ipairs({"--threads", "--max-context", "--prompt", "--vad"}) do
      -- Lua pattern 需跳脫 "-"
      if helpText:find(flag:gsub("%-", "%%-")) then
        table.insert(supported, flag)
      else
        table.insert(missing, flag)
      end
    end
    if #missing == 0 then
      return "全部支援（" .. table.concat(supported, " ") .. "）"
    end
    -- 缺旗標不是錯誤：transcribe.sh 會自動略過不支援的項目
    return string.format("支援 %s ／ 此 build 無 %s（會自動略過）",
      table.concat(supported, " "), table.concat(missing, " "))
  end)

  -- 15. [P3] VAD
  check("VAD", function()
    if VAD_ENABLED == "false" then return "已停用（vad_enabled: false）" end
    local whisperDir = os.getenv("WHISPER_DIR")
                       or (os.getenv("HOME") .. "/whisper.cpp")
    -- 與 transcribe.sh 一致：用 glob 掃描，不寫死 silero 版本號
    local out = runCommandSync("/bin/ls", {whisperDir .. "/models"}) or ""
    local vadModel = nil
    for line in out:gmatch("[^\n]+") do
      if line:match("^ggml%-silero.*%.bin$") then vadModel = line; break end
    end
    if not vadModel then
      local hint = "!找不到 VAD model — cd " .. whisperDir
                   .. " && bash ./models/download-vad-model.sh silero-v5.1.2"
      -- auto 模式下沒有 model 只是「不啟用」，不算故障
      if VAD_ENABLED == "auto" then
        return "未啟用（無 VAD model）— 下載後 auto 模式會自動啟用"
      end
      return hint
    end
    local path = findWhisperBin()
    if path then
      local helpText = runCommandSync(path, {"--help"}, {stderr = true}) or ""
      if not helpText:find("%-%-vad") then
        return "!此 whisper.cpp build 不支援 --vad（請更新 whisper.cpp）"
      end
    end
    return "啟用 — " .. vadModel
  end)

  -- 16. [P3] Initial prompt
  check("Initial prompt", function()
    local _, _, appName, appPrompt = getLangModelForCurrentApp()
    local combined = buildPrompt(appPrompt)
    if combined == "" then return "未設定" end
    local preview, truncated = utf8Sub(combined, 40)
    return string.format("%s%s（%d bytes，前景 App：%s）",
      preview, truncated and "…" or "", #combined, appName)
  end)

  -- 17. [SV1] whisper-server
  check("whisper-server", function()
    if not SERVER_MODE then return "已停用（server_mode: false）" end
    local bin = findWhisperServerBin()
    if not bin then
      return "!找不到 whisper-server — 需要 cmake --build 產出 build/bin/whisper-server"
    end
    if not serverTask then
      return "!未執行 — " .. serverStatusText
    end
    if not serverReady then
      return "!未就緒 — " .. serverStatusText
    end
    return string.format("%s — %s（model: %s）",
      serverStatusText, serverBaseURL(), serverModelPath or "?")
  end)

  -- 18. [SV1] 上次實際使用的後端
  check("上次轉錄後端", function()
    local label = lastBackendLabel()
    if label == "尚無記錄" then return "尚無記錄（還沒轉錄過）" end
    -- 開了 server 卻實際走 CLI，代表有東西不對，值得提醒。
    -- 快取命中不算——那不是降級。
    if SERVER_MODE and label == "📼 CLI" then
      return "!" .. label .. " — server_mode 已開啟但上次走的是 CLI，見 Error Log"
    end
    return label
  end)

  -- 組裝報告
  local header = string.format(
    "=== PTT Whisper v%s Diagnostics ===\n%s\nBackend: %s",
    VERSION, os.date("%Y-%m-%d %H:%M:%S"),
    (SERVER_MODE and serverReady) and "server" or "CLI")

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
  cancelKillFallbackTimer()
  recordTask     = nil
  transcribeTask = nil
  currentState   = STATE.IDLE
  recordStartAt  = nil
  os.remove(RECORD_FILE)
  -- [SV1] 一定要收掉常駐 server，否則 reload 後埠會被殘留行程占住
  stopServer()
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
  startRecording()
end

local function onKeyUp()
  if currentState == STATE.RECORDING then
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
      { title = "Session：#" .. sessionCounter, disabled = true },
      { title = "裝置：" .. AUDIO_DEVICE, disabled = true },
      { title = "熱鍵：" .. hotkeyLabel, disabled = true },
      { title = "快取：" .. (CACHE_ENABLED and "ON" or "OFF"), disabled = true },
      { title = "Fallback：" .. (FALLBACK_MODEL ~= "" and FALLBACK_MODEL or "無"),
        disabled = true },
      { title = "濾波器：" .. (AUDIO_FILTER_CHAIN ~= "" and "ON" or "OFF"),
        disabled = true },
      { title = "Server：" .. (SERVER_MODE and serverStatusText or "OFF"),
        disabled = true },
      { title = "上次後端：" .. lastBackendLabel(), disabled = true },
      { title = langModelMenuLabel(), disabled = true },
      { title = "-" },
      { title = "🔍 Run Diagnostics", fn = function() runDiagnostics() end },
      { title = "🔄 重啟 whisper-server",
        disabled = not SERVER_MODE,
        fn = function()
          hs.alert.show("重啟 whisper-server…", 2)
          restartServer()
        end },
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
              f:write('  "cache_enabled": false,\n')
              f:write('  "fallback_model": "",\n')
              f:write('  "audio_filter_chain": "highpass=f=200,lowpass=f=5000,loudnorm=I=-16:TP=-1.5",\n')
              f:write('  "initial_prompt": "",\n')
              f:write('  "vad_enabled": "auto",\n')
              f:write('  "server_mode": false,\n')
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

-- ── [SV1] 啟動常駐 server（server_mode = false 時直接 return）──
-- 非同步：模型載入期間不阻塞 Hammerspoon 載入，
-- 尚未就緒前的錄音會自動走 CLI 路徑
startServer()

-- ── 啟動提示 ────────────────────────────────────────────────
local backendLabel = SERVER_MODE and "⚡Server" or "📼CLI"
hs.alert.show(string.format(
  "🎤 PTT Whisper v%s 已載入\n%s — 按住 %s 開始錄音",
  VERSION, backendLabel, hotkeyLabel), 2)
print(string.format(
  "PTT Whisper v%s loaded [%s] — run PTTWhisper.runDiagnostics() for health check",
  VERSION, backendLabel))
