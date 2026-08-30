-- 從 ptt_whisper.lua 抽出 [TESTABLE:...] 區塊直接執行，
-- 驗證的是「實際出貨的那段程式碼」，不是複製一份來測。
-- 用法： lua tests/test-lua-units.lua <ptt_whisper.lua> <observations.tsv>
local srcPath, obsPath = arg[1], arg[2]

local function readAll(p)
  local f = assert(io.open(p, "r"), "cannot open " .. tostring(p))
  local c = f:read("*a"); f:close(); return c
end

local function extract(src, name)
  local pat = "%-%- %[TESTABLE:" .. name .. "%](.-)%-%- %[/TESTABLE%]"
  local block = src:match(pat)
  assert(block, "找不到 TESTABLE 區塊: " .. name)
  return block
end

local loader = load or loadstring
local src = readAll(srcPath)
local chunk = extract(src, "classifyHealthResponse")
  .. "\nreturn classifyHealthResponse\n"
local fn = assert(loader(chunk, "classifyHealthResponse"))()

local pass, fail = 0, 0
local function check(name, got, want)
  if got == want then
    pass = pass + 1; print("PASS " .. name)
  else
    fail = fail + 1
    print("FAIL " .. name .. " (got=" .. tostring(got) .. " want=" .. tostring(want) .. ")")
  end
end

-- ── 決策表（不依賴外部觀測）────────────────────────────────
check("status=nil → unavailable",        (fn(nil, nil)),  "unavailable")
check("status=-1 → unavailable",         (fn(-1, nil)),   "unavailable")
check("status=0 → unavailable",          (fn(0, nil)),    "unavailable")
check("200 + status/ok → ready",         (fn(200, '{"status":"ok"}')), "ready")
check("200 + 額外欄位仍 ready",           (fn(200, '{"status":"ok","model":"small"}')), "ready")
check("200 + 大寫 STATUS/OK → ready",     (fn(200, '{"STATUS":"OK"}')), "ready")
check("503 → loading",                   (fn(503, '{"status":"loading model"}')), "loading")
check("503 空 body → loading",            (fn(503, nil)),  "loading")
check("200 + nginx 首頁 → foreign",       (fn(200, "<html>nginx</html>")), "foreign")
check("200 + 空 body → foreign",          (fn(200, "")),   "foreign")
check("404 → foreign",                   (fn(404, "Not Found")), "foreign")
check("500 → foreign",                   (fn(500, "err")), "foreign")
check("403 → foreign",                   (fn(403, "")),   "foreign")

-- 關鍵語意：行程活著 ≠ 模型可用；port 有人聽 ≠ 有效 whisper-server
check("loading 不等於 ready",  (fn(503, '{"status":"loading model"}')) ~= "ready", true)
check("foreign 不等於 ready",  (fn(200, "<html>nginx</html>")) ~= "ready", true)
check("foreign 不等於 unavailable（port 被占用，不是空的）",
      (fn(404, "x")) ~= "unavailable", true)

-- ── 對真實 fake server 的觀測結果分類 ──────────────────────
local EXPECT = {
  loading = "loading", ok = "ready", notfound = "foreign",
  foreign = "foreign", malformed = "foreign", error = "foreign",
  refused = "unavailable",
}
if obsPath then
  local f = io.open(obsPath, "r")
  if f then
    for line in f:lines() do
      local scen, status, body = line:match("^([^\t]*)\t([^\t]*)\t(.*)$")
      if scen and EXPECT[scen] then
        local st = tonumber(status)
        if st == 0 or st == -1 then st = -1 end
        check("實測 /health 情境 '" .. scen .. "'", (fn(st, body)), EXPECT[scen])
      end
    end
    f:close()
  end
end

print(string.format("-- lua units: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
