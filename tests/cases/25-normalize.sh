source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
t_sandbox; t_model ggml-small-q5_1.bin
echo "  [N] 響度正規化（loudnorm 移進管線）"

FFMPEG_BIN=""
for c in /opt/homebrew/bin/ffmpeg /usr/local/bin/ffmpeg /usr/bin/ffmpeg; do
  [[ -x "$c" ]] && { FFMPEG_BIN="$c"; break; }
done

# t_reset_log 只清 arglog/reqlog；ptt_whisper_err.log 是累積的，
# 「這一次沒有出現 X」這種斷言必須先把它清掉，否則會讀到上一次的內容。
t_reset_ptt() { mkdir -p "$T_PTT"; : > "$T_PTT/ptt_whisper_err.log"; }
# 快取是跨 t_run 累積的。斷言「這次存了什麼 key」之前必須清掉，
# 否則會變成 CACHE HIT（不寫 CACHE STORE），key 抓不到而誤報。
t_reset_cache() { rm -f "$T_PTT"/cache/*.txt 2>/dev/null || true; }

# ── 預設關閉：終端機直接呼叫的行為不能被改變 ────────────────
t_reset_log; t_reset_ptt; out=$(t_run)
assert_eq           "預設不做正規化 → 仍正常轉錄" "$out" "hello world"
assert_not_contains "預設不做正規化 → log 無 normalized" "$(t_log)" "normalized"
assert_contains     "預設送進推理的就是原始檔" "$(t_args)" "$WAV"

# ── 明確開啟 ────────────────────────────────────────────────
if [[ -z "$FFMPEG_BIN" ]]; then
  t_skip "開啟正規化的所有斷言" "ffmpeg 不存在"
else
  t_reset_log; t_reset_ptt; out=$(t_run "WHISPER_NORMALIZE=true")
  assert_eq       "開啟後仍正常轉錄" "$out" "hello world"
  assert_contains "log 記錄已正規化" "$(t_log)" "INFO: normalized"
  assert_contains "log 記錄用的濾波器" "$(t_log)" "loudnorm=I=-16:TP=-1.5"

  # 送進 whisper 的必須是正規化後的暫存檔，不是原始檔
  assert_contains     "推理拿到的是 ptt_norm_ 暫存檔" "$(t_args)" "ptt_norm_"
  assert_not_contains "推理拿到的不是原始檔" "$(t_args)" "$WAV"

  # 暫存檔必須被清乾淨（cleanup trap）
  leftover=$(ls "$T_PTT"/ptt_norm_* 2>/dev/null | wc -l | tr -d ' ')
  assert_eq "正規化暫存檔已清除" "$leftover" "0"

  # ── 取樣率必須維持 16kHz ──────────────────────────────────
  # loudnorm 內部以 192kHz 運作，正規化指令若漏掉 -ar 16000，產出的檔案
  # 就是 192kHz（已實測確認）。whisper.cpp 只吃 16kHz，餵錯結果會是垃圾，
  # 而且不會有任何錯誤訊息——正是那種「測不到就會長回來」的坑。
  t_reset_log; t_reset_ptt
  out=$(t_run "WHISPER_NORMALIZE=true" "FAKE_ECHO_SR=1")
  assert_eq "正規化後送進推理的仍是 16kHz" "$out" "sr:16000"

  t_reset_log; t_reset_ptt
  out=$(t_run "FAKE_ECHO_SR=1")
  assert_eq "不正規化時本來就是 16kHz（對照組）" "$out" "sr:16000"
fi

# ── 非法值 ──────────────────────────────────────────────────
t_reset_log; t_reset_ptt; out=$(t_run "WHISPER_NORMALIZE=maybe")
assert_eq       "非法值 → 不中止，照常轉錄" "$out" "hello world"
assert_contains "非法值 → log 警告" "$(t_log)" "invalid WHISPER_NORMALIZE"
assert_not_contains "非法值 → 不做正規化" "$(t_log)" "INFO: normalized"

# ── 正規化失敗 → 降級用原始音訊，不讓整次轉錄失敗 ──────────
# （「ffmpeg 完全不存在」這條路徑測不到：find_ffmpeg 走的是絕對路徑，
#   PATH 蓋不掉。這裡測的是「ffmpeg 在，但這個檔案它解不開」。）
if [[ -n "$FFMPEG_BIN" ]]; then
  BAD="$T_DIR/undecodable.wav"
  head -c 4096 /dev/zero | tr '\0' 'Z' > "$BAD"    # 夠大不會被 size 檢查擋下，但不是合法音訊
  t_reset_log; t_reset_ptt
  out=$(t_run "WHISPER_NORMALIZE=true" -- "$BAD"); rc=$?
  assert_eq       "正規化失敗 → 整次轉錄仍成功" "$out" "hello world"
  [[ $rc -eq 0 ]] && _t_ok "正規化失敗 → exit 0" || _t_bad "正規化失敗不該讓 exit 非零"
  assert_contains "正規化失敗 → log 說明降級" "$(t_log)" "normalize failed"
  assert_contains "正規化失敗 → stderr 有 Warning" "$(t_stderr)" "normalize failed"
  assert_contains "正規化失敗 → 推理拿到的是原始檔" "$(t_args)" "$BAD"
  leftover=$(ls "$T_PTT"/ptt_norm_* 2>/dev/null | wc -l | tr -d ' ')
  assert_eq       "正規化失敗 → 暫存檔已清除" "$leftover" "0"

  # ── [N5] 正規化失敗時，快取身分必須說實話 ──────────────────
  # 失敗時轉錄的是「未正規化」的音訊。若仍存進 normalize=true 的身分，
  # 之後 ffmpeg 恢復正常，查到的會是那筆髒資料——而且永遠不會被更新。
  # 這與既有的「identity 描述實際完成推理的 backend」是同一條原則。
  ckey() { grep -o 'CACHE STORE ([^)]*): [^ ]*' "$T_PTT/ptt_whisper_err.log" | tail -1 | sed 's/.*: //'; }

  t_reset_log; t_reset_ptt; t_reset_cache
  t_run "WHISPER_CACHE=true" -- "$BAD" >/dev/null
  key_plain=$(ckey)

  t_reset_log; t_reset_ptt; t_reset_cache
  t_run "WHISPER_CACHE=true" "WHISPER_NORMALIZE=true" -- "$BAD" >/dev/null
  key_failed=$(ckey)

  t_reset_log; t_reset_ptt; t_reset_cache
  t_run "WHISPER_CACHE=true" "WHISPER_NORMALIZE=true" >/dev/null   # 正常檔案，會成功
  key_ok=$(ckey)

  assert_eq "正規化失敗 → 存進 normalize=false 的身分（與沒要求時相同）" \
            "$key_failed" "$key_plain"
  [[ -n "$key_ok" && "$key_ok" != "$key_failed" ]] \
    && _t_ok "正規化成功 → 身分與失敗時不同" \
    || _t_bad "正規化成功時的 key 應與失敗時不同（key_ok=${key_ok}）"
fi

# ── 快取 identity 必須把正規化算進去 ────────────────────────
if [[ -n "$FFMPEG_BIN" ]]; then
  t_reset_log; t_reset_ptt; t_reset_cache
  t_run "WHISPER_CACHE=true" >/dev/null
  key_off=$(ckey)
  t_reset_log; t_reset_ptt; t_reset_cache
  t_run "WHISPER_CACHE=true" "WHISPER_NORMALIZE=true" >/dev/null
  key_on=$(ckey)
  [[ -n "$key_off" && -n "$key_on" && "$key_off" != "$key_on" ]] \
    && _t_ok "開關正規化 → 快取 key 不同（不會互相污染）" \
    || _t_bad "開關正規化的 key 應不同（off=${key_off} on=${key_on}）"
fi

t_teardown; t_summary "N 響度正規化"
