source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
t_sandbox; t_model ggml-small-q5_1.bin
echo "  [D2] 快取 identity = 實際推理行為（非 preference）"
M="$T_WD/models/ggml-small-q5_1.bin"
# 每個情境用不同 prompt，確保各自獨立的 cache namespace，不互相污染
srv() { local p="$1"; shift
  t_run "WHISPER_SERVER=true" "WHISPER_SERVER_URL=$(t_server_url)" \
        "WHISPER_SERVER_MODEL=$M" "WHISPER_CACHE=true" "WHISPER_PROMPT=$p" "$@"; }
backend() { cat "$T_PTT/last_backend.txt" 2>/dev/null; }

# ═══ 核心迴歸：preference=server 但實際由 CLI 完成 ═══════════
t_server_start ok error
t_reset_log; out=$(srv scenA "FAKE_TEXT=cli-produced-A")
assert_eq "server 失敗 → CLI 完成"  "$out" "cli-produced-A"
assert_eq "後端標記 = cli"           "$(backend)" "cli"
assert_contains     "以 cli identity 寫入快取"   "$(t_log)" "CACHE STORE (cli)"
assert_not_contains "不可寫成 server identity"   "$(t_log)" "CACHE STORE (server)"
t_server_stop

t_server_start ok ok
t_reset_log; out=$(srv scenA)
assert_eq "server 恢復 → 必須真的問 server，不可回傳 CLI 產生的舊快取" \
          "$out" "server transcription result"
assert_eq "後端標記 = server" "$(backend)" "server"
assert_eq "確實發出了 HTTP 請求" "$(t_req_count)" "1"
t_server_stop

# ═══ 降級狀態下，CLI 的快取仍可被利用（第二次查詢）══════════
t_server_start ok error
t_reset_log; out=$(srv scenB "FAKE_TEXT=cli-produced-B")
assert_eq "情境 B 首次：CLI 產生" "$out" "cli-produced-B"
t_reset_log; out=$(srv scenB "FAKE_TEXT=SHOULD-NOT-RUN")
assert_eq "server 仍失敗 → 命中 CLI namespace 的快取" "$out" "cli-produced-B"
assert_eq "命中後不再呼叫 whisper" "$(t_runs)" "0"
assert_contains "log 顯示 CLI namespace 命中" "$(t_log)" "CACHE HIT (cli)"
assert_eq "後端標記標示來源是快取" "$(backend)" "cache:cli"
t_server_stop

# ═══ server 正常時的快取命中 ════════════════════════════════
t_server_start ok ok
t_reset_log; srv scenC >/dev/null
t_reset_log; out=$(srv scenC "FAKE_SERVER_TEXT=SHOULD-NOT-BE-ASKED")
assert_eq "server namespace 快取命中" "$out" "server transcription result"
assert_eq "命中 → 不發 HTTP 請求"     "$(t_req_count)" "0"
assert_eq "後端標記 = cache:server"   "$(backend)" "cache:server"
t_server_stop

# ═══ 純 CLI 模式（未開 server）══════════════════════════════
t_reset_log; out=$(t_run "WHISPER_CACHE=true" "WHISPER_PROMPT=scenD" "FAKE_TEXT=plain-cli")
assert_eq "純 CLI 首次"     "$out" "plain-cli"
assert_eq "純 CLI 後端標記" "$(backend)" "cli"
t_reset_log; out=$(t_run "WHISPER_CACHE=true" "WHISPER_PROMPT=scenD" "FAKE_TEXT=SHOULD-NOT-RUN")
assert_eq "純 CLI 命中快取" "$out" "plain-cli"
assert_eq "純 CLI 命中標記" "$(backend)" "cache:cli"

# ═══ 未開快取時，backend 標記仍需正確 ═══════════════════════
t_server_start ok error
t_reset_log; out=$(t_run "WHISPER_SERVER=true" "WHISPER_SERVER_URL=$(t_server_url)" \
                         "WHISPER_SERVER_MODEL=$M" "FAKE_TEXT=nocache")
assert_eq "未開快取 + server 失敗 → cli 標記" "$(backend)" "cli"
t_server_stop

t_teardown; t_summary "D2 cache backend identity"
