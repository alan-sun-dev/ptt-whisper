#!/usr/bin/env bash
# ============================================================
# transcribe.sh v2.8.4 — PTT Whisper 轉錄腳本
#
# 搭配 ptt_whisper.lua v3.6.4 使用
# 用法：transcribe.sh /path/to/audio.wav [language] [model_path]
#   language   — 覆寫 WHISPER_LANG（如 en, zh, ja）
#                空字串 "" 或 "auto" = 不帶 -l，讓 whisper.cpp 自行偵測
#   model_path — 覆寫 WHISPER_MODEL
#                可為完整路徑或檔名（自動加 WHISPER_DIR/models/ 前綴）
#                空字串 "" = 使用預設
# 輸出：轉錄文字寫到 stdout（單行，去頭尾空白，含 trailing newline）
#
# v2.8.4 修正（第四輪 Code Review）：
#  CR12.[Fix]  LRU 快取清理的 stat 加入 Linux fallback（跨平台安全）
#  CR13.[Perf] 幻覺比對從 O(N) forks 降為 O(1) forks（批次 normalize + grep）
#
# v2.8.3：CR7~CR10（第三輪 Code Review）
# v2.8.2：OPT2（推理效能）
# v2.8.1：CR2,CR6,CRx（第二輪 Code Review）
# v2.8.0：P1,B2  v2.7.1：R1~R4  v2.7：F4,F6
# v2.6.1：R1~R5  v2.6：F1~F3  v2.5：#20~#23  v2.4：#18~#19
# v2.3：#16~#17  v2.2：#10~#15  v2.1：#8~#9  v2：#1~#7
# ============================================================
set -euo pipefail
umask 077

# [CR6] 統一 locale — 確保 sed/sort/字元類在所有系統上行為一致
# 這防止例如 [[:space:]] 在不同 locale 下包含不同字元的問題
# [CR10] 注意：LC_ALL=C 下字元類（如 [[:space:]]）只匹配 ASCII 範圍，
# 全形空白 U+3000 不會被自動捕捉，需在 normalize_text() 中顯式處理。
# 這是刻意的 trade-off：犧牲全形字元的自動匹配，換取跨系統的一致性。
export LC_ALL=C

# ── 設定區 ───────────────────────────────────────────────────
WHISPER_DIR="${WHISPER_DIR:-$HOME/whisper.cpp}"
# [OPT2] 預設優先 Q5_0 量化版，fallback 到 FP16
if [[ -n "${WHISPER_MODEL:-}" ]]; then
  MODEL="$WHISPER_MODEL"
elif [[ -f "$WHISPER_DIR/models/ggml-small-q5_0.bin" ]]; then
  MODEL="$WHISPER_DIR/models/ggml-small-q5_0.bin"
else
  MODEL="$WHISPER_DIR/models/ggml-small.bin"
fi
LANGUAGE="${WHISPER_LANG:-auto}"
TIMEOUT_SEC="${WHISPER_TIMEOUT:-60}"
AUTO_RESAMPLE="${WHISPER_AUTO_RESAMPLE:-true}"

# [F4] 快取設定
CACHE_ENABLED="${WHISPER_CACHE:-false}"
CACHE_MAX="${WHISPER_CACHE_MAX:-50}"
CACHE_MAX="${CACHE_MAX//[^0-9]/}"
: "${CACHE_MAX:=50}"
if (( CACHE_MAX < 5 )); then CACHE_MAX=5; fi
if (( CACHE_MAX > 500 )); then CACHE_MAX=500; fi

# [F6] Fallback model
FALLBACK_MODEL="${WHISPER_FALLBACK_MODEL:-}"

# 路徑
PTT_DIR="$HOME/.ptt-whisper"
LOG_FILE="$PTT_DIR/ptt_whisper_err.log"
OUT_PREFIX="$PTT_DIR/ptt_whisper_out"
CACHE_DIR="$PTT_DIR/cache"

# [P1] 幻覺列表路徑
BUILTIN_HALLUCINATION_FILE="$PTT_DIR/hallucinations_builtin.txt"
USER_HALLUCINATION_FILE="$PTT_DIR/hallucinations.txt"

# ── 輸入驗證 ─────────────────────────────────────────────────
AUDIO_FILE="${1:-}"
if [[ -z "$AUDIO_FILE" ]]; then
  echo "Usage: transcribe.sh /path/to/audio.wav [language] [model_path]" >&2
  exit 1
fi
if [[ ! -f "$AUDIO_FILE" ]]; then
  echo "Error: audio file not found: $AUDIO_FILE" >&2
  exit 1
fi

# 語言/模型覆寫
LANG_OVERRIDE="${2:-}"
MODEL_OVERRIDE="${3:-}"
if [[ -n "$LANG_OVERRIDE" ]]; then
  LANGUAGE="$LANG_OVERRIDE"
fi
if [[ -n "$MODEL_OVERRIDE" ]]; then
  if [[ "$MODEL_OVERRIDE" == /* ]]; then
    MODEL="$MODEL_OVERRIDE"
  else
    MODEL="$WHISPER_DIR/models/$MODEL_OVERRIDE"
  fi
fi

# [F6] 解析 fallback model 路徑
FALLBACK_MODEL_RESOLVED=""
if [[ -n "$FALLBACK_MODEL" ]]; then
  if [[ "$FALLBACK_MODEL" == /* ]]; then
    FALLBACK_MODEL_RESOLVED="$FALLBACK_MODEL"
  else
    FALLBACK_MODEL_RESOLVED="$WHISPER_DIR/models/$FALLBACK_MODEL"
  fi
  if [[ "$FALLBACK_MODEL_RESOLVED" == "$MODEL" ]]; then
    FALLBACK_MODEL_RESOLVED=""
  elif [[ ! -f "$FALLBACK_MODEL_RESOLVED" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: fallback model not found: $FALLBACK_MODEL_RESOLVED" >> "$LOG_FILE" 2>/dev/null || true
    FALLBACK_MODEL_RESOLVED=""
  fi
fi

# 檔案大小檢查
# macOS: stat -f%z, Linux: stat -c%s
FILE_SIZE=$(stat -f%z "$AUDIO_FILE" 2>/dev/null || stat -c%s "$AUDIO_FILE" 2>/dev/null || echo 0)
FILE_SIZE="${FILE_SIZE//[^0-9]/}"
: "${FILE_SIZE:=0}"
if (( FILE_SIZE < 1000 )); then
  echo "Error: audio file too small (${FILE_SIZE} bytes): $AUDIO_FILE" >&2
  exit 1
fi

# ── 偵測 whisper.cpp ─────────────────────────────────────────
# [P6] 搜尋順序與 ptt_whisper.lua WHISPER_BIN_CANDIDATES 一致
WHISPER_BIN=""
for candidate in \
  "$WHISPER_DIR/whisper-cli" \
  "$WHISPER_DIR/build/bin/whisper-cli" \
  "$WHISPER_DIR/main" \
  "$WHISPER_DIR/build/bin/main"; do
  if [[ -x "$candidate" ]]; then
    WHISPER_BIN="$candidate"
    break
  fi
done
if [[ -z "$WHISPER_BIN" ]]; then
  echo "Error: whisper.cpp executable not found in $WHISPER_DIR" >&2
  exit 1
fi
if [[ ! -f "$MODEL" ]]; then
  echo "Error: model not found: $MODEL" >&2
  exit 1
fi

mkdir -p "$PTT_DIR"

# ── [F4] 快取查詢 ────────────────────────────────────────────
CACHE_KEY=""
CACHE_FILE=""

if [[ "$CACHE_ENABLED" == "true" ]]; then
  mkdir -p "$CACHE_DIR"
  AUDIO_HASH=$(md5 -q "$AUDIO_FILE" 2>/dev/null \
    || md5sum "$AUDIO_FILE" 2>/dev/null | cut -d' ' -f1 \
    || echo "")
  if [[ -n "$AUDIO_HASH" ]]; then
    MODEL_NAME=$(basename "$MODEL")
    CACHE_KEY="${AUDIO_HASH}_${MODEL_NAME}_${LANGUAGE}"

    # [CRx] 防禦性檢查：驗證 cache key 只含安全字元 [a-zA-Z0-9._-]
    # 從源頭杜絕怪檔名進入 cache 目錄，保障下游 find + stat 解析安全
    if [[ "$CACHE_KEY" =~ ^[a-zA-Z0-9._-]+$ ]]; then
      CACHE_FILE="$CACHE_DIR/${CACHE_KEY}.txt"

      if [[ -f "$CACHE_FILE" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] CACHE HIT: $CACHE_KEY" >> "$LOG_FILE"
        cat "$CACHE_FILE"
        exit 0
      fi
    else
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: invalid cache key format, caching disabled for this run: $CACHE_KEY" >> "$LOG_FILE" 2>/dev/null || true
      CACHE_KEY=""
    fi
  fi
fi

# ── Cleanup trap ─────────────────────────────────────────────
RESAMPLE_TMPFILE=""
cleanup() {
  rm -f "${OUT_PREFIX}.txt" 2>/dev/null || true
  if [[ -n "$RESAMPLE_TMPFILE" && -f "$RESAMPLE_TMPFILE" ]]; then
    rm -f "$RESAMPLE_TMPFILE" 2>/dev/null || true
  fi
  # [CR13] 清理可能殘留的幻覺過濾暫存檔
  rm -f "$PTT_DIR"/hall_clean_*.tmp "$PTT_DIR"/hall_norm_*.tmp 2>/dev/null || true
}
trap cleanup EXIT
rm -f "${OUT_PREFIX}.txt" 2>/dev/null || true

# ── Sample rate 檢查 + 自動 Resample ─────────────────────────
EFFECTIVE_AUDIO="$AUDIO_FILE"

if command -v ffprobe &>/dev/null; then
  SR=$(ffprobe -v error -show_entries stream=sample_rate -of csv=p=0 "$AUDIO_FILE" 2>/dev/null || echo "")
  SR="${SR//[^0-9]/}"
  if [[ -n "$SR" && "$SR" != "16000" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: detected ${SR}Hz" >> "$LOG_FILE"
    if [[ "$AUTO_RESAMPLE" == "true" ]]; then
      FFMPEG_BIN=""
      for ffcand in /opt/homebrew/bin/ffmpeg /usr/local/bin/ffmpeg /usr/bin/ffmpeg; do
        [[ -x "$ffcand" ]] && { FFMPEG_BIN="$ffcand"; break; }
      done
      [[ -z "$FFMPEG_BIN" ]] && FFMPEG_BIN=$(command -v ffmpeg 2>/dev/null || true)

      if [[ -n "$FFMPEG_BIN" ]]; then
        RESAMPLE_TMPFILE=$(mktemp "$PTT_DIR/ptt_resample_XXXXXX.wav") || RESAMPLE_TMPFILE=""
        if [[ -n "$RESAMPLE_TMPFILE" ]] && "$FFMPEG_BIN" -y -i "$AUDIO_FILE" -ac 1 -ar 16000 "$RESAMPLE_TMPFILE" 2>>"$LOG_FILE"; then
          EFFECTIVE_AUDIO="$RESAMPLE_TMPFILE"
          echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: resampled ${SR}Hz → 16kHz" >> "$LOG_FILE"
        else
          echo "Warning: resample failed, using original ${SR}Hz." >&2
          rm -f "$RESAMPLE_TMPFILE" 2>/dev/null || true
          RESAMPLE_TMPFILE=""
        fi
      else
        echo "Warning: audio is ${SR}Hz, ffmpeg not found for resample." >&2
      fi
    else
      echo "Warning: audio sample rate is ${SR}Hz, expected 16000Hz." >&2
    fi
  fi
fi

# ── [F6] whisper.cpp 執行函式 ────────────────────────────────
run_whisper() {
  local use_model="$1"
  local cmd=(
    "$WHISPER_BIN"
    -m "$use_model"
    -f "$EFFECTIVE_AUDIO"
    -otxt
    -of "$OUT_PREFIX"
    -nt
  )
  if [[ -n "$LANGUAGE" && "$LANGUAGE" != "auto" ]]; then
    cmd+=(-l "$LANGUAGE")
  fi

  local tcmd=""
  if (( TIMEOUT_SEC > 0 )); then
    if command -v gtimeout &>/dev/null; then
      tcmd="gtimeout"
    elif command -v timeout &>/dev/null; then
      tcmd="timeout"
    fi
  fi

  rm -f "${OUT_PREFIX}.txt" 2>/dev/null || true

  if [[ -n "$tcmd" ]]; then
    "$tcmd" "$TIMEOUT_SEC" "${cmd[@]}" 2>>"$LOG_FILE" && return 0
    return $?
  else
    if (( TIMEOUT_SEC > 0 )); then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: timeout not found" >> "$LOG_FILE"
    fi
    "${cmd[@]}" 2>>"$LOG_FILE" && return 0
    return $?
  fi
}

# ── 主要執行 ─────────────────────────────────────────────────
WHISPER_FAILED=false
run_whisper "$MODEL" || {
  rc=$?
  WHISPER_FAILED=true

  if [[ -n "$FALLBACK_MODEL_RESOLVED" ]]; then
    if (( rc == 124 )); then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] RETRY: primary model timed out, trying fallback: $FALLBACK_MODEL_RESOLVED" >> "$LOG_FILE"
    else
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] RETRY: primary model failed (exit=$rc), trying fallback: $FALLBACK_MODEL_RESOLVED" >> "$LOG_FILE"
    fi

    run_whisper "$FALLBACK_MODEL_RESOLVED" || {
      rc2=$?
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: fallback model also failed (exit=$rc2)" >> "$LOG_FILE"
      echo "Error: whisper.cpp failed with both primary and fallback models" >&2
      exit $rc2
    }
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: fallback model succeeded" >> "$LOG_FILE"
    echo "Warning: used fallback model (primary failed with exit $rc)" >&2
    WHISPER_FAILED=false
  else
    if (( rc == 124 )); then
      echo "Error: whisper.cpp timed out after ${TIMEOUT_SEC}s" >&2
    else
      echo "Error: whisper.cpp failed with exit code $rc" >&2
    fi
    exit $rc
  fi
}

# ── 驗證輸出 ─────────────────────────────────────────────────
if [[ ! -f "${OUT_PREFIX}.txt" ]]; then
  echo "Error: transcription output not generated" >&2
  exit 1
fi
if [[ ! -s "${OUT_PREFIX}.txt" ]]; then
  echo "Error: transcription output is empty" >&2
  exit 1
fi

# ── 文字清理 + 幻覺過濾 ─────────────────────────────────────

# ── [CR8] 文字清理函式：移除 whisper.cpp 特殊標記 ───────────
clean_whisper_output() {
  local file="$1"
  tr '\n' ' ' < "$file" \
    | sed -E \
      -e 's/\[[Bb][Ll][Aa][Nn][Kk][_ ][Aa][Uu][Dd][Ii][Oo]\]//g' \
      -e 's/\[[Ss][Ii][Ll][Ee][Nn][Cc][Ee]\]//g' \
      -e 's/\[[Mm][Uu][Ss][Ii][Cc]\]//g' \
      -e 's/\[[Ll][Aa][Uu][Gg][Hh][Tt][Ee][Rr]\]//g' \
      -e 's/\([Cc]lears [Tt]hroat\)//g' \
      -e 's/\([Cc]oughs?\)//g' \
      -e 's/\([Cc]oughing\)//g' \
      -e 's/\([Ll]aughs?\)//g' \
      -e 's/\([Ll]aughing\)//g' \
      -e 's/\([Ll]aughter\)//g' \
      -e 's/\([Mm]usic\)//g' \
      -e 's/\([Aa]pplause\)//g' \
      -e 's/\([Ss]ilence\)//g' \
      -e 's/\([Ss]ighs?\)//g' \
      -e 's/\([Ss]niffs?\)//g' \
      -e 's/\([Gg]asps?\)//g' \
      -e 's/\([Bb]reathing\)//g' \
      -e 's/[[:space:]]+/ /g' \
      -e 's/^ //' \
      -e 's/ $//' \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# [B2] 基本文字清理
result=$(clean_whisper_output "${OUT_PREFIX}.txt")

# ── [CR2][CR7] Normalize 函式（與 Lua 端 normalizeForMatch 策略一致）──
# trim → 壓空白 → 全形標點轉半形 → 移除尾部標點 → lowercase
# [CR7] 合併所有 sed 呼叫為單一 pipeline（7 次 fork → 2 次），
#       在大幻覺列表場景下避免 fork overhead 超過推理時間
normalize_text() {
  local text="$1"
  [[ -z "$text" ]] && { echo ""; return; }
  # 注意：LC_ALL=C 下 [[:space:]] 只匹配 ASCII 空白，
  # 全形空白 U+3000 由顯式 sed 規則處理——這是正確且預期的行為
  echo "$text" | sed -E \
    -e 's/^[[:space:]]+//' -e 's/[[:space:]]+$//' \
    -e 's/[[:space:]]+/ /g' \
    -e 's/。/./g' -e 's/！/!/g' -e 's/？/?/g' \
    -e 's/，/,/g' -e 's/；/;/g' -e 's/：/:/g' \
    -e 's/、/,/g' -e 's/（/(/g' -e 's/）/)/g' \
    -e 's/　/ /g' \
    -e 's/[.!?,;:]+$//' \
    -e 's/^[[:space:]]+//' -e 's/[[:space:]]+$//' \
  | tr '[:upper:]' '[:lower:]'
}

# ── [CR2][CR13] 兩層幻覺比對函式 ──────────────────────────────
# [CR13] 重構為批次處理：
#   舊版：逐行呼叫 normalize_text → O(N) forks（50 行 = 100 forks）
#   新版：整檔一次 sed+tr normalize → O(1) forks（固定 ~7 forks）
# @param $1  幻覺列表檔案路徑
# @param $2  當前 result 文字
# @return    過濾後 result（透過 echo）；空字串 = 命中幻覺
filter_by_hallucination_file() {
  local file="$1"
  local text="$2"
  [[ -z "$text" ]] && { echo ""; return; }
  [[ ! -f "$file" || ! -s "$file" ]] && { echo "$text"; return; }

  # 建立清理過的幻覺列表（去除註解和空行，trim 每行）— 1 fork
  local clean_tmp
  clean_tmp=$(mktemp "$PTT_DIR/hall_clean_XXXXXX.tmp") || { echo "$text"; return; }
  sed -e '/^[[:space:]]*$/d' -e '/^[[:space:]]*#/d' \
      -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$file" > "$clean_tmp"

  if [[ ! -s "$clean_tmp" ]]; then
    rm -f "$clean_tmp"
    echo "$text"
    return
  fi

  # ── 第一層：exact match（1 fork: grep）──
  if grep -Fxq -- "$text" "$clean_tmp" 2>/dev/null; then
    rm -f "$clean_tmp"
    echo ""
    return
  fi

  # ── 第二層：normalized match ──
  local text_norm
  text_norm=$(normalize_text "$text")  # 2 forks (sed + tr)
  if [[ -n "$text_norm" ]]; then
    # [CR13] 批次 normalize 整個幻覺列表（2 forks：sed + tr）
    # 取代逐行呼叫 normalize_text 的 N×2 forks
    # sed 規則與 normalize_text() 完全一致，確保 Lua/Bash 行為對齊
    local norm_tmp
    norm_tmp=$(mktemp "$PTT_DIR/hall_norm_XXXXXX.tmp") || { rm -f "$clean_tmp"; echo "$text"; return; }
    sed -E \
      -e 's/^[[:space:]]+//' -e 's/[[:space:]]+$//' \
      -e 's/[[:space:]]+/ /g' \
      -e 's/。/./g' -e 's/！/!/g' -e 's/？/?/g' \
      -e 's/，/,/g' -e 's/；/;/g' -e 's/：/:/g' \
      -e 's/、/,/g' -e 's/（/(/g' -e 's/）/)/g' \
      -e 's/　/ /g' \
      -e 's/[.!?,;:]+$//' \
      -e 's/^[[:space:]]+//' -e 's/[[:space:]]+$//' \
      "$clean_tmp" | tr '[:upper:]' '[:lower:]' > "$norm_tmp"

    # 1 fork: grep
    if grep -Fxq -- "$text_norm" "$norm_tmp" 2>/dev/null; then
      rm -f "$clean_tmp" "$norm_tmp"
      echo ""
      return
    fi
    rm -f "$norm_tmp"
  fi

  rm -f "$clean_tmp"
  echo "$text"
}

# ── 執行幻覺過濾 ────────────────────────────────────────────
if [[ -n "$result" ]]; then
  if [[ -f "$BUILTIN_HALLUCINATION_FILE" && -s "$BUILTIN_HALLUCINATION_FILE" ]]; then
    result=$(filter_by_hallucination_file "$BUILTIN_HALLUCINATION_FILE" "$result")
  else
    # Fallback：共用檔案不存在時使用硬編碼 case statement
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: hallucinations_builtin.txt not found, using hardcoded fallback" >> "$LOG_FILE" 2>/dev/null || true
    case "$result" in
      "Thank you."|"Thank you!"|"Thank you"|\
      "Thanks."|"Thanks for watching."|"Thanks for watching!"|\
      "Thanks for listening."|\
      "Thank you for watching."|"Thank you for watching!"|\
      "Thank you for listening."|\
      "Please subscribe."|"Subscribe."|"Like and subscribe."|\
      "Bye."|"Bye bye."|"Bye-bye."|"Goodbye."|"Good bye."|\
      "..."|".."|"."|","|\
      "Subtitles by the Amara.org community"|\
      "Subtitles by the Amara.org community."|\
      "Sous-titres réalisés para la communauté d'Amara.org"|\
      "ご視聴ありがとうございました"|"ご視聴ありがとうございました。"|\
      "謝謝觀看"|"謝謝觀看。"|"謝謝觀看！"|\
      "謝謝收看"|"謝謝收看。"|"謝謝收聽"|"謝謝收聽。"|\
      "謝謝"|"謝謝。"|"感謝觀看"|"感謝觀看。"|\
      "字幕由Amara.org社區提供"|\
      "請訂閱"|"請訂閱。"|"再見"|"再見。")
        result=""
        ;;
    esac
  fi
fi

# 使用者自定義幻覺列表
if [[ -n "$result" ]]; then
  result=$(filter_by_hallucination_file "$USER_HALLUCINATION_FILE" "$result")
fi

# 重複標點檢查
if [[ -n "$result" ]]; then
  stripped=$(echo "$result" | sed -E 's/[[:punct:][:space:]]//g')
  [[ -z "$stripped" ]] && result=""
fi

# ── [F4] 寫入快取 ────────────────────────────────────────────
if [[ "$CACHE_ENABLED" == "true" && -n "$CACHE_KEY" && -n "$result" ]]; then
  printf '%s\n' "$result" > "$CACHE_FILE" 2>/dev/null || true

  # [CR9][CR12] LRU 清理：保留最近 CACHE_MAX 個檔案
  # 使用 find + stat 取代 ls 解析，避免 glob 不展開時的邊界情況
  # [CR12] 跨平台 stat 格式：macOS 用 -f '%m %N'，Linux 用 -c '%Y %n'
  # cache key 已在上方驗證只含 [a-zA-Z0-9._-]，所以檔名不含空白或特殊字元
  # cut -d' ' -f2- 安全地取得完整路徑（即使理論上路徑含空白也正確）
  if stat -f '%m %N' /dev/null &>/dev/null; then
    # macOS / BSD: stat -f '%m %N' (modification time + filename)
    find "$CACHE_DIR" -maxdepth 1 -name '*.txt' -type f -exec stat -f '%m %N' {} + 2>/dev/null \
      | sort -rn \
      | tail -n +"$((CACHE_MAX + 1))" \
      | cut -d' ' -f2- \
      | while IFS= read -r old; do
          [[ -n "$old" ]] && rm -f "$old" 2>/dev/null || true
        done
  else
    # Linux / GNU: stat -c '%Y %n' (modification time + filename)
    find "$CACHE_DIR" -maxdepth 1 -name '*.txt' -type f -exec stat -c '%Y %n' {} + 2>/dev/null \
      | sort -rn \
      | tail -n +"$((CACHE_MAX + 1))" \
      | cut -d' ' -f2- \
      | while IFS= read -r old; do
          [[ -n "$old" ]] && rm -f "$old" 2>/dev/null || true
        done
  fi
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] CACHE STORE: $CACHE_KEY" >> "$LOG_FILE"
fi

printf '%s\n' "$result"
