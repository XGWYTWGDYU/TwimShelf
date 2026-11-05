#!/bin/bash
# Runs Kani harnesses one at a time with a memory cap and a time limit. Only the processes this
# script started are measured and stopped (never another cbmc on the machine). Exits non-zero
# unless every harness reports VERIFICATION:- SUCCESSFUL, so it can gate a release.
# Usage: scripts/kani_guard.sh harness1 harness2 ...   (from anywhere)
[ "$#" -gt 0 ] || { echo "No harnesses supplied" >&2; exit 2; }
LIMIT_MB=${LIMIT_MB:-4096}
TIMEOUT_S=${TIMEOUT_S:-600}
cd "$(dirname "$0")/../core" || exit 1
TL_KANI_CACHE=$(python3 ../scripts/apply.py where cache) || exit 1
export CARGO_TARGET_DIR="$TL_KANI_CACHE/kani"

# every process below $1 (children, grandchildren, …)
tree() {
  local kids
  kids=$(pgrep -P "$1" 2>/dev/null)
  for k in $kids; do echo "$k"; tree "$k"; done
}

failed=0
for h in "$@"; do
  log=$(mktemp)
  cargo kani --manifest-path verification/Cargo.toml --lib --harness "$h" >"$log" 2>&1 &
  pid=$!
  start=$(date +%s)
  killed=""
  while kill -0 $pid 2>/dev/null; do
    pids=$(tree $pid)
    rss=0
    if [ -n "$pids" ]; then rss=$(ps -o rss= -p $(echo $pids | tr ' ' ',') 2>/dev/null | awk '{s+=$1} END {print int(s/1024)}'); fi
    if [ "${rss:-0}" -gt "$LIMIT_MB" ] || [ $(( $(date +%s) - start )) -gt "$TIMEOUT_S" ]; then
      for p in $pids; do kill "$p" 2>/dev/null; done
      kill $pid 2>/dev/null
      killed="KILLED (rss ${rss} MB, $(( $(date +%s) - start ))s)"
      break
    fi
    sleep 1
  done
  status=0
  wait $pid 2>/dev/null || status=$?
  res=$(grep -E "VERIFICATION:-" "$log" | tail -1)
  t=$(grep -E "Verification Time" "$log" | tail -1 | grep -oE "[0-9.]+s")
  echo "== $h ${killed:-${res:-NO RESULT}} ${t}"
  grep -E "Failed Checks|FAILURE" "$log" | head -5
  case "$res" in *SUCCESSFUL*) [ -z "$killed" ] && [ "$status" -eq 0 ] || failed=1 ;; *) failed=1 ;; esac
  rm -f "$log"
done
exit $failed
