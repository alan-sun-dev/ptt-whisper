#!/usr/bin/env bash
# ============================================================
# transcribe.sh v2.12.0 — PTT Whisper 轉錄腳本
#
# 搭配 ptt_whisper.lua v4.1.2 使用
# 用法：transcribe.sh /path/to/audio.wav [language] [model_path]
#   language   — 覆寫 WHISPER_LANG（如 en, zh, ja）
#                空字串 "" 或 "auto" = 不帶 -l，讓 whisper.cpp 自行偵測
#   model_path — 覆寫 WHISPER_MODEL
#                可為完整路徑或檔名（自動加 WHISPER_DIR/models/ 前綴）
#                空字串 "" = 使用預設
#   prompt     — 覆寫 WHISPER_PROMPT（initial prompt，注入術語/人名）
# 輸出：轉錄文字寫到 stdout（單行，去頭尾空白，含 trailing newline）
#
# v2.12.0（code review 修正）：
#  N5.[Fix]  快取身分改用「實際做成了正規化」而非「要求做正規化」。
#            正規化失敗時我們用原始音訊繼續轉錄，舊版仍把結果存進
#            normalize=true 的身分，之後 ffmpeg 恢復正常就會一直命中那筆
#            髒資料。與既有的「identity 描述實際完成推理的 backend」同原則
#  N7.[Feat] 記錄實際完成推理的模型到 last_model.txt（會反映 fallback 降級）
#
# v2.11.0（響度正規化移進管線）：
#  N1.[Feat]  WHISPER_NORMALIZE=true 時，在 cache lookup 之後、推理之前做
#             一次 loudnorm。原本掛在 ptt_whisper.lua 的錄音 -af 鏈上，
#             但 loudnorm 需要 lookahead，會在濾波圖裡壓著約 2.4 秒音訊，
#             ffmpeg 一旦沒能優雅結束那段就消失。移到這裡沒有即時性限制。
#             已併入 cache 的 variant hash（會改變送進推理的音訊）。
#             預設 false，終端機直接呼叫的行為不變。
#
# v2.10.2 修正（真機驗證抓到）：
#  B1.[Fix]   run_whisper 導掉 stdout —— whisper-cli 同時印 stdout 與寫
#             -otxt，不導掉會讓轉錄文字被輸出兩次
#  B2.[Fix]   MAX_CONTEXT 預設由 0 改為「不帶旗標」—— -mc 0 會讓
#             initial prompt 完全失效
#
# v2.10.1 強化：
#  H1.[Fix]   curl multipart 除音訊檔外一律用 --form-string（@ / < 字面值）
#  H2.[Fix]   WHISPER_TIMEOUT 非數字會讓 (( )) 在 set -u 下中止腳本
#  H3.[Fix]   快取 identity 改以「實際完成推理的 backend」為準
#
# v2.10.0（常駐 server）：
#  SV1.[Feat]  支援 whisper-server：WHISPER_SERVER=true 時改用 HTTP 推理，
#              省掉每次的模型載入。連不上／HTTP 非 200／回應不是純文字／
#              模型與 server 不符 —— 任一情況都自動退回 CLI 路徑
#
# v2.9.0（推理參數）：
#  P3.[Feat]   initial prompt（--prompt）、VAD（--vad）、
#              執行緒數（-t，Apple Silicon 取效能核心數）、
#              max-context（-mc 0，減少重複／拖尾幻覺）
#              — 每個旗標都先偵測 build 是否支援，不支援就自動略過
#  P3.[Fix]    快取 key 納入 prompt / VAD / max-context
#
# v2.8.5：MC1（模型候選掃描）
#
# v2.8.4：CR12~CR13（第四輪 Code Review）
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

# [OPT2][MC1] 預設模型候選清單（依偏好順序）
# 量化版優先：速度 2~3x、RAM 減半、準確率幾乎無損（<0.5% WER 差異）；
# 全部找不到才退回 FP16。
#
# 注意 q5_1 排在 q5_0 之前：whisper.cpp 的 download-ggml-model.sh 對 small
# 只提供 q5_1（q5_0 僅 medium/large 有），q5_0 需自行 quantize。
# 此清單需與 ptt_whisper.lua 的 DEFAULT_MODEL_CANDIDATES 保持一致。
DEFAULT_MODEL_CANDIDATES=(
  "ggml-small-q5_1.bin"
  "ggml-small-q5_0.bin"
  "ggml-small-q8_0.bin"
  "ggml-small.bin"
)

if [[ -n "${WHISPER_MODEL:-}" ]]; then
  MODEL="$WHISPER_MODEL"
else
  MODEL=""
  for candidate in "${DEFAULT_MODEL_CANDIDATES[@]}"; do
    if [[ -f "$WHISPER_DIR/models/$candidate" ]]; then
      MODEL="$WHISPER_DIR/models/$candidate"
      break
    fi
  done
  # 全部候選皆不存在時仍指向 FP16 路徑，
  # 讓後續的 model-not-found 檢查能輸出明確的錯誤訊息
  : "${MODEL:=$WHISPER_DIR/models/ggml-small.bin}"
fi
LANGUAGE="${WHISPER_LANG:-auto}"
# [H1] TIMEOUT_SEC 必須先驗證成數字。非數字的值會讓後面的 (( TIMEOUT_SEC > 0 ))
# 在 set -u 下把它當變數名解析，直接 "unbound variable" 中止整個腳本。
TIMEOUT_SEC="${WHISPER_TIMEOUT:-60}"
if [[ ! "$TIMEOUT_SEC" =~ ^[0-9]+$ ]]; then
  TIMEOUT_SEC=60
fi
AUTO_RESAMPLE="${WHISPER_AUTO_RESAMPLE:-true}"

# ── [N1] 錄音後的響度正規化 ──────────────────────────────────
# loudnorm 原本掛在 ptt_whisper.lua 的錄音濾波鏈上（-af，即時套用）。
# 問題是它需要 lookahead：實測會在濾波圖裡壓著約 2.4 秒的音訊還沒寫出去，
# 一旦 ffmpeg 沒能優雅結束，那段就跟著消失（錄 2 秒 → 硬砍後 0 bytes）。
#
# 正規化本來就不必即時做。移到這裡（錄完之後、推理之前）結果完全一樣，
# 卻讓錄音端只剩逐樣本即時的濾波器，不再囤積任何東西。
#
# 預設 false：直接在終端機呼叫 transcribe.sh 的行為維持不變；
# ptt_whisper.lua 會明確帶 WHISPER_NORMALIZE=true。
# 值的驗證在 LOG_FILE 定義之後才做（見下方 [N1] 驗證區塊）
NORMALIZE_MODE="${WHISPER_NORMALIZE:-false}"
NORMALIZE_ENABLED=false
# [N5] 「要求做正規化」與「實際做成了」必須分開。
# 正規化可能失敗（ffmpeg 不在、檔案解不開），此時我們用原始音訊繼續轉錄
# ——那個結果就**不是**正規化過的，不能存進 normalize=true 的快取身分。
# 這與既有的「cache identity 描述實際完成推理的 backend、不是偏好」
# 是同一條原則（見 docs/ARCHITECTURE.md）。
NORMALIZE_APPLIED=false
# EBU R128 感知響度正規化。這裡是離線單檔處理，沒有即時性限制。
NORMALIZE_FILTER="loudnorm=I=-16:TP=-1.5"

# [F4] 快取設定
CACHE_ENABLED="${WHISPER_CACHE:-false}"
CACHE_MAX="${WHISPER_CACHE_MAX:-50}"
CACHE_MAX="${CACHE_MAX//[^0-9]/}"
: "${CACHE_MAX:=50}"
if (( CACHE_MAX < 5 )); then CACHE_MAX=5; fi
if (( CACHE_MAX > 500 )); then CACHE_MAX=500; fi

# [F6] Fallback model
FALLBACK_MODEL="${WHISPER_FALLBACK_MODEL:-}"
# [N7] 實際完成推理的模型（可能是 fallback，不一定是設定的主模型）。
# 與 last_backend.txt 同一條原則：Diagnostics 的「實際生效的模型」只能報
# 「預期會用哪個」，它沒辦法預知未來某次轉錄會不會降級到 fallback。
USED_MODEL=""

# ── [P3] 推理參數 ────────────────────────────────────────────
# initial prompt：注入術語 / 人名 / 中英混用詞，提升專有名詞辨識率
PROMPT="${WHISPER_PROMPT:-}"
# initial prompt 受 whisper 的 n_text_ctx/2 (≈224 tokens) 限制，
# 過長會擠掉真正的解碼上下文。以 bytes 設上限（LC_ALL=C 下 ${#var} 數的是
# bytes 而非字元）：800 bytes ≈ 266 個中日文字 ≈ 130 個英文單字，
# 兩種語言都落在 224 tokens 的安全範圍內。
PROMPT_MAX_BYTES="${WHISPER_PROMPT_MAX_BYTES:-800}"

# VAD：true / false / auto（auto = 支援且有 VAD model 才啟用）
VAD_MODE="${WHISPER_VAD:-auto}"

# max-context：預設「不帶」此旗標，使用 whisper 自己的預設值。
#
# [B2] 曾經預設為 0，這是錯的：-mc 0 會清空 text context，而 initial prompt
# 的 token 就活在 text context 裡 —— 兩者同時設定時 initial_prompt 會「完全
# 失效」。真機實測（同一段音訊、同一組 prompt）：
#     有 prompt、無 -mc  → "Cloud Code ... vLLM and Qwen"   ✅
#     有 prompt、-mc 0   → "cloud code ... VLLM and Quen"   ❌ prompt 沒作用
#     有 prompt、-mc 64  → "Cloud Code ... vLLM and Qwen"   ✅
# 由於 initial prompt 是準確度收益最大的功能，預設不能犧牲它。
# 空字串 = 不帶旗標；設定 0~224 才會帶。
MAX_CONTEXT="${WHISPER_MAX_CONTEXT:-}"

# threads：留空 = 自動偵測（Apple Silicon 取效能核心數）
THREADS="${WHISPER_THREADS:-}"

# ── [SV1] 常駐 whisper-server ────────────────────────────────
# CLI 模式每次錄音都要重新載入模型（small 約 0.3~0.5s）。常駐 server 把
# 模型留在記憶體，省掉這段固定成本。Server 的生命週期由 ptt_whisper.lua
# 管理，這裡只負責「送出請求」與「失敗時退回 CLI」。
SERVER_MODE="${WHISPER_SERVER:-false}"
SERVER_URL="${WHISPER_SERVER_URL:-http://127.0.0.1:8178}"
# Server 啟動時載入的模型路徑。若本次要用的模型與它不同（例如 lang_models
# 指定了 .en 模型），就繞過 server 走 CLI —— 為單次請求叫 server 換模型
# 會把「省下載入時間」的好處整個賠掉。
SERVER_MODEL="${WHISPER_SERVER_MODEL:-}"

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
  echo "Usage: transcribe.sh /path/to/audio.wav [language] [model_path] [prompt]" >&2
  exit 1
fi
if [[ ! -f "$AUDIO_FILE" ]]; then
  echo "Error: audio file not found: $AUDIO_FILE" >&2
  exit 1
fi

# 語言/模型/prompt 覆寫
LANG_OVERRIDE="${2:-}"
MODEL_OVERRIDE="${3:-}"
# [P3] 第 4 個位置參數覆寫 WHISPER_PROMPT（供終端機直接呼叫時使用）
PROMPT_OVERRIDE="${4:-}"
if [[ -n "$PROMPT_OVERRIDE" ]]; then
  PROMPT="$PROMPT_OVERRIDE"
fi
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

# ── [P3] whisper.cpp 能力偵測 ────────────────────────────────
# 不同 build / 版本支援的旗標不同，貿然帶上不支援的旗標會讓 whisper 直接失敗。
# `--help` 每次都跑要多一次 fork，所以結果快取在 PTT_DIR，
# 以「binary 路徑 + mtime + size」為 key，換 binary 或重新編譯會自動失效。
WHISPER_CAPS_FILE="$PTT_DIR/whisper_caps.txt"
WHISPER_CAPS=""

detect_whisper_caps() {
  local bin="$1"
  local stamp key cached_key cached_caps help caps

  stamp=$(stat -f '%m %z' "$bin" 2>/dev/null \
          || stat -c '%Y %s' "$bin" 2>/dev/null \
          || echo "0 0")
  key="${bin}|${stamp}"

  if [[ -f "$WHISPER_CAPS_FILE" ]]; then
    IFS=$'\t' read -r cached_key cached_caps < "$WHISPER_CAPS_FILE" || true
    if [[ "${cached_key:-}" == "$key" ]]; then
      WHISPER_CAPS="${cached_caps:-}"
      return 0
    fi
  fi

  help=$("$bin" --help 2>&1 || true)
  caps=""
  case "$help" in *--prompt*)      caps="$caps prompt" ;; esac
  case "$help" in *--vad*)         caps="$caps vad" ;; esac
  case "$help" in *--max-context*) caps="$caps max-context" ;; esac
  case "$help" in *--threads*)     caps="$caps threads" ;; esac
  WHISPER_CAPS="$caps"

  printf '%s\t%s\n' "$key" "$caps" > "$WHISPER_CAPS_FILE" 2>/dev/null || true
}

has_cap() {
  case " $WHISPER_CAPS " in
    *" $1 "*) return 0 ;;
    *)        return 1 ;;
  esac
}

detect_whisper_caps "$WHISPER_BIN"

# ── [P3] 執行緒數 ────────────────────────────────────────────
# whisper.cpp 預設 min(4, hardware_concurrency)。Apple Silicon 上應該用
# 效能核心（P-core）數量：把效率核心也算進來會拖慢整體推理。
if [[ -z "$THREADS" ]]; then
  THREADS=$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || true)
  if [[ ! "$THREADS" =~ ^[0-9]+$ ]]; then
    THREADS=$(sysctl -n hw.physicalcpu 2>/dev/null || true)
  fi
  if [[ ! "$THREADS" =~ ^[0-9]+$ ]]; then
    THREADS=$(nproc 2>/dev/null || true)
  fi
fi
if [[ ! "$THREADS" =~ ^[0-9]+$ ]]; then
  THREADS=4
fi
if (( THREADS < 1 ));  then THREADS=1;  fi
if (( THREADS > 16 )); then THREADS=16; fi

# ── [P3] max-context 驗證 ────────────────────────────────────
# 有效範圍 0~224（whisper 的 n_text_ctx/2）。非數字或超界則不帶此旗標。
# 負數（含 -1）視為「使用 whisper 預設」，同樣不帶旗標。
if [[ "$MAX_CONTEXT" == -* ]]; then
  MAX_CONTEXT=""
fi
if [[ -n "$MAX_CONTEXT" ]]; then
  if [[ ! "$MAX_CONTEXT" =~ ^[0-9]+$ ]] || (( MAX_CONTEXT > 224 )); then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: invalid WHISPER_MAX_CONTEXT='$MAX_CONTEXT', ignoring" >> "$LOG_FILE" 2>/dev/null || true
    MAX_CONTEXT=""
  fi
fi

# ── [P3] initial prompt 長度上限 ─────────────────────────────
if [[ -n "$PROMPT" ]]; then
  if [[ ! "$PROMPT_MAX_BYTES" =~ ^[0-9]+$ ]]; then PROMPT_MAX_BYTES=800; fi
  prompt_len=${#PROMPT}   # LC_ALL=C：這裡數的是 bytes
  if (( prompt_len > PROMPT_MAX_BYTES )); then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: prompt truncated from ${prompt_len} to ${PROMPT_MAX_BYTES} bytes" >> "$LOG_FILE" 2>/dev/null || true
    PROMPT="${PROMPT:0:$PROMPT_MAX_BYTES}"
    # 按 byte 切會把中日文字從中間剖半，留下不完整的 UTF-8 序列。
    # iconv -c 會丟棄無效序列，確保交給 whisper 的是合法 UTF-8。
    PROMPT_CLEAN=$(printf '%s' "$PROMPT" | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null || true)
    if [[ -n "$PROMPT_CLEAN" ]]; then
      PROMPT="$PROMPT_CLEAN"
    fi
  fi
fi

# ── [P3] VAD（Voice Activity Detection）────────────────────
# 砍掉靜音段：短錄音提速明顯，且能從源頭減少 whisper 在靜音上的幻覺
# （幻覺黑名單是事後補救，VAD 是治本）。
# ── [N1] WHISPER_NORMALIZE 驗證（LOG_FILE 此時已就緒）──────
case "$NORMALIZE_MODE" in
  true)  NORMALIZE_ENABLED=true ;;
  false) NORMALIZE_ENABLED=false ;;
  *)
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: invalid WHISPER_NORMALIZE='$NORMALIZE_MODE' (expected true/false)" >> "$LOG_FILE" 2>/dev/null || true
    ;;
esac
# [N5] 查快取時先樂觀假設會成功；真的失敗時再改回 false（見正規化區塊）
NORMALIZE_APPLIED="$NORMALIZE_ENABLED"

VAD_MODEL="${WHISPER_VAD_MODEL:-}"
if [[ -z "$VAD_MODEL" ]]; then
  # 用 glob 掃描而非寫死檔名，才不會被 silero 版本號變動綁死
  for vad_candidate in "$WHISPER_DIR/models"/ggml-silero*.bin; do
    if [[ -f "$vad_candidate" ]]; then
      VAD_MODEL="$vad_candidate"
      break
    fi
  done
fi

VAD_ENABLED=false
case "$VAD_MODE" in
  true|auto)
    if ! has_cap vad; then
      if [[ "$VAD_MODE" == "true" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: WHISPER_VAD=true but this whisper.cpp build has no --vad" >> "$LOG_FILE" 2>/dev/null || true
      fi
    elif [[ -z "$VAD_MODEL" || ! -f "$VAD_MODEL" ]]; then
      if [[ "$VAD_MODE" == "true" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: WHISPER_VAD=true but no VAD model found in $WHISPER_DIR/models (ggml-silero*.bin)" >> "$LOG_FILE" 2>/dev/null || true
      fi
    else
      VAD_ENABLED=true
    fi
    ;;
  false) ;;
  *)
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: invalid WHISPER_VAD='$VAD_MODE' (expected true/false/auto)" >> "$LOG_FILE" 2>/dev/null || true
    ;;
esac

# ── [SV1] 這次請求能不能走 server ────────────────────────────
# 定義提前到快取之前：快取 identity 需要知道「預計會用哪個 backend」。
server_usable() {
  local use_model="$1"
  [[ "$SERVER_MODE" == "true" ]] || return 1
  command -v curl &>/dev/null || {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: WHISPER_SERVER=true but curl not found" >> "$LOG_FILE"
    return 1
  }
  # 模型不一致就走 CLI（見 SERVER_MODEL 的說明）
  if [[ -n "$SERVER_MODEL" && "$SERVER_MODEL" != "$use_model" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: model differs from server ($use_model != $SERVER_MODEL), using CLI" >> "$LOG_FILE"
    return 1
  fi
  return 0
}

# ── [F4][BK1] 快取：identity 描述「實際推理行為」 ─────────────
# backend 必須進 cache key（server 是否真的吃下 prompt / max_context 取決於
# 它的版本，不能假設兩條路徑等價）。但 SERVER_MODE 只代表「希望用 server」，
# 不代表「這次真的由 server 完成」——server 請求失敗會退回 CLI。
# 若把 CLI 產生的結果寫進 server 的 namespace，下次 server 正常時就會拿到
# 一份其實由 CLI 產生的結果，isolation 的契約就破了。
#
# 因此：
#   查詢 —— 用「預計使用的 backend」查一次；真的降級到 CLI 時，
#           在確定 backend 之後再用 CLI 的 identity 查第二次
#   寫入 —— 一律用「實際完成推理的 backend」
CACHE_KEY=""
CACHE_FILE=""
AUDIO_HASH=""

if [[ "$CACHE_ENABLED" == "true" ]]; then
  mkdir -p "$CACHE_DIR"
  AUDIO_HASH=$(md5 -q "$AUDIO_FILE" 2>/dev/null \
    || md5sum "$AUDIO_FILE" 2>/dev/null | cut -d' ' -f1 \
    || echo "")
  if [[ -z "$AUDIO_HASH" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: cannot compute audio hash (md5/md5sum not found in PATH), cache disabled for this run" >> "$LOG_FILE" 2>/dev/null || true
  fi
fi

# 依 backend 算出這次的 cache key/file。成功回 0，不可用回 1。
cache_identity_for() {
  local backend="$1" model_name variant_raw variant_hash
  CACHE_KEY=""; CACHE_FILE=""
  [[ "$CACHE_ENABLED" == "true" && -n "$AUDIO_HASH" ]] || return 1

  model_name=$(basename "$MODEL")
  # 所有會改變輸出的參數都要進來
  # [N1] 正規化會改變實際送進推理的音訊，因此必須併入 variant hash，
  # 否則開關前後會互相污染彼此的快取。
  # [N5] 用 NORMALIZE_APPLIED（實際結果）而非 NORMALIZE_ENABLED（要求值）：
  # 查快取時兩者相同（樂觀假設會成功）；寫入快取前若正規化失敗，
  # 這裡已被改成 false，結果就會存進正確的身分底下。
  variant_raw="${PROMPT}|${VAD_ENABLED}|${MAX_CONTEXT}|${backend}|${NORMALIZE_APPLIED}"
  variant_hash=$(printf '%s' "$variant_raw" | md5 -q 2>/dev/null \
    || printf '%s' "$variant_raw" | md5sum 2>/dev/null | cut -d' ' -f1 \
    || echo "")
  variant_hash="${variant_hash:0:8}"
  : "${variant_hash:=none}"

  local key="${AUDIO_HASH}_${model_name}_${LANGUAGE}_${variant_hash}"
  # [CRx] 防禦性檢查：cache key 只能含 [a-zA-Z0-9._-]，
  # 從源頭杜絕怪檔名進入 cache 目錄，保障下游 find + stat 解析安全
  if [[ ! "$key" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: invalid cache key format, caching disabled for this run: $key" >> "$LOG_FILE" 2>/dev/null || true
    return 1
  fi
  CACHE_KEY="$key"
  CACHE_FILE="$CACHE_DIR/${key}.txt"
  return 0
}

# 查快取；命中就直接輸出並結束整個腳本。
cache_lookup_or_continue() {
  local backend="$1"
  cache_identity_for "$backend" || return 1
  [[ -f "$CACHE_FILE" ]] || return 1
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] CACHE HIT ($backend): $CACHE_KEY" >> "$LOG_FILE"
  # 標記來源是快取，並保留是哪個 backend 的 namespace，
  # 否則開了 server 卻一直命中快取時，使用者看不出 server 有沒有在用
  printf 'cache:%s\n' "$backend" > "$PTT_DIR/last_backend.txt" 2>/dev/null || true
  # [N7] cache key 的格式是 <audiohash>_<model>_<lang>_<variant>，
  # 中間那段就是當初實際產生這筆結果的模型。
  local cached_model="${CACHE_KEY#*_}"; cached_model="${cached_model%_*_*}"
  [[ -n "$cached_model" ]] && printf 'cache:%s\n' "$cached_model" > "$PTT_DIR/last_model.txt" 2>/dev/null || true
  cat "$CACHE_FILE"
  exit 0
}

# 預計使用的 backend（尚未實際發出請求）
if server_usable "$MODEL"; then
  PLANNED_BACKEND="server"
else
  PLANNED_BACKEND="cli"
fi
cache_lookup_or_continue "$PLANNED_BACKEND" || true

# ── Cleanup trap ─────────────────────────────────────────────
RESAMPLE_TMPFILE=""
NORMALIZE_TMPFILE=""
cleanup() {
  rm -f "${OUT_PREFIX}.txt" 2>/dev/null || true
  if [[ -n "$RESAMPLE_TMPFILE" && -f "$RESAMPLE_TMPFILE" ]]; then
    rm -f "$RESAMPLE_TMPFILE" 2>/dev/null || true
  fi
  if [[ -n "$NORMALIZE_TMPFILE" && -f "$NORMALIZE_TMPFILE" ]]; then
    rm -f "$NORMALIZE_TMPFILE" 2>/dev/null || true
  fi
  # [CR13] 清理可能殘留的幻覺過濾暫存檔
  rm -f "$PTT_DIR"/hall_clean_*.tmp "$PTT_DIR"/hall_norm_*.tmp 2>/dev/null || true
  # [SV1] 清理 server 回應暫存檔
  rm -f "$PTT_DIR"/ptt_server_*.tmp 2>/dev/null || true
}
trap cleanup EXIT
rm -f "${OUT_PREFIX}.txt" 2>/dev/null || true

# ── [N1] ffmpeg 尋路（resample 與 normalize 共用）───────────
find_ffmpeg() {
  local cand
  for cand in /opt/homebrew/bin/ffmpeg /usr/local/bin/ffmpeg /usr/bin/ffmpeg; do
    [[ -x "$cand" ]] && { printf '%s' "$cand"; return 0; }
  done
  command -v ffmpeg 2>/dev/null || true
}

# ── Sample rate 檢查 + 自動 Resample ─────────────────────────
EFFECTIVE_AUDIO="$AUDIO_FILE"

if command -v ffprobe &>/dev/null; then
  SR=$(ffprobe -v error -show_entries stream=sample_rate -of csv=p=0 "$AUDIO_FILE" 2>/dev/null || echo "")
  SR="${SR//[^0-9]/}"
  if [[ -n "$SR" && "$SR" != "16000" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: detected ${SR}Hz" >> "$LOG_FILE"
    if [[ "$AUTO_RESAMPLE" == "true" ]]; then
      FFMPEG_BIN=$(find_ffmpeg)

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

# ── [N1] 響度正規化（錄音後、推理前）────────────────────────
# 位置很重要：在 cache lookup 之後（快取 key 算的是原始音檔的 hash），
# 在推理之前（backend 拿到的是已經處理好的音訊，不必各自實作一次）。
if [[ "$NORMALIZE_ENABLED" == "true" ]]; then
  NORM_FFMPEG=$(find_ffmpeg)
  if [[ -z "$NORM_FFMPEG" ]]; then
    NORMALIZE_APPLIED=false          # [N5] 沒做成 → 快取身分必須說實話
    echo "Warning: WHISPER_NORMALIZE=true but ffmpeg not found, skipping." >&2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: normalize skipped, ffmpeg not found" >> "$LOG_FILE"
  else
    NORMALIZE_TMPFILE=$(mktemp "$PTT_DIR/ptt_norm_XXXXXX.wav") || NORMALIZE_TMPFILE=""
    # -ar 16000 不能省：loudnorm 內部以 192kHz 運作，不指定輸出取樣率的話
    # 產出的檔案會變成 192kHz，下游整條管線都會跟著錯。
    if [[ -n "$NORMALIZE_TMPFILE" ]] && "$NORM_FFMPEG" -y -i "$EFFECTIVE_AUDIO" \
         -af "$NORMALIZE_FILTER" -ac 1 -ar 16000 "$NORMALIZE_TMPFILE" 2>>"$LOG_FILE"; then
      EFFECTIVE_AUDIO="$NORMALIZE_TMPFILE"
      NORMALIZE_APPLIED=true         # [N5] 確實做成了
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: normalized ($NORMALIZE_FILTER)" >> "$LOG_FILE"
    else
      # 正規化失敗不該讓整次轉錄失敗——沒正規化的音訊仍然可用
      NORMALIZE_APPLIED=false        # [N5] 但結果不能冒充成正規化過的
      echo "Warning: normalize failed, using original audio." >&2
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: normalize failed, using original audio" >> "$LOG_FILE"
      rm -f "$NORMALIZE_TMPFILE" 2>/dev/null || true
      NORMALIZE_TMPFILE=""
    fi
  fi
fi

# ── [F6] whisper.cpp 執行函式 ────────────────────────────────
run_whisper() {
  local use_model="$1"
  USED_MODEL="$use_model"      # [N7] 記下實際送進推理的模型
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

  # [P3] 每個旗標都先確認這個 build 支援，避免舊版 whisper.cpp 直接失敗
  if [[ -n "$THREADS" ]] && has_cap threads; then
    cmd+=(-t "$THREADS")
  fi
  if [[ -n "$MAX_CONTEXT" ]] && has_cap max-context; then
    cmd+=(-mc "$MAX_CONTEXT")
  fi
  if [[ -n "$PROMPT" ]] && has_cap prompt; then
    cmd+=(--prompt "$PROMPT")
  fi
  if [[ "$VAD_ENABLED" == "true" ]]; then
    cmd+=(--vad --vad-model "$VAD_MODEL")
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

  # [B1] stdout 必須丟掉。whisper-cli 會「同時」把轉錄文字印到 stdout
  # 和寫進 -otxt 指定的檔案；本腳本自己的 stdout 就是最終輸出，
  # 不導掉的話 whisper 的那份會漏出去，使用者會看到文字被貼兩次。
  # 唯一的真實來源是 ${OUT_PREFIX}.txt。
  if [[ -n "$tcmd" ]]; then
    "$tcmd" "$TIMEOUT_SEC" "${cmd[@]}" >/dev/null 2>>"$LOG_FILE" && return 0
    return $?
  else
    if (( TIMEOUT_SEC > 0 )); then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: timeout not found" >> "$LOG_FILE"
    fi
    "${cmd[@]}" >/dev/null 2>>"$LOG_FILE" && return 0
    return $?
  fi
}

# ── [SV1] whisper-server 推理 ────────────────────────────────
# 成功時把結果寫進 ${OUT_PREFIX}.txt，與 CLI 路徑產出同一份檔案，
# 因此下游的驗證／清理／幻覺過濾完全不需要區分是哪條路徑跑的。
run_whisper_server() {
  local body_tmp http_code curl_rc first
  body_tmp=$(mktemp "$PTT_DIR/ptt_server_XXXXXX.tmp") || return 1

  # [H2] 只有音訊檔用 -F（需要 @ 的檔案語意）；其餘一律 --form-string。
  # curl 的 -F 會把值裡的 @ 當「上傳這個本機檔案」、< 當「從檔案讀入內容」，
  # 而 prompt 完全可能合法地以 @ 或 < 開頭（"@channel"、"<tag>"）。
  # 用 -F 傳 prompt 等於把本機檔案內容送到 server，必須永遠當字面值處理。
  local args=(
    -s -o "$body_tmp" -w '%{http_code}'
    --max-time "$TIMEOUT_SEC"
    -F "file=@${EFFECTIVE_AUDIO}"
    --form-string "response_format=text"
    --form-string "no_timestamps=true"
  )
  if [[ -n "$LANGUAGE" && "$LANGUAGE" != "auto" ]]; then
    args+=(--form-string "language=$LANGUAGE")
  fi
  if [[ -n "$PROMPT" ]]; then
    args+=(--form-string "prompt=$PROMPT")
  fi
  if [[ -n "$MAX_CONTEXT" ]]; then
    args+=(--form-string "max_context=$MAX_CONTEXT")
  fi

  curl_rc=0
  http_code=$(curl "${args[@]}" "${SERVER_URL}/inference" 2>>"$LOG_FILE") || curl_rc=$?

  if (( curl_rc != 0 )); then
    # curl exit 7 = 連不上（server 沒起來或剛掛掉）；28 = 逾時
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: server request failed (curl exit=$curl_rc)" >> "$LOG_FILE"
    rm -f "$body_tmp"; return 1
  fi
  if [[ "$http_code" != "200" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: server returned HTTP $http_code" >> "$LOG_FILE"
    rm -f "$body_tmp"; return 1
  fi
  if [[ ! -s "$body_tmp" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: server returned empty body" >> "$LOG_FILE"
    rm -f "$body_tmp"; return 1
  fi

  # 防呆：若這版 server 不認得 response_format=text，會回 JSON。
  # 與其把 JSON 當轉錄結果貼給使用者，不如退回 CLI。
  first=$(head -c 1 "$body_tmp" 2>/dev/null || echo "")
  if [[ "$first" == "{" || "$first" == "[" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: server returned JSON, expected plain text (response_format unsupported?)" >> "$LOG_FILE"
    rm -f "$body_tmp"; return 1
  fi

  mv -f "$body_tmp" "${OUT_PREFIX}.txt" || { rm -f "$body_tmp"; return 1; }
  return 0
}

# ── [SV1] 推理入口：先試 server，失敗就退回 CLI ──────────────
SERVER_USED=false
run_transcription() {
  local use_model="$1"
  if server_usable "$use_model"; then
    if run_whisper_server; then
      SERVER_USED=true
      return 0
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: falling back to CLI" >> "$LOG_FILE"
    # [BK1] 現在才確定 backend 是 CLI。先前查的是 server 的 namespace，
    # 這裡用 CLI 的 identity 再查一次——否則 server 持續失敗時，
    # 明明有 CLI 的快取可用卻每次都重跑推理。
    cache_lookup_or_continue "cli" || true
  fi
  run_whisper "$use_model"
}

# ── 主要執行 ─────────────────────────────────────────────────
WHISPER_FAILED=false
# 第一次嘗試走 dispatcher（server 優先）。若它失敗，代表 server 與 CLI 都
# 失敗了，接下來的 VAD 重試與 fallback model 一律走已知穩定的 CLI 路徑。
run_transcription "$MODEL" || {
  rc=$?
  WHISPER_FAILED=true

  # [P3] VAD 是最可能與環境衝突的一項（build 支援但 VAD model 損壞／格式不符）。
  # 在換模型之前，先關掉 VAD 用同一個主模型重試一次——
  # 這比直接降級到較差的 fallback 模型更能保住轉錄品質。
  if [[ "$VAD_ENABLED" == "true" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] RETRY: primary model failed (exit=$rc) with VAD on, retrying without VAD" >> "$LOG_FILE"
    VAD_ENABLED=false
    if run_whisper "$MODEL"; then
      WHISPER_FAILED=false
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: succeeded without VAD (check VAD model: $VAD_MODEL)" >> "$LOG_FILE"
    else
      rc=$?
    fi
  fi

  if [[ "$WHISPER_FAILED" == "false" ]]; then
    :
  elif [[ -n "$FALLBACK_MODEL_RESOLVED" ]]; then
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

# [SV1] 記錄本次實際使用的後端，供 diagnostics / menubar 顯示。
# 這條路徑會靜默退回 CLI，沒有這個標記使用者無從得知 server 到底有沒有在用。
if [[ "$SERVER_USED" == "true" ]]; then
  printf 'server\n' > "$PTT_DIR/last_backend.txt" 2>/dev/null || true
else
  printf 'cli\n' > "$PTT_DIR/last_backend.txt" 2>/dev/null || true
fi
# [N7] 同時記下實際完成推理的模型。server 路徑用 server 載入的那個。
if [[ "$SERVER_USED" == "true" && -n "$SERVER_MODEL" ]]; then
  printf '%s\n' "$(basename "$SERVER_MODEL")" > "$PTT_DIR/last_model.txt" 2>/dev/null || true
elif [[ -n "$USED_MODEL" ]]; then
  printf '%s\n' "$(basename "$USED_MODEL")" > "$PTT_DIR/last_model.txt" 2>/dev/null || true
fi

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

# ── [F4][BK1] 寫入快取：一律用「實際完成推理的 backend」 ──────
if [[ "$SERVER_USED" == "true" ]]; then
  ACTUAL_BACKEND="server"
else
  ACTUAL_BACKEND="cli"
fi
cache_identity_for "$ACTUAL_BACKEND" || true

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
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] CACHE STORE ($ACTUAL_BACKEND): $CACHE_KEY" >> "$LOG_FILE"
fi

printf '%s\n' "$result"
