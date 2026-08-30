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

print(string.format("-- lua units: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
