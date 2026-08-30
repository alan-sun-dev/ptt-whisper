source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
t_sandbox; t_model ggml-small-q5_1.bin
echo "  [E] Server backend"
M="$T_WD/models/ggml-small-q5_1.bin"
srv() { t_run "WHISPER_SERVER=true" "WHISPER_SERVER_URL=$(t_server_url)" \
              "WHISPER_SERVER_MODEL=$M" "$@"; }
backend() { cat "$T_PTT/last_backend.txt" 2>/dev/null; }

t_server_start ok ok
t_reset_log; out=$(srv)
assert_eq "server 成功 → 使用 server 結果" "$out" "server transcription result"
assert_eq "server 成功 → 完全沒呼叫 CLI"   "$(t_runs)" "0"
assert_eq "後端標記 = server"              "$(backend)" "server"
assert_eq "打的是 /inference"              "$(python3 -c "
import json;print(json.loads(open('$T_REQLOG').readline())['path'])")" "/inference"
t_server_stop

t_server_start ok error
t_reset_log; out=$(srv "FAKE_TEXT=cli-fb")
assert_eq "HTTP 500 → 退回 CLI"     "$out" "cli-fb"
assert_eq "退回 CLI → 呼叫 1 次 CLI" "$(t_runs)" "1"
assert_eq "後端標記 = cli"           "$(backend)" "cli"
t_server_stop

t_server_start ok empty
t_reset_log; out=$(srv "FAKE_TEXT=cli-fb")
assert_eq "空回應 → 退回 CLI" "$out" "cli-fb"
assert_contains "log 記錄空回應" "$(t_log)" "empty body"
t_server_stop

t_server_start ok json
t_reset_log; out=$(srv "FAKE_TEXT=cli-fb")
assert_eq "JSON 回應 → 退回 CLI（不把 JSON 當結果）" "$out" "cli-fb"
assert_not_contains "輸出不含 JSON 內容" "$out" "json shaped"
assert_contains "log 記錄非預期 JSON" "$(t_log)" "returned JSON"
t_server_stop

t_reset_log; out=$(srv "FAKE_TEXT=cli-fb")
assert_eq "連線被拒 → 退回 CLI" "$out" "cli-fb"
assert_contains "log 記錄 curl 失敗" "$(t_log)" "curl exit=7"

t_server_start ok ok
t_reset_log
out=$(t_run "WHISPER_SERVER=true" "WHISPER_SERVER_URL=$(t_server_url)" \
            "WHISPER_SERVER_MODEL=/other/model.bin" "FAKE_TEXT=cli-fb")
assert_eq "模型與 server 不符 → 走 CLI" "$out" "cli-fb"
assert_eq "模型不符 → 完全不發 HTTP 請求" "$(t_req_count)" "0"
assert_contains "log 記錄模型不符" "$(t_log)" "model differs from server"
t_server_stop

# ── multipart 欄位 ─────────────────────────────────────────
t_server_start ok ok
t_reset_log
srv "WHISPER_PROMPT=gRPC, Kubernetes" "WHISPER_MAX_CONTEXT=32" -- "$WAV" zh >/dev/null
assert_eq "送出 language"        "$(t_req_field language)" "zh"
assert_eq "送出 prompt"          "$(t_req_field prompt)" "gRPC, Kubernetes"
assert_eq "送出 max_context"     "$(t_req_field max_context)" "32"
assert_eq "送出 response_format" "$(t_req_field response_format)" "text"
assert_eq "送出 no_timestamps"   "$(t_req_field no_timestamps)" "true"
assert_contains "送出音訊檔"     "$(t_req_fields)" "<file:"

# ── multipart 字面值安全性（--form-string 迴歸）──────────────
echo "LOCAL-FILE-SHOULD-NOT-LEAK" > "$T_DIR/secret.txt"
t_reset_log
srv "WHISPER_PROMPT=@$T_DIR/secret.txt" >/dev/null
assert_eq "prompt 以 @ 開頭 → 當字面值，不讀本機檔案" \
          "$(t_req_field prompt)" "@$T_DIR/secret.txt"
assert_not_contains "本機檔案內容沒有外洩" "$(t_req_fields)" "LOCAL-FILE-SHOULD-NOT-LEAK"

t_reset_log
srv "WHISPER_PROMPT=<angle> \"quoted\" 中文 🎤" >/dev/null
assert_eq "prompt 含 < \" 中文 emoji → 原樣送出" \
          "$(t_req_field prompt)" '<angle> "quoted" 中文 🎤'
t_server_stop

t_teardown; t_summary "E server"
