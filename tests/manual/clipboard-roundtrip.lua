-- 剪貼簿存／還原的往返驗證。
-- 這一層無法用 shell 測試套件覆蓋——它依賴 Hammerspoon 的 hs.pasteboard，
-- 而 hs.pasteboard 只存在於 Hammerspoon runtime。
--
-- 用法：在 ~/.hammerspoon/init.lua 尾端加入
--     dofile(os.getenv("HOME") .. "/ptt-whisper/tests/manual/clipboard-roundtrip.lua")
-- 重載 Hammerspoon 後結果會寫到 /tmp/clipboard_roundtrip.txt
--
-- 背景：writeDataForUTI 的第 4 個參數 add 預設為 false，每次呼叫都會先清空
-- 剪貼簿。不帶這個參數的迴圈跑完只剩最後一個 UTI，從文件複製的多型別內容
-- 會整個消失。單一型別（純文字）不會出事，所以很容易漏掉。
--
-- 涵蓋範圍分工（不要誤以為這支腳本涵蓋全部）：
--
--   這支手動腳本      真實 hs.pasteboard 的多型別往返（成功路徑）
--   ./tests/run.sh    寫入失敗的語意（pcall 成功但回 false／writer throw／
--                     全部失敗時 fallback 可達／第一筆失敗後 add 仍為 false）
--                     —— 見 tests/test-lua-units.lua 的 restoreClipboardEntries
--
-- 失敗路徑之所以只能靠注入 writer 測：實測 writeDataForUTI 在這個
-- Hammerspoon 版本用空 UTI、非法 UTI、不存在的 pasteboard 名稱都回 true，
-- 無法在真實 runtime 逼出 false。
hs.timer.doAfter(2, function()
  local out = {}
  local function log(s) out[#out + 1] = s end
  local pass, fail = 0, 0
  local function check(name, got, want)
    if got == want then pass = pass + 1; log("PASS " .. name)
    else fail = fail + 1; log("FAIL " .. name .. "  got=" .. tostring(got)) end
  end

  local MARK = "剪貼簿往返測試-ABC123"

  -- 建一個「像從文件複製」的多型別剪貼簿
  hs.pasteboard.clearContents()
  hs.pasteboard.writeDataForUTI(nil, "public.utf8-plain-text", MARK, false)
  hs.pasteboard.writeDataForUTI(nil, "public.rtf", "{\\rtf1\\ansi " .. MARK .. "}", true)
  hs.pasteboard.writeDataForUTI(nil, "public.html", "<p>" .. MARK .. "</p>", true)

  local types = hs.pasteboard.contentTypes()
  log("原始 UTI: " .. table.concat(types, " | "))
  check("多型別剪貼簿建立成功", #types >= 3, true)

  local saved = {}
  for _, ct in ipairs(types) do
    local ok, data = pcall(hs.pasteboard.readDataForUTI, nil, ct)
    if ok and data then saved[#saved + 1] = { uti = ct, data = data } end
  end
  check("所有型別都能讀出", #saved, #types)

  -- 模擬語音輸入覆蓋剪貼簿
  hs.pasteboard.setContents("這是語音轉錄的文字")
  check("剪貼簿確實被覆蓋", hs.pasteboard.getContents(), "這是語音轉錄的文字")

  -- 還原（與 ptt_whisper.lua 的 restoreClipboard 相同邏輯）
  local wrote = 0
  for _, e in ipairs(saved) do
    if pcall(hs.pasteboard.writeDataForUTI, nil, e.uti, e.data, wrote > 0) then
      wrote = wrote + 1
    end
  end

  check("純文字內容正確還原", hs.pasteboard.getContents(), MARK)
  check("所有型別都還原", #hs.pasteboard.contentTypes(), #types)

  log(string.format("-- clipboard roundtrip: %d passed, %d failed", pass, fail))
  local f = io.open("/tmp/clipboard_roundtrip.txt", "w")
  if f then f:write(table.concat(out, "\n") .. "\n"); f:close() end
end)
