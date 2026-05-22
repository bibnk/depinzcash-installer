#!/usr/bin/env bash
# DePINZcash — status check
# Usage: bash status.sh

HOME_DIR="${HOME:-/root}"
ZEBRA_LOG="$HOME_DIR/zebrad.log"
RELAY_LOG="$HOME_DIR/relay.log"

ok()   { printf "\033[1;32m ✓ \033[0m %s\n" "$*"; }
bad()  { printf "\033[1;31m ✗ \033[0m %s\n" "$*"; }
hdr()  { printf "\n\033[1;36m── %s ──\033[0m\n" "$*"; }

is_running() { pgrep -f "$1" >/dev/null 2>&1; }

hdr "Process Status"
if is_running "zebrad start"; then
  PID=$(pgrep -f "zebrad start" | head -1)
  MEM=$(ps -p "$PID" -o rss= 2>/dev/null | awk '{printf "%.0f MB", $1/1024}')
  ok "zebrad running (pid=$PID, mem=$MEM)"
else
  bad "zebrad NOT running"
fi

if is_running "depinzcash-relay watch"; then
  PID=$(pgrep -f "depinzcash-relay watch" | head -1)
  MEM=$(ps -p "$PID" -o rss= 2>/dev/null | awk '{printf "%.0f MB", $1/1024}')
  ok "relay watcher running (pid=$PID, mem=$MEM)"
else
  bad "relay watcher NOT running"
fi

hdr "Zebra Sync Status"
if [[ -f "$ZEBRA_LOG" ]]; then
  tail -200 "$ZEBRA_LOG" 2>/dev/null | grep -E "Sync|tip|height|sync_percent|complete" | tail -3 || echo "  (no sync info yet)"
else
  bad "Zebra log not found: $ZEBRA_LOG"
fi

hdr "Relay Last Activity"
if [[ -f "$RELAY_LOG" ]]; then
  tail -10 "$RELAY_LOG"
  echo ""
  ACCEPTED=$(grep -c "verdict=accepted" "$RELAY_LOG" 2>/dev/null || echo 0)
  REJECTED=$(grep -c "verdict=rejected" "$RELAY_LOG" 2>/dev/null || echo 0)
  printf "\n  Total accepted: \033[1;32m%s\033[0m | rejected: \033[1;31m%s\033[0m\n" "$ACCEPTED" "$REJECTED"
else
  bad "Relay log not found: $RELAY_LOG"
fi

hdr "RPC Endpoint Probe"
if curl -fsS -o /dev/null -w "  zebra RPC :8232 → HTTP %{http_code}\n" \
   --max-time 5 -X POST -H 'content-type: application/json' \
   --data '{"jsonrpc":"1.0","method":"getinfo","params":[]}' \
   http://127.0.0.1:8232 2>&1; then
  :
else
  bad "RPC endpoint :8232 tidak respond (zebra mungkin masih sync awal)"
fi

echo ""
