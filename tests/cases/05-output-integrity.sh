source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
t_sandbox; t_model ggml-small-q5_1.bin
echo "  [O] 輸出完整性"

# 真機驗證抓到的 blocker：whisper-cli 同時把文字印到 stdout 和寫進 -otxt，
# 而 run_whisper 只導走 stderr，導致每次轉錄的文字被輸出兩次。
# fake-whisper-cli 現在也會印 stdout，這組斷言把這個迴歸鎖住。

t_reset_log
out=$(t_run "FAKE_TEXT=hello world")
assert_eq "輸出剛好等於轉錄結果（沒有重複）" "$out" "hello world"

n=$(printf '%s' "$out" | grep -o 'hello world' | grep -c .)
assert_eq "文字只出現一次" "$n" "1"

lines=$(printf '%s\n' "$out" | grep -c .)
assert_eq "輸出只有一行" "$lines" "1"

# 中文與含空白的文字也一樣
out=$(t_run "FAKE_TEXT=這是一個真機測試")
assert_eq "中文輸出不重複" "$out" "這是一個真機測試"

# server 路徑本來就沒有這個問題，一併鎖住
M="$T_WD/models/ggml-small-q5_1.bin"
t_server_start ok ok
t_reset_log
out=$(t_run "WHISPER_SERVER=true" "WHISPER_SERVER_URL=$(t_server_url)" \
            "WHISPER_SERVER_MODEL=$M")
assert_eq "server 路徑輸出不重複" "$out" "server transcription result"
t_server_stop

# 退回 CLI 的路徑也不能重複
t_reset_log
out=$(t_run "WHISPER_SERVER=true" "WHISPER_SERVER_URL=http://127.0.0.1:$T_PORT" \
            "WHISPER_SERVER_MODEL=$M" "FAKE_TEXT=fallback text")
assert_eq "server 失敗退回 CLI 後輸出不重複" "$out" "fallback text"

t_teardown; t_summary "O output integrity"
