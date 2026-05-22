#!/usr/bin/env bash
# DePINZcash — restart zebrad + relay setelah server reboot
# Usage: bash restart.sh

set -euo pipefail

HOME_DIR="${HOME:-/root}"
DEPIN_DIR="$HOME_DIR/DePINZcash"
RELAY_BIN="$DEPIN_DIR/prover/target/release/depinzcash-relay"
KEYPAIR="$DEPIN_DIR/config/solana-keypair.json"
RELAY_STATE="$DEPIN_DIR/config/relay-state.json"
ZEBRA_LOG="$HOME_DIR/zebrad.log"
RELAY_LOG="$HOME_DIR/relay.log"
API_URL="${API_URL:-https://api.zcashdepin.com}"
ZEBRA_RPC_PORT="${ZEBRA_RPC_PORT:-8232}"
RELAY_INTERVAL="${RELAY_INTERVAL:-300}"

log() { printf "\033[1;36m==>\033[0m %s\n" "$*"; }
ok()  { printf "\033[1;32m ✓ \033[0m %s\n" "$*"; }
err() { printf "\033[1;31m ✗ \033[0m %s\n" "$*" >&2; }

is_running() { pgrep -f "$1" >/dev/null 2>&1; }

# Ensure cargo env loaded (zebrad mungkin di ~/.cargo/bin)
[[ -f "$HOME_DIR/.cargo/env" ]] && source "$HOME_DIR/.cargo/env"

if ! command -v zebrad >/dev/null 2>&1; then
  err "zebrad tidak ditemukan. Jalankan install.sh dulu."
  exit 1
fi

# Start zebrad
if is_running "zebrad start"; then
  ok "zebrad sudah jalan"
else
  log "Start zebrad..."
  nohup zebrad start > "$ZEBRA_LOG" 2>&1 &
  sleep 3
  is_running "zebrad start" && ok "zebrad started" || { err "zebrad gagal start"; tail -20 "$ZEBRA_LOG"; exit 1; }
fi

# Start relay watcher
if is_running "depinzcash-relay watch"; then
  ok "Relay watcher sudah jalan"
else
  [[ -x "$RELAY_BIN" && -f "$KEYPAIR" && -f "$RELAY_STATE" ]] || {
    err "Relay belum di-setup. Jalankan install.sh dulu."
    exit 1
  }
  log "Start relay watcher..."
  nohup "$RELAY_BIN" watch \
    --api "$API_URL" \
    --keypair "$KEYPAIR" \
    --state "$RELAY_STATE" \
    --node-rpc "http://127.0.0.1:$ZEBRA_RPC_PORT" \
    --interval-secs "$RELAY_INTERVAL" > "$RELAY_LOG" 2>&1 &
  sleep 3
  is_running "depinzcash-relay watch" && ok "Relay started" || { err "Relay gagal start"; tail -20 "$RELAY_LOG"; exit 1; }
fi

echo ""
ok "Semua running. Monitor:"
echo "    tail -f $ZEBRA_LOG"
echo "    tail -f $RELAY_LOG"
