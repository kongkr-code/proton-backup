#!/bin/bash
set -uo pipefail

# --- CHANGE PASSWORD to keyring made ---
KEYRING_PASS="YourChosenPassword"

# CHANGE LOCAL BACKUP FOLDER Proxmox dumps everything (all LXCs, flat) into a "dump" subfolder
LOCAL_BACKUP_DIR="/your/local/backup"
LOCAL_DUMP_DIR="$LOCAL_BACKUP_DIR/dump"

REMOTE_TARGET_DIR="/my-files/LXC-Backup"
REMOTE_DUMP_DIR="$REMOTE_TARGET_DIR/dump"

LOG_FILE="/var/log/proton-backup.log"

# Retention: how many of the newest backup RUNS to keep, per container ID
# (a "run" = the .log + .tar.zst + .tar.zst.notes trio sharing one timestamp)
KEEP_N=2

# Safety guards for the delete step
MIN_LOCAL_FILES=1        # abort delete step if fewer local files than this exist (mount hiccup guard)
MAX_DELETE_RATIO=50      # abort if more than this % of remote files would be deleted in one run
DRY_RUN=false             # set true to log what WOULD be deleted without deleting anything

# Network interface used for the live transfer-rate readout (e.g. vmbr0, eno1).
# Leave empty to auto-detect the interface your default route uses.
NET_IFACE=""

# Color of the filled part of the progress bar (ANSI code): 32 green, 36 cyan,
# 33 yellow, 35 magenta, 34 blue. Set the environment variable NO_COLOR=1 to
# turn colors off entirely.
BAR_COLOR=32
# ---------------------

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Keep a handle on the real terminal BEFORE stdout is redirected into the log.
# The progress bar is drawn on fd 3, and only if fd 3 is an actual terminal.
exec 3>&1
exec > >(tee -a "$LOG_FILE") 2>&1

echo "[$(date)] Starting Backup Sync to Proton Drive ..."

run_proton() {
  # Runs a proton-drive command inside a fresh keyring session.
  # Usage: run_proton filesystem list "$REMOTE_TARGET_DIR" --json
  dbus-run-session -- sh -c "
    echo -n '$KEYRING_PASS' | gnome-keyring-daemon --daemonize --login > /dev/null
    proton-drive $*
  "
}

# --- Progress bar helpers ---
# The bar only appears when you run the script from a terminal. Under cron
# there is no terminal, so nothing is drawn and the log just gets plain lines.
draw_progress() {   # usage: draw_progress DONE TOTAL "label"
  [ -t 3 ] || return 0
  local cur=$1 total=$2 label=$3 width=20 pct=0 filled fill rest on="" dim="" off="" cols max
  [ "$total" -gt 0 ] && pct=$(( cur * 100 / total ))
  filled=$(( pct * width / 100 ))
  fill="$(printf '%*s' "$filled" '' | tr ' ' '#')"
  rest="$(printf '%*s' $(( width - filled )) '' | tr ' ' '-')"
  if [ -z "${NO_COLOR:-}" ]; then on=$'\033[1;'"${BAR_COLOR}"'m'; dim=$'\033[90m'; off=$'\033[0m'; fi
  cols=$(stty size <&3 2>/dev/null | cut -d' ' -f2)
  { [ -n "$cols" ] && [ "$cols" -gt 0 ]; } || cols=80
  max=$(( cols - width - 9 )); [ "$max" -lt 10 ] && max=10
  printf '\r\033[K[%s%s%s%s%s%s] %3d%% %s' "$on" "$fill" "$off" "$dim" "$rest" "$off" "$pct" "${label:0:$max}" >&3
}
end_progress() { [ -t 3 ] && printf '\n' >&3; return 0; }

# Per-file log line: on a terminal it goes to the log file only (so it can't
# collide with the bar); otherwise it goes through the normal log stream.
step_log() {
  if [ -t 3 ]; then echo "[$(date)] $*" >> "$LOG_FILE"; else echo "[$(date)] $*"; fi
}

# Run proton-drive with all its output going to the log file, not the screen
# (keeps dbus-daemon's chatty messages from breaking the bar).
run_proton_quiet() { run_proton "$@" >> "$LOG_FILE" 2>&1; }

human() { numfmt --to=iec-i --suffix=B "$1"; }

fmt_dur() {   # seconds -> 42s / 3m07s / 1h05m
  local s=$1
  if   [ "$s" -ge 3600 ]; then printf '%dh%02dm' $(( s / 3600 )) $(( s % 3600 / 60 ))
  elif [ "$s" -ge 60 ];   then printf '%dm%02ds' $(( s / 60 )) $(( s % 60 ))
  else printf '%ds' "$s"; fi
}

# --- Live transfer rate ---
# The Proton CLI doesn't report progress, so the live rate comes from the
# network interface's transmit counter, sampled once a second while a file
# uploads. It counts ALL traffic on that interface, so other activity on the
# same NIC will inflate the number a little (uploads are encrypted, so there
# is also a small overhead on top of the raw file size).
[ -n "$NET_IFACE" ] || NET_IFACE=$(ip -o route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p')
tx_bytes() { cat "/sys/class/net/$NET_IFACE/statistics/tx_bytes" 2>/dev/null || echo 0; }

TICKER_PID=""
start_ticker() {   # usage: start_ticker DONE TOTAL "prefix" "suffix"
  [ -t 3 ] && [ -n "$NET_IFACE" ] || return 0
  (
    prev=$(tx_bytes); smooth=0
    # exits on its own if the main script dies, so it can never be orphaned
    while sleep 1 && kill -0 "$$" 2>/dev/null; do
      now=$(tx_bytes); rate=$(( now - prev )); prev=$now
      smooth=$(( (smooth * 2 + rate) / 3 ))     # light smoothing so it isn't jumpy
      draw_progress "$1" "$2" "$3  $(human "$smooth")/s  $4"
    done
  ) &
  TICKER_PID=$!
}
stop_ticker() {
  if [ -n "$TICKER_PID" ]; then
    kill "$TICKER_PID" 2>/dev/null
    wait "$TICKER_PID" 2>/dev/null
    TICKER_PID=""
  fi
  return 0
}
trap 'stop_ticker' EXIT
trap 'exit 130' INT TERM

# 1a. Upload any backup files missing from the remote one at a time, with a
#     progress bar weighted by file size. This needs the remote 'dump' folder
#     to exist already; on a very first run the listing comes back empty, so
#     this stage is skipped and 1b below does the work instead.
echo "[$(date)] Checking which backup files still need uploading..."
PRE_JSON=$(run_proton filesystem list "'$REMOTE_DUMP_DIR'" --json 2>/dev/null)
mapfile -t PRE_REMOTE < <(echo "$PRE_JSON" | jq -r '.[] | select(.type=="file") | .name.value' 2>/dev/null)

if [ "${#PRE_REMOTE[@]}" -gt 0 ]; then
  mapfile -t TO_UPLOAD < <(comm -23 \
    <(find "$LOCAL_DUMP_DIR" -maxdepth 1 -type f -printf '%f\n' | sort) \
    <(printf '%s\n' "${PRE_REMOTE[@]}" | sort))
  TOTAL_FILES=${#TO_UPLOAD[@]}

  if [ "$TOTAL_FILES" -eq 0 ]; then
    echo "[$(date)] Remote already has every local backup file."
  else
    TOTAL_BYTES=0
    for f in "${TO_UPLOAD[@]}"; do
      TOTAL_BYTES=$(( TOTAL_BYTES + $(stat -c %s "$LOCAL_DUMP_DIR/$f") ))
    done
    echo "[$(date)] Uploading $TOTAL_FILES new file(s), $(human "$TOTAL_BYTES") total..."

    DONE_BYTES=0; N=0; UPLOAD_FAILS=0; RUN_START=$(date +%s)
    for f in "${TO_UPLOAD[@]}"; do
      N=$(( N + 1 ))
      size=$(stat -c %s "$LOCAL_DUMP_DIR/$f")
      step_log "Uploading ($N/$TOTAL_FILES, $(human "$size")): $f"

      # ETA from the average speed of the files finished so far
      elapsed_all=$(( $(date +%s) - RUN_START ))
      if [ "$DONE_BYTES" -gt 0 ] && [ "$elapsed_all" -gt 0 ]; then
        avg=$(( DONE_BYTES / elapsed_all ))
        [ "$avg" -gt 0 ] || avg=1
        eta="ETA ~$(fmt_dur $(( (TOTAL_BYTES - DONE_BYTES) / avg )))"
      else
        eta="ETA --"
      fi
      prefix="$N/$TOTAL_FILES  $(human "$DONE_BYTES")/$(human "$TOTAL_BYTES")"

      draw_progress "$DONE_BYTES" "$TOTAL_BYTES" "$prefix  --/s  $eta  $f"
      start_ticker "$DONE_BYTES" "$TOTAL_BYTES" "$prefix" "$eta  $f"
      file_start=$(date +%s)
      run_proton_quiet filesystem upload "'$LOCAL_DUMP_DIR/$f'" "'$REMOTE_DUMP_DIR/'" --file-conflict-strategy skip
      rc=$?
      stop_ticker
      dur=$(( $(date +%s) - file_start )); [ "$dur" -gt 0 ] || dur=1

      if [ "$rc" -eq 0 ]; then
        DONE_BYTES=$(( DONE_BYTES + size ))
        step_log "Uploaded $f in $(fmt_dur "$dur") ($(human $(( size / dur )))/s)"
      else
        step_log "WARNING: upload failed for $f"
        UPLOAD_FAILS=$(( UPLOAD_FAILS + 1 ))
      fi
    done
    run_secs=$(( $(date +%s) - RUN_START )); [ "$run_secs" -gt 0 ] || run_secs=1
    draw_progress "$DONE_BYTES" "$TOTAL_BYTES" "$(( N - UPLOAD_FAILS ))/$TOTAL_FILES uploaded  $(human "$DONE_BYTES")  avg $(human $(( DONE_BYTES / run_secs )))/s"
    end_progress
    echo "[$(date)] Per-file upload finished: $(( TOTAL_FILES - UPLOAD_FAILS )) ok, $UPLOAD_FAILS failed, $(human "$DONE_BYTES") in $(fmt_dur "$run_secs") (avg $(human $(( DONE_BYTES / run_secs )))/s)."
  fi
fi

# 1b. Original bulk upload, unchanged. It uploads the whole parent folder (so
#     the folder structure is preserved on the remote), skips anything already
#     there, and acts as a catch-all for anything stage 1a didn't cover.
echo "[$(date)] Uploading local files..."
run_proton filesystem upload "'$LOCAL_BACKUP_DIR'/*" "'$REMOTE_TARGET_DIR/'" \
  --folder-conflict-strategy merge --file-conflict-strategy skip

echo "[$(date)] File Transfer Complete."

# 2. Retention step: keep only the newest KEEP_N backup runs PER CONTAINER
echo "[$(date)] Applying per-container retention policy (keep last $KEEP_N runs each)..."

# Sanity check: don't run retention if the local dumped folder looks empty —
# that usually means the mount isn't up, and we don't want to start pruning
# the remote based on a false read of "nothing local exists".
LOCAL_COUNT=$(find "$LOCAL_DUMP_DIR" -maxdepth 1 -type f 2>/dev/null | wc -l)
if [ "$LOCAL_COUNT" -lt "$MIN_LOCAL_FILES" ]; then
  echo "[$(date)] SAFETY ABORT: only $LOCAL_COUNT local file(s) found in $LOCAL_DUMP_DIR (minimum $MIN_LOCAL_FILES). Skipping retention step."
  exit 1
fi

# --- Get remote file list from the 'dumped' subfolder ---
# NOTE: verify the exact JSON field name proton-drive returns by running:
#   proton-drive filesystem list "$REMOTE_DUMP_DIR" --json | jq .
REMOTE_JSON=$(run_proton filesystem list "'$REMOTE_DUMP_DIR'" --json)

if [ -z "$REMOTE_JSON" ]; then
  echo "[$(date)] SAFETY ABORT: could not retrieve remote file listing. Skipping retention step."
  exit 1
fi

mapfile -t REMOTE_FILES < <(echo "$REMOTE_JSON" | jq -r '.[] | select(.type=="file") | .name.value' 2>/dev/null)
REMOTE_COUNT=${#REMOTE_FILES[@]}

if [ "$REMOTE_COUNT" -eq 0 ]; then
  echo "[$(date)] No remote files found (or JSON parsing failed) — nothing to prune."
  exit 0
fi

# --- Group files by container ID + timestamp ---
# Expected pattern: vzdump-lxc-<CTID>-<YYYY_MM_DD-HH_MM_SS>.(tar.zst|tar.zst.notes|log)
declare -A RUN_FILES   # key "CTID|timestamp" -> newline-separated filenames belonging to that run

for fname in "${REMOTE_FILES[@]}"; do
  if [[ "$fname" =~ ^vzdump-lxc-([0-9]+)-([0-9]{4}_[0-9]{2}_[0-9]{2}-[0-9]{2}_[0-9]{2}_[0-9]{2})\. ]]; then
    ctid="${BASH_REMATCH[1]}"
    ts="${BASH_REMATCH[2]}"
    key="${ctid}|${ts}"
    RUN_FILES["$key"]+="$fname"$'\n'
  else
    echo "[$(date)] WARNING: filename doesn't match expected vzdump pattern, leaving untouched: $fname"
  fi
done

# --- For each container, find runs beyond the newest KEEP_N ---
mapfile -t CTIDS < <(printf '%s\n' "${!RUN_FILES[@]}" | cut -d'|' -f1 | sort -un)

TO_DELETE=()

for ctid in "${CTIDS[@]}"; do
  # Timestamps for this CTID, sorted newest first (string sort works because
  # the format YYYY_MM_DD-HH_MM_SS is fixed-width and zero-padded)
  mapfile -t TS_LIST < <(printf '%s\n' "${!RUN_FILES[@]}" | grep "^${ctid}|" | cut -d'|' -f2 | sort -r)
  TOTAL_RUNS=${#TS_LIST[@]}

  if [ "$TOTAL_RUNS" -le "$KEEP_N" ]; then
    continue
  fi

  STALE_TS=("${TS_LIST[@]:$KEEP_N}")
  echo "[$(date)] CTID $ctid: $TOTAL_RUNS run(s) found, pruning $(( TOTAL_RUNS - KEEP_N )) old run(s)."

  for ts in "${STALE_TS[@]}"; do
    key="${ctid}|${ts}"
    while IFS= read -r f; do
      [ -n "$f" ] && TO_DELETE+=("$f")
    done <<< "${RUN_FILES[$key]}"
  done
done

DELETE_COUNT=${#TO_DELETE[@]}

if [ "$DELETE_COUNT" -eq 0 ]; then
  echo "[$(date)] All containers within retention limit. Nothing to delete."
else
  DELETE_PCT=$(( DELETE_COUNT * 100 / REMOTE_COUNT ))
  echo "[$(date)] Found $DELETE_COUNT file(s) to delete out of $REMOTE_COUNT remote file(s) ($DELETE_PCT%)."

  if [ "$DELETE_PCT" -gt "$MAX_DELETE_RATIO" ]; then
    echo "[$(date)] SAFETY ABORT: deletion would remove more than ${MAX_DELETE_RATIO}% of remote files. Refusing to proceed automatically."
    echo "[$(date)] Files that would have been deleted:"
    printf '  %s\n' "${TO_DELETE[@]}"
    exit 1
  fi

  N=0
  for f in "${TO_DELETE[@]}"; do
    N=$(( N + 1 ))
    if [ "$DRY_RUN" = true ]; then
      echo "[$(date)] [DRY RUN] Would delete: $REMOTE_DUMP_DIR/$f"
    else
      step_log "Trashing old remote backup ($N/$DELETE_COUNT): $REMOTE_DUMP_DIR/$f"
      draw_progress "$(( N - 1 ))" "$DELETE_COUNT" "$N/$DELETE_COUNT  $f"
      run_proton_quiet filesystem trash "'$REMOTE_DUMP_DIR/$f'" || step_log "WARNING: failed to trash $f"
    fi
  done
  if [ "$DRY_RUN" = false ]; then
    draw_progress "$DELETE_COUNT" "$DELETE_COUNT" "$DELETE_COUNT/$DELETE_COUNT trashed"
    end_progress
  fi
fi

# 3. Empty trash so storage is actually reclaimed
if [ "$DRY_RUN" = false ]; then
  echo "[$(date)] Purging Proton Drive trash..."
  run_proton filesystem empty-trash
fi

echo "[$(date)] Synchronisation complete."
