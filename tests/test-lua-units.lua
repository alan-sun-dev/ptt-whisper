-- 從 ptt_whisper.lua 抽出 [TESTABLE:...] 區塊直接執行，
-- 驗證的是「實際出貨的那段程式碼」，不是複製一份來測。
-- 用法： lua tests/test-lua-units.lua <ptt_whisper.lua> <observations.tsv>
local srcPath, obsPath = arg[1], arg[2]

local function readAll(p)
  local f = assert(io.open(p, "r"), "cannot open " .. tostring(p))
  local c = f:read("*a"); f:close(); return c
end

local function extract(src, name)
  -- 從 marker「那一行的結尾」之後開始擷取。marker 行尾還有中文說明文字，
  -- 若從 "]" 之後直接擷取，那段沒有 -- 前綴的文字會被當成程式碼。
  local pat = "%-%- %[TESTABLE:" .. name .. "%][^\n]*\n(.-)%-%- %[/TESTABLE%]"
  local block = src:match(pat)
  assert(block, "找不到 TESTABLE 區塊: " .. name)
  return block
end

-- ── 測試用的嚴格 JSON decoder（test double）─────────────────
-- production 走的是 hs.json.decode；這裡只是為了讓被測函式能在沒有
-- Hammerspoon 的環境下執行。行為契約與 hs.json.decode 對齊的關鍵一點：
-- 非法 JSON 必須 error()，而不是回傳 nil。
local function jsonDecode(str)
  local pos = 1
  local function err(m) error("json: " .. m .. " @" .. pos, 0) end
  local function skip()
    while pos <= #str do
      local c = str:sub(pos, pos)
      if c == " " or c == "\t" or c == "\n" or c == "\r" then pos = pos + 1 else break end
    end
  end
  local parseValue
  local ESC = { n = "\n", t = "\t", r = "\r", b = "\b", f = "\f",
                ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
  local function parseString()
    if str:sub(pos, pos) ~= '"' then err("expected string") end
    pos = pos + 1
    local buf = {}
    while true do
      if pos > #str then err("unterminated string") end
      local c = str:sub(pos, pos)
      if c == '"' then pos = pos + 1; return table.concat(buf) end
      if c == "\\" then
        local e = str:sub(pos + 1, pos + 1)
        if ESC[e] then buf[#buf + 1] = ESC[e]; pos = pos + 2
        elseif e == "u" then buf[#buf + 1] = "?"; pos = pos + 6
        else err("bad escape") end
      else
        buf[#buf + 1] = c; pos = pos + 1
      end
    end
  end
  local function parseObject()
    pos = pos + 1; local o = {}; skip()
    if str:sub(pos, pos) == "}" then pos = pos + 1; return o end
    while true do
      skip()
      local k = parseString()
      skip()
      if str:sub(pos, pos) ~= ":" then err("expected :") end
      pos = pos + 1
      o[k] = parseValue()
      skip()
      local c = str:sub(pos, pos)
      if c == "," then pos = pos + 1
      elseif c == "}" then pos = pos + 1; return o
      else err("expected , or }") end
    end
  end
  local function parseArray()
    pos = pos + 1; local a = {}; skip()
    if str:sub(pos, pos) == "]" then pos = pos + 1; return a end
    while true do
      a[#a + 1] = parseValue()
      skip()
      local c = str:sub(pos, pos)
      if c == "," then pos = pos + 1
      elseif c == "]" then pos = pos + 1; return a
      else err("expected , or ]") end
    end
  end
  parseValue = function()
    skip()
    local c = str:sub(pos, pos)
    if c == "{" then return parseObject() end
    if c == "[" then return parseArray() end
    if c == '"' then return parseString() end
    if str:sub(pos, pos + 3) == "true"  then pos = pos + 4; return true end
    if str:sub(pos, pos + 4) == "false" then pos = pos + 5; return false end
    if str:sub(pos, pos + 3) == "null"  then pos = pos + 4; return nil end
    local n = str:match("^%-?%d+%.?%d*", pos)
    if n and #n > 0 then pos = pos + #n; return tonumber(n) end
    err("unexpected token")
  end
  local v = parseValue()
  skip()
  if pos <= #str then err("trailing data") end
  return v
end

local loader = load or loadstring
local chunk = extract(readAll(srcPath), "classifyHealthResponse")
  .. "\nreturn classifyHealthResponse\n"
local classify = assert(loader(chunk, "classifyHealthResponse"))()

-- 注入 test double；被測的仍是上面抽出來的同一份程式碼
local function fn(status, body) return (classify(status, body, jsonDecode)) end

local pass, fail = 0, 0
local function check(name, got, want)
  if got == want then
    pass = pass + 1; print("PASS " .. name)
  else
    fail = fail + 1
    print("FAIL " .. name .. " (got=" .. tostring(got) .. " want=" .. tostring(want) .. ")")
  end
end

-- ── 契約內：ready / loading ────────────────────────────────
check('200 {"status":"ok"} → ready',                fn(200, '{"status":"ok"}'), "ready")
check('200 額外欄位仍 ready',                        fn(200, '{"status":"ok","model":"small"}'), "ready")
check('200 前後空白仍 ready',                        fn(200, '  {"status":"ok"}  '), "ready")
check('503 {"status":"loading model"} → loading',   fn(503, '{"status":"loading model"}'), "loading")

-- ── 嚴格性：substring 判斷會誤判、JSON 判斷不會 ─────────────
check('200 {"status_message":"ok"} → foreign',      fn(200, '{"status_message":"ok"}'), "foreign")
check('200 {"status":"not ok"} → foreign',          fn(200, '{"status":"not ok"}'), "foreign")
check('200 純文字 "status check ok" → foreign',      fn(200, 'status check ok'), "foreign")
check('200 {"status":true}（非字串）→ foreign',      fn(200, '{"status":true}'), "foreign")
check('200 JSON 陣列 → foreign',                     fn(200, '[1,2,3]'), "foreign")
check('200 空 body → foreign',                       fn(200, ''), "foreign")
check('200 合法 JSON 但無 status → foreign',         fn(200, '{"unexpected":"shape"}'), "foreign")
check('200 nginx 首頁 → foreign',                    fn(200, '<html>nginx</html>'), "foreign")
check('200 malformed JSON → foreign',                fn(200, '{"status": '), "foreign")

-- ── 503 但不是 loading ─────────────────────────────────────
check('503 {"status":"error"} → foreign',            fn(503, '{"status":"error"}'), "foreign")
check('503 malformed JSON → foreign',                fn(503, '{status: broken'), "foreign")
check('503 空 body → foreign',                       fn(503, ''), "foreign")

-- ── 其他 HTTP status ───────────────────────────────────────
check('404 → foreign',                               fn(404, "Not Found"), "foreign")
check('500 → foreign',                               fn(500, "err"), "foreign")
check('403 → foreign',                               fn(403, ""), "foreign")
check('200 但 status 正確卻在 404 → foreign',         fn(404, '{"status":"ok"}'), "foreign")

-- ── 連線失敗 ───────────────────────────────────────────────
check("status=nil → unavailable",                    fn(nil, nil), "unavailable")
check("status=-1 → unavailable",                     fn(-1, nil),  "unavailable")
check("status=0 → unavailable",                      fn(0, nil),   "unavailable")

-- ── 沒有 decoder 可用時必須保守（不可回 ready）──────────────
check("無 JSON decoder → foreign",                   (classify(200, '{"status":"ok"}', false)), "foreign")

-- ── 關鍵語意不變式 ─────────────────────────────────────────
check("loading ≠ ready",       fn(503, '{"status":"loading model"}') ~= "ready", true)
check("foreign ≠ ready",       fn(200, '<html>nginx</html>') ~= "ready", true)
check("foreign ≠ unavailable（port 被占用，不是空的）",
                               fn(404, "x") ~= "unavailable", true)

-- ── 對真實 fake server 的觀測結果分類 ──────────────────────
local EXPECT = {
  ok = "ready", ok_extra = "ready",
  loading = "loading",
  status_message = "foreign", notok = "foreign", plaintext_ok = "foreign",
  status_bool = "foreign", json_array = "foreign", empty = "foreign",
  loading_error = "foreign", malformed503 = "foreign",
  notfound = "foreign", foreign = "foreign", malformed = "foreign",
  error = "foreign", refused = "unavailable",
}
if obsPath then
  local f = io.open(obsPath, "r")
  if f then
    for line in f:lines() do
      local scen, status, body = line:match("^([^\t]*)\t([^\t]*)\t(.*)$")
      if scen and EXPECT[scen] then
        local st = tonumber(status)
        if st == 0 then st = -1 end
        check("實測 /health 情境 '" .. scen .. "'", fn(st, body), EXPECT[scen])
      end
    end
    f:close()
  end
end

-- ── [HK1] maskIsSet：修飾鍵左右辨識的位元判斷 ─────────────
local maskChunk = extract(readAll(srcPath), "maskIsSet") .. "\nreturn maskIsSet\n"
local maskIsSet = assert(loader(maskChunk, "maskIsSet"))()

local RALT, LALT, RSHIFT = 0x40, 0x20, 0x04
check("右 Option 單獨按下 → 有設",        maskIsSet(RALT, RALT), true)
check("只按左 Option → 右 Option 未設",   maskIsSet(LALT, RALT), false)
check("左右 Option 同時 → 右 Option 有設", maskIsSet(RALT + LALT, RALT), true)
check("左右 Option 同時 → 左 Option 有設", maskIsSet(RALT + LALT, LALT), true)
check("放開全部 → 未設",                  maskIsSet(0, RALT), false)
check("其他修飾鍵不會誤判成右 Option",     maskIsSet(RSHIFT, RALT), false)
-- 真實 CGEventFlags 會同時含有粗粒度位元（alt = 0x00080000）
check("含粗粒度 alt 位元時仍能分辨右 Option",
      maskIsSet(0x00080000 + RALT, RALT), true)
check("含粗粒度 alt 位元但實際是左 Option",
      maskIsSet(0x00080000 + LALT, RALT), false)
check("flags 為 nil → false（不誤觸發）",  maskIsSet(nil, RALT), false)
check("mask 為 0 → false",                 maskIsSet(RALT, 0), false)

-- ── [CB2] restoreClipboardEntries：pcall 與回傳值兩層都要檢查 ──────
-- writeDataForUTI 在真實 runtime 幾乎不回 false（實測空 UTI、非法 UTI、
-- 不存在的 pasteboard 名稱全都回 true），所以失敗路徑只能靠注入 writer
-- 來驗證。這裡執行的是從 ptt_whisper.lua 抽出的同一份出貨程式碼。
local restoreChunk = extract(readAll(srcPath), "restoreClipboardEntries")
  .. "\nreturn restoreClipboardEntries\n"
local restoreEntries = assert(loader(restoreChunk, "restoreClipboardEntries"))()

local ENTRIES = {
  { uti = "public.utf8-plain-text", data = "A" },
  { uti = "public.rtf",             data = "B" },
  { uti = "public.html",            data = "C" },
}

-- case A：pcall 成功 + 回 true → 計入
local addLog = {}
local n = restoreEntries(ENTRIES, function(_, _, add)
  addLog[#addLog + 1] = add; return true
end)
check("A. 全部成功 → wrote = 3", n, 3)
check("A. 第一筆 add=false", addLog[1], false)
check("A. 第二筆 add=true",  addLog[2], true)
check("A. 第三筆 add=true",  addLog[3], true)

-- case B：pcall 成功但回 false → 不可計入
n = restoreEntries(ENTRIES, function() return false end)
check("B. 回 false → wrote = 0（不可誤算成功）", n, 0)

-- case C：writer 拋出錯誤 → 不可計入
n = restoreEntries(ENTRIES, function() error("boom") end)
check("C. writer throw → wrote = 0", n, 0)

-- case D：全部失敗 → wrote = 0，純文字 fallback 才有機會被觸發
n = restoreEntries(ENTRIES, function() return nil end)
check("D. 回 nil → wrote = 0（fallback 可達）", n, 0)

-- 關鍵：第一筆失敗時，第二筆仍必須以 add=false 開始。
-- 否則會疊加到剪貼簿上殘留的轉錄文字，而不是取代它。
addLog = {}
local callCount = 0
n = restoreEntries(ENTRIES, function(_, _, add)
  callCount = callCount + 1
  addLog[#addLog + 1] = add
  return callCount > 1          -- 第一筆失敗，其餘成功
end)
check("第一筆失敗 → wrote = 2", n, 2)
check("第一筆 add=false", addLog[1], false)
check("第一筆失敗後，第二筆仍是 add=false（不可疊加）", addLog[2], false)
check("第三筆才變 add=true", addLog[3], true)

-- 中間失敗不應該讓已成功的部分被重新清空
addLog = {}; callCount = 0
n = restoreEntries(ENTRIES, function(_, _, add)
  callCount = callCount + 1
  addLog[#addLog + 1] = add
  return callCount ~= 2         -- 第二筆失敗
end)
check("中間失敗 → wrote = 2", n, 2)
check("中間失敗後，第三筆維持 add=true（不重新清空）", addLog[3], true)

check("空清單 → wrote = 0", restoreEntries({}, function() return true end), 0)

print(string.format("-- lua units: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
