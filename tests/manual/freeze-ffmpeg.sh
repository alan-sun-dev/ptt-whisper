#!/usr/bin/env bash
# ============================================================
# 真機驗證：把錄音中的 ffmpeg 凍住，逼出「ffmpeg 不肯結束」的路徑
#
# 為什麼需要這個腳本：
#   要驗證的情境是「錄音進行中，ffmpeg 卡死不回應訊號」。但按住熱鍵的
#   同時沒辦法在終端機下指令——按住 Right Option 時，Enter 會變成
#   Option+Enter，指令不會執行。
#   所以反過來：先讓這個腳本在這裡等，你再去按熱鍵。
#
# 用法：
#   1. Hammerspoon → Reload Config（載入 v4.1.0 以上）
#   2. 在終端機執行：  ./tests/manual/freeze-ffmpeg.sh
#   3. 看到「等待中」之後，按住 Right Option 講話，按住 8 秒以上再放開
#   4. 照著畫面上的檢查清單看結果
# ============================================================
set -u

PTT_DIR="$HOME/.ptt-whisper"
REC="$PTT_DIR/ptt_record.wav"
LOG="$PTT_DIR/ptt_whisper_err.log"
RECORD_SEC="${1:-3}"     # 凍住之前先讓它錄幾秒
THAW_SEC=15              # 多久之後自動解凍（保險，避免留下停住的行程）

# 只認 PTT 自己的錄音行程。
# 不能單用 pgrep -f：它比對的是「任何行程的完整命令列」，連命令列裡剛好
# 提到 ffmpeg 和 ptt_record.wav 的 shell（例如這個腳本本身）都會被抓進來。
# 先用 -x 以行程名精確篩出真正的 ffmpeg，再看它的命令列。
pttpid() {
  local p last=""
  for p in $(pgrep -x ffmpeg 2>/dev/null); do
    if ps -o command= -p "$p" 2>/dev/null | grep -q "ptt_record\.wav"; then
      last="$p"
    fi
  done
  [[ -n "$last" ]] && echo "$last"
}

if [[ -n "$(pttpid)" ]]; then
  echo "⚠️  已經有一個 PTT 錄音行程在跑，先處理掉再來："
  echo "    kill -CONT $(pttpid); kill -9 $(pttpid)"
  exit 1
fi

MARK=$(wc -l < "$LOG" 2>/dev/null || echo 0)   # 記住 log 目前的行數

echo "════════════════════════════════════════════"
echo "  等待中 —— 現在去按住 Right Option 講話"
echo "  （按住 8 秒以上再放開）"
echo "════════════════════════════════════════════"

# 1. 等錄音開始
while [[ -z "$(pttpid)" ]]; do sleep 0.05; done
PID=$(pttpid)
echo "  ✓ 偵測到錄音行程 pid=$PID"

# 2. 讓它先真的錄一段
sleep "$RECORD_SEC"
SIZE_BEFORE=$(stat -f%z "$REC" 2>/dev/null || echo 0)

# 3. 凍住它 —— SIGSTOP 無法被攔截，SIGINT/SIGTERM 從此完全無效
kill -STOP "$PID" 2>/dev/null
echo "  ✓ 已凍住 ffmpeg（SIGSTOP）—— 它現在對任何訊號都沒反應了"
echo
echo "  ── 檢查點 1：錄音進行中，磁碟上有東西嗎 ─────────"
printf "     錄了 %s 秒 → 磁碟上 %s bytes\n" "$RECORD_SEC" "$SIZE_BEFORE"
if [[ "$SIZE_BEFORE" -gt 1000 ]]; then
  echo "     ✅ 有資料 → -flush_packets 1 生效了"
  echo "        （v4.1.0 之前這裡必定是 0，整段錄音會消失）"
else
  echo "     ❌ 還是 0 bytes → -flush_packets 沒生效，請把這個結果貼回去"
fi
echo
echo "  現在放開 Right Option，然後看畫面上的提示。"

# 4. 等 PTT 那邊跑完（放棄等待 3.0s + 轉錄）
sleep "$THAW_SEC"
kill -CONT "$PID" 2>/dev/null || true   # 若還在（已被 SIGKILL 就不存在）
kill -9   "$PID" 2>/dev/null || true    # 保險：不留殘留行程

echo
echo "  ── 檢查點 2：這段期間的 log ─────────────────────"
tail -n +"$((MARK + 1))" "$LOG" 2>/dev/null \
  | grep -E "recording:|killTask:|skipped:|pasteText|CACHE" \
  | sed 's/^/     /'
echo
echo "  ── 預期應該看到 ─────────────────────────────────"
echo "     • killTask: SIGINT timeout, sent SIGTERM"
echo "     • killTask: SIGTERM timeout, sent SIGKILL to pid $PID   ← N3"
echo "     • recording: ffmpeg 未在 3.0s 內結束                    ← B4"
echo "     • recording: ffmpeg 未結束，改用磁碟上已寫出的音訊       ← 根治的證明"
echo "     • 而且文字有正常貼出來（不該出現「錄音檔過小」）"
echo
echo "  若 ffmpeg 被 SIGKILL 收掉了，上面的 CONT/kill 會找不到行程，正常。"
