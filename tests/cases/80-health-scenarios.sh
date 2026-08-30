source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
t_sandbox
echo "  [H] Server readiness 情境（/health 契約 + Lua 分類器）"

CAP="$T_DIR/health-observations.txt"; : > "$CAP"

# 對每個情境實際打 /health，記錄 (scenario, status, body)，
# 之後餵給 Lua 的 classifyHealthResponse 驗證分類正確。
probe() { # probe <scenario> <expected_status>
  local mode="$1" expect="$2"
  if [[ "$mode" == "refused" ]]; then
    local st; st=$(curl -s -o "$T_DIR/body" -w '%{http_code}' -m 2 \
                   "http://127.0.0.1:$T_PORT/health" 2>/dev/null) || st="000"
    assert_eq "connection refused → curl 無法取得 HTTP status" "$st" "000"
    printf '%s\t%s\t%s\n' "$mode" "-1" "" >> "$CAP"
    return
  fi
  t_server_start "$mode" ok
  local st; st=$(curl -s -o "$T_DIR/body" -w '%{http_code}' -m 2 \
                 "http://127.0.0.1:$T_PORT/health")
  local body; body=$(tr -d '\n' < "$T_DIR/body")
  assert_eq "$mode → HTTP $expect" "$st" "$expect"
  printf '%s\t%s\t%s\n' "$mode" "$st" "$body" >> "$CAP"
  t_server_stop
}

# whisper.cpp server 的正式契約
probe ok             200
probe loading        503
probe ok_extra       200
# 曾經會被 substring 判斷誤判成 ready 的情境
probe status_message 200
probe notok          200
probe plaintext_ok   200
probe status_bool    200
probe json_array     200
probe empty          200
# 503 但不是 loading
probe loading_error  503
probe malformed503   503
# 其他服務 / 錯誤
probe notfound       404
probe foreign        200
probe malformed      200
probe error          500
probe refused        000

echo "    ── Lua classifyHealthResponse 分類驗證 ──"
LUA_BIN=""
for c in lua lua5.4 lua5.3 luajit; do
  command -v "$c" >/dev/null 2>&1 && { LUA_BIN="$c"; break; }
done
if [[ -z "$LUA_BIN" ]]; then
  t_skip "Lua 分類器單元測試" "本機沒有 lua 直譯器；安裝後 (brew install lua) 會自動執行"
  echo "    ⚠️  REAL HAMMERSPOON TEST REQUIRED：readiness 分類尚未由直譯器驗證"
else
  if "$LUA_BIN" "$TESTS/test-lua-units.lua" "$REPO/ptt_whisper.lua" "$CAP" > "$T_DIR/luaout" 2>&1; then
    while IFS= read -r line; do _t_ok "$line"; done < <(grep '^PASS ' "$T_DIR/luaout" | cut -d' ' -f2-)
  else
    while IFS= read -r line; do _t_bad "$line"; done < <(grep '^FAIL ' "$T_DIR/luaout" | cut -d' ' -f2-)
    while IFS= read -r line; do _t_ok  "$line"; done < <(grep '^PASS ' "$T_DIR/luaout" | cut -d' ' -f2-)
    grep -qv '^\(PASS\|FAIL\) ' "$T_DIR/luaout" && cat "$T_DIR/luaout"
  fi
fi

t_teardown; t_summary "H health scenarios"
