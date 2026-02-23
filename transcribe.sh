#!/usr/bin/env bash
# ============================================================
# transcribe.sh v2.7.1 — PTT Whisper 轉錄腳本
#
# 搭配 ptt_whisper.lua v3.5.1 使用
# 用法：transcribe.sh /path/to/audio.wav [language] [model_path]
#   language   — 覆寫 WHISPER_LANG（如 en, zh, ja）
#                空字串 "" 或 "auto" = 不帶 -l，讓 whisper.cpp 自行偵測
#   model_path — 覆寫 WHISPER_MODEL
#                可為完整路徑或檔名（自動加 WHISPER_DIR/models/ 前綴）
#                空字串 "" = 使用預設
# 輸出：轉錄文字寫到 stdout（單行，去頭尾空白，含 trailing newline）
#
# v2.7.1 修正（Code Review 修正）：
#  R1. [Fix] 快取 LRU 清理變數命名改善 + 安全性註解
#  R2. [Fix] run_whisper timeout 指令變數加引號
#  R3. [Fix] 快取 key 限制說明（不含 whisper.cpp 版本）
#  R4. [Fix] stat 指令跨平台相容性註解
#
# v2.7 新功能（第九輪 — 中期架構優化）：
#  F4. [Feature] 轉錄結果快取
#       對音訊檔做 checksum，相同內容+model+lang 直接回傳快取結果
#       環境變數 WHISPER_CACHE=true 開啟（預設 false，debug 時使用）
#       快取上限 WHISPER_CACHE_MAX=50，LRU 淘汰
#  F6. [Feature] 錯誤恢復 — Fallback Model 重試
#       whisper.cpp 失敗（timeout 或 crash）時，自動用較小的 model 重試
#       環境變數 WHISPER_FALLBACK_MODEL 設定 fallback model 路徑/檔名
#
# v2.6.1：R1~R5  v2.6：F1~F3  v2.5：#20~#23  v2.4：#18~#19
# v2.3：#16~#17  v2.2：#10~#15  v2.1：#8~#9  v2：#1~#7
# ============================================================
set -euo pipefail
umask 077

# ── 設定區 ───────────────────────────────────────────────────
WHISPER_DIR="${WHISPER_DIR:-$HOME/whisper.cpp}"
MODEL="${WHISPER_MODEL:-$WHISPER_DIR/models/ggml-small.bin}"
LANGUAGE="${WHISPER_LANG:-auto}"
TIMEOUT_SEC="${WHISPER_TIMEOUT:-60}"
AUTO_RESAMPLE="${WHISPER_AUTO_RESAMPLE:-true}"

# [F4] 快取設定
CACHE_ENABLED="${WHISPER_CACHE:-false}"
CACHE_MAX="${WHISPER_CACHE_MAX:-50}"
# [P1] 數字消毒：防止非數字值導致 (( )) 在 set -e 下 crash
CACHE_MAX="${CACHE_MAX//[^0-9]/}"
: "${CACHE_MAX:=50}"
if (( CACHE_MAX < 5 )); then CACHE_MAX=5; fi
if (( CACHE_MAX > 500 )); then CACHE_MAX=500; fi

# [F6] Fallback model（空字串 = 不重試）
# 可設為檔名（如 ggml-tiny.bin）或完整路徑
FALLBACK_MODEL="${WHISPER_FALLBACK_MODEL:-}"

# 路徑
PTT_DIR="$HOME/.ptt-whisper"
LOG_FILE="$PTT_DIR/ptt_whisper_err.log"
OUT_PREFIX="$PTT_DIR/ptt_whisper_out"
CACHE_DIR="$PTT_DIR/cache"
HALLUCINATION_FILE="$PTT_DIR/hallucinations.txt"

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

# 語言/模型覆寫參數
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
  # 若 fallback model 與主 model 相同，或不存在，清空
  if [[ "$FALLBACK_MODEL_RESOLVED" == "$MODEL" ]]; then
    FALLBACK_MODEL_RESOLVED=""
  elif [[ ! -f "$FALLBACK_MODEL_RESOLVED" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: fallback model not found: $FALLBACK_MODEL_RESOLVED" >> "$LOG_FILE" 2>/dev/null || true
    FALLBACK_MODEL_RESOLVED=""
  fi
fi

# 檔案大小檢查
# [R4] macOS 使用 stat -f%z，Linux 使用 stat -c%s（兩者語法不同）
FILE_SIZE=$(stat -f%z "$AUDIO_FILE" 2>/dev/null || stat -c%s "$AUDIO_FILE" 2>/dev/null || echo 0)
FILE_SIZE="${FILE_SIZE//[^0-9]/}"
: "${FILE_SIZE:=0}"
if (( FILE_SIZE < 1000 )); then
  echo "Error: audio file too small (${FILE_SIZE} bytes): $AUDIO_FILE" >&2
  exit 1
fi

# ── 偵測 whisper.cpp 執行檔 ──────────────────────────────────
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
# [R3] 快取 key = md5(音訊內容) + model 檔名 + language
# 注意：cache key 不包含 whisper.cpp 版本或 model 內容 hash，
# 因此升級 whisper.cpp 或替換同名 model 檔案後，建議手動清除快取：
#   rm -rf ~/.ptt-whisper/cache/
CACHE_KEY=""
CACHE_FILE=""

if [[ "$CACHE_ENABLED" == "true" ]]; then
  mkdir -p "$CACHE_DIR"
  # 計算 audio checksum（macOS: md5 -q, Linux: md5sum）
  AUDIO_HASH=$(md5 -q "$AUDIO_FILE" 2>/dev/null \
    || md5sum "$AUDIO_FILE" 2>/dev/null | cut -d' ' -f1 \
    || echo "")
  if [[ -n "$AUDIO_HASH" ]]; then
    MODEL_NAME=$(basename "$MODEL")
    CACHE_KEY="${AUDIO_HASH}_${MODEL_NAME}_${LANGUAGE}"
    CACHE_FILE="$CACHE_DIR/${CACHE_KEY}.txt"

    if [[ -f "$CACHE_FILE" ]]; then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] CACHE HIT: $CACHE_KEY" >> "$LOG_FILE"
      cat "$CACHE_FILE"
      exit 0
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

# ── [F6] whisper.cpp 執行函式（支援重試）─────────────────────
# @param $1  model path
# @return 0=成功, 非0=失敗
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

  # 偵測 timeout 指令
  local tcmd=""
  if (( TIMEOUT_SEC > 0 )); then
    if command -v gtimeout &>/dev/null; then
      tcmd="gtimeout"
    elif command -v timeout &>/dev/null; then
      tcmd="timeout"
    fi
  fi

  # 清除上次輸出
  rm -f "${OUT_PREFIX}.txt" 2>/dev/null || true

  # [R2] $tcmd 加引號，符合 set -euo pipefail 嚴格模式精神
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

# ── 主要執行：先用主 model，失敗則 fallback ──────────────────
WHISPER_FAILED=false
run_whisper "$MODEL" || {
  rc=$?
  WHISPER_FAILED=true

  if [[ -n "$FALLBACK_MODEL_RESOLVED" ]]; then
    # [F6] 有 fallback model → 重試
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
    # fallback 成功
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: fallback model succeeded" >> "$LOG_FILE"
    echo "Warning: used fallback model (primary failed with exit $rc)" >&2
    WHISPER_FAILED=false
  else
    # 無 fallback → 報錯退出
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

# ── 幻覺過濾 + 輸出 ─────────────────────────────────────────
# ⚠️ 注意：此內建列表需與 ptt_whisper.lua 的 builtinHallucinations 保持同步
result=$(tr '\n' ' ' < "${OUT_PREFIX}.txt" \
  | sed -E \
    -e 's/\[BLANK_AUDIO\]//g' \
    -e 's/\[blank_audio\]//g' \
    -e 's/\[Blank_Audio\]//g' \
    -e 's/\[Blank audio\]//g' \
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
    -e 's/ $//')

result=$(echo "$result" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

# 內建幻覺列表
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

# 外部幻覺列表
if [[ -n "$result" && -f "$HALLUCINATION_FILE" && -s "$HALLUCINATION_FILE" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    [[ "$line" == \#* ]] && continue
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    if [[ "$result" == "$line" ]]; then
      result=""
      break
    fi
  done < "$HALLUCINATION_FILE"
fi

# 重複標點檢查
if [[ -n "$result" ]]; then
  stripped=$(echo "$result" | sed -E 's/[[:punct:][:space:]]//g')
  [[ -z "$stripped" ]] && result=""
fi

# ── [F4] 寫入快取 ────────────────────────────────────────────
if [[ "$CACHE_ENABLED" == "true" && -n "$CACHE_KEY" && -n "$result" ]]; then
  printf '%s\n' "$result" > "$CACHE_FILE" 2>/dev/null || true

  # [R1] LRU 清理：保留最近 CACHE_MAX 個檔案，刪除較舊的
  # 注意：此處使用 ls -1t 解析檔名。在本專案中 cache key 格式為
  # {md5}_{model}_{lang}.txt，不含空白或特殊字元，因此 ls 解析是安全的。
  # 若未來 cache key 格式變更，需改用 find + sort 方式。
  cached_files=$(ls -1t "$CACHE_DIR"/*.txt 2>/dev/null || true)
  if [[ -n "$cached_files" ]]; then
    echo "$cached_files" | tail -n +"$((CACHE_MAX + 1))" | while IFS= read -r old; do
      [[ -n "$old" ]] && rm -f "$old" 2>/dev/null || true
    done
  fi
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] CACHE STORE: $CACHE_KEY" >> "$LOG_FILE"
fi

printf '%s\n' "$result"
