#!/usr/bin/env bash
# DePINZcash Relay — Ubuntu auto-installer
# Tested on Ubuntu 22.04 / 24.04
#
# Usage:
#   bash install.sh                          # interactive
#   LABEL="my-node" bash install.sh          # non-interactive
#
# Requirements: Linux server, 4 CPU, 4-8GB RAM, 120GB SSD
# Source guide: https://pastebin.com/787tFsc5  (credit: @cliviusss)

set -euo pipefail

# ===== CONFIG =====
LABEL="${LABEL:-}"                                     # label node, akan diminta interaktif kalau kosong
API_URL="${API_URL:-https://api.zcashdepin.com}"
ZEBRA_RPC_PORT="${ZEBRA_RPC_PORT:-8232}"
RELAY_INTERVAL="${RELAY_INTERVAL:-300}"
DEPIN_REPO="${DEPIN_REPO:-https://github.com/ZcashDePIN/DePINZcash.git}"
HOME_DIR="${HOME:-/root}"
DEPIN_DIR="$HOME_DIR/DePINZcash"
CONFIG_DIR="$HOME_DIR/.config"
ZEBRA_CONFIG="$CONFIG_DIR/zebrad.toml"
RELAY_BIN="$DEPIN_DIR/prover/target/release/depinzcash-relay"
KEYPAIR="$DEPIN_DIR/config/solana-keypair.json"
RELAY_STATE="$DEPIN_DIR/config/relay-state.json"
ZEBRA_LOG="$HOME_DIR/zebrad.log"
RELAY_LOG="$HOME_DIR/relay.log"

# ===== Helpers =====
log()  { printf "\033[1;36m==>\033[0m %s\n" "$*"; }
ok()   { printf "\033[1;32m ✓ \033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m ! \033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m ✗ \033[0m %s\n" "$*" >&2; }

asroot() {
  if [[ $EUID -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    err "Bukan root dan sudo tidak ada. Login sebagai root atau install sudo."
    exit 1
  fi
}

require_ubuntu() {
  if ! command -v apt-get >/dev/null 2>&1; then
    err "Script ini khusus Ubuntu/Debian (butuh apt-get)."
    exit 1
  fi
}

is_running() {
  pgrep -f "$1" >/dev/null 2>&1
}

# ===== Step 0: Pre-flight =====
require_ubuntu

if [[ -z "$LABEL" ]]; then
  read -rp "$(printf '\033[1;36m? \033[0mNode label (mis. bibnk-vps-01): ')" LABEL
  [[ -z "$LABEL" ]] && LABEL="node-$(hostname | tr -cd 'a-zA-Z0-9-')-$(date +%s | tail -c 5)"
fi

log "Configuration:"
echo "    LABEL          : $LABEL"
echo "    API URL        : $API_URL"
echo "    Zebra RPC port : $ZEBRA_RPC_PORT"
echo "    Relay interval : ${RELAY_INTERVAL}s"
echo ""
read -rp "$(printf '\033[1;36m? \033[0mLanjut install? (Y/n): ')" CONFIRM
[[ "${CONFIRM:-y}" =~ ^[Nn] ]] && { warn "Cancelled."; exit 0; }

# ===== Step 1: Install all build dependencies =====
log "Step 1/7 — Install system dependencies"
asroot apt-get update -qq
# build-essential: gcc, make
# pkg-config + libssl-dev: openssl-sys crate (sering missing → error utama Yang Mulia)
# protobuf-compiler: zebrad build dependency
# cmake clang libclang-dev: zebrad C deps
# git curl: clone repo & download
# ca-certificates: TLS untuk crates.io
asroot apt-get install -y -qq \
  build-essential \
  pkg-config \
  libssl-dev \
  protobuf-compiler \
  cmake \
  clang \
  libclang-dev \
  git \
  curl \
  ca-certificates
ok "System deps installed"

# ===== Step 1.5: Auto-create swap (CRITICAL untuk VPS <16GB RAM) =====
log "Step 1.5/7 — Check & setup swap"
TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
SWAP_MB=$(free -m | awk '/^Swap:/{print $2}')

if [[ "$SWAP_MB" -gt 0 ]]; then
  ok "Swap sudah aktif: ${SWAP_MB} MB"
elif [[ "$TOTAL_RAM_MB" -ge 16384 ]]; then
  ok "RAM ${TOTAL_RAM_MB} MB cukup besar, skip swap"
else
  # Calculate swap size: 4GB minimum, atau 50% RAM kalau RAM <8GB
  if [[ "$TOTAL_RAM_MB" -lt 8192 ]]; then
    SWAP_SIZE="4G"
  else
    SWAP_SIZE="4G"
  fi
  warn "RAM cuma ${TOTAL_RAM_MB} MB tanpa swap → zebrad bakal stall saat verify block."
  warn "Membuat ${SWAP_SIZE} swap file di /swapfile..."

  if [[ ! -f /swapfile ]]; then
    asroot fallocate -l "$SWAP_SIZE" /swapfile || asroot dd if=/dev/zero of=/swapfile bs=1M count=4096 status=progress
    asroot chmod 600 /swapfile
    asroot mkswap /swapfile
  fi
  asroot swapon /swapfile 2>/dev/null || warn "swapon failed (mungkin sudah ON)"

  # Persist di fstab kalau belum ada
  if ! grep -q '^/swapfile' /etc/fstab; then
    echo '/swapfile none swap sw 0 0' | asroot tee -a /etc/fstab >/dev/null
  fi

  # Tune swappiness (jangan terlalu agresif pakai swap)
  if ! grep -q '^vm.swappiness' /etc/sysctl.conf; then
    echo 'vm.swappiness=10' | asroot tee -a /etc/sysctl.conf >/dev/null
    asroot sysctl -q vm.swappiness=10 2>/dev/null || true
  fi

  ok "Swap activated: $(free -h | awk '/^Swap:/{print $2}') (swappiness=10)"
fi

# ===== Step 2: Install Rust =====
log "Step 2/7 — Install/check Rust toolchain"
if [[ ! -f "$HOME_DIR/.cargo/env" ]]; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
fi
# shellcheck source=/dev/null
source "$HOME_DIR/.cargo/env"
RUST_VER=$(rustc --version)
ok "Rust ready: $RUST_VER"

# ===== Step 3: Install zebrad =====
log "Step 3/7 — Install zebrad (Zcash full node)"
if command -v zebrad >/dev/null 2>&1; then
  ok "zebrad sudah terinstall: $(zebrad --version 2>&1 | head -1)"
else
  log "Compiling zebrad — bisa 30-60 menit di VPS 4 CPU 8GB"
  cargo install --locked zebrad
  ok "zebrad installed"
fi

# ===== Step 4: Generate & patch zebrad config =====
log "Step 4/7 — Configure zebrad RPC"
mkdir -p "$CONFIG_DIR"
if [[ ! -f "$ZEBRA_CONFIG" ]]; then
  zebrad generate -o "$ZEBRA_CONFIG"
  ok "zebrad config generated: $ZEBRA_CONFIG"
fi

# Patch [rpc] section secara idempoten
python3 - "$ZEBRA_CONFIG" "$ZEBRA_RPC_PORT" <<'PY'
import sys, re, pathlib
path, port = sys.argv[1], sys.argv[2]
src = pathlib.Path(path).read_text()
listen = f'127.0.0.1:{port}'

# Cari section [rpc]
pat = re.compile(r'(\[rpc\][^\[]*)', re.S)
m = pat.search(src)
if m:
    block = m.group(1)
    # Replace listen_addr
    if re.search(r'^\s*#?\s*listen_addr\s*=', block, re.M):
        block = re.sub(r'^\s*#?\s*listen_addr\s*=.*$',
                       f'listen_addr = "{listen}"', block, flags=re.M)
    else:
        block = block.rstrip() + f'\nlisten_addr = "{listen}"\n'
    # Replace enable_cookie_auth
    if re.search(r'^\s*#?\s*enable_cookie_auth\s*=', block, re.M):
        block = re.sub(r'^\s*#?\s*enable_cookie_auth\s*=.*$',
                       'enable_cookie_auth = false', block, flags=re.M)
    else:
        block = block.rstrip() + '\nenable_cookie_auth = false\n'
    src = pat.sub(block, src, count=1)
else:
    src += f'\n[rpc]\nlisten_addr = "{listen}"\nenable_cookie_auth = false\n'

pathlib.Path(path).write_text(src)
print(f"   patched [rpc] → listen_addr={listen}, enable_cookie_auth=false")
PY

ok "zebrad config patched"

# ===== Step 5: Start zebrad =====
log "Step 5/7 — Start zebrad in background"
if is_running "zebrad start"; then
  ok "zebrad sudah jalan, skip start"
else
  nohup zebrad start > "$ZEBRA_LOG" 2>&1 &
  sleep 3
  if is_running "zebrad start"; then
    ok "zebrad started → log: $ZEBRA_LOG"
    warn "Sync butuh 4-24 jam. Relay akan accepted setelah Zebra cukup tersinkron."
  else
    err "zebrad gagal start. Cek log:"
    tail -20 "$ZEBRA_LOG"
    exit 1
  fi
fi

# ===== Step 6: Build relay =====
log "Step 6/7 — Clone & build DePINZcash relay"
if [[ ! -d "$DEPIN_DIR/.git" ]]; then
  git clone "$DEPIN_REPO" "$DEPIN_DIR"
else
  ok "Repo sudah di-clone, pull update"
  (cd "$DEPIN_DIR" && git pull --ff-only) || warn "git pull gagal, pakai versi lokal"
fi

if [[ ! -x "$RELAY_BIN" ]]; then
  log "Compiling depinzcash-relay (5-15 menit)"
  (cd "$DEPIN_DIR/prover" && cargo build --release --bin depinzcash-relay)
fi
[[ -x "$RELAY_BIN" ]] || { err "Build relay gagal."; exit 1; }
ok "Relay binary ready: $RELAY_BIN"

# ===== Step 7: Keygen + register + start watcher =====
log "Step 7/7 — Setup wallet & register node"
mkdir -p "$DEPIN_DIR/config"

if [[ ! -f "$KEYPAIR" ]]; then
  "$RELAY_BIN" keygen --out "$KEYPAIR"
  ok "Wallet baru digenerate: $KEYPAIR"
else
  ok "Wallet sudah ada, pakai yang lama: $KEYPAIR"
fi

# Extract public key untuk display (prefer 'address' / 'pubkey' field)
if command -v jq >/dev/null 2>&1; then
  PUBKEY=$(jq -r '.address // .pubkey // .public_key // empty' "$KEYPAIR" 2>/dev/null || echo "")
else
  PUBKEY=$(python3 -c "import json,sys; d=json.load(open('$KEYPAIR')); print(d.get('address') or d.get('pubkey') or d.get('public_key') or '')" 2>/dev/null || echo "")
fi

if [[ ! -f "$RELAY_STATE" ]]; then
  log "Register node ke API (auto-retry karena API DePINZcash kadang slow/cold-start)..."
  REGISTER_OK=0
  for attempt in 1 2 3 4 5; do
    log "  Attempt $attempt/5..."
    if "$RELAY_BIN" register \
        --api "$API_URL" \
        --keypair "$KEYPAIR" \
        --kind zebra-full \
        --label "$LABEL" \
        --state "$RELAY_STATE" 2>&1 | tee /tmp/depin-register.out; then
      if [[ -f "$RELAY_STATE" ]]; then
        REGISTER_OK=1
        break
      fi
    fi
    # Detect transient timeout errors
    if grep -qE "operation timed out|connect.*timed out|503|502|504" /tmp/depin-register.out 2>/dev/null; then
      backoff=$((attempt * 10))
      warn "Transient error, retry dalam ${backoff}s..."
      sleep "$backoff"
    else
      err "Non-transient error, hentikan retry. Lihat output di atas."
      break
    fi
  done
  if [[ "$REGISTER_OK" -eq 1 ]]; then
    ok "Node registered"
  else
    err "Gagal register setelah 5 attempt. Coba manual nanti dengan:"
    echo "    $RELAY_BIN register \\"
    echo "      --api $API_URL \\"
    echo "      --keypair $KEYPAIR \\"
    echo "      --kind zebra-full \\"
    echo "      --label \"$LABEL\" \\"
    echo "      --state $RELAY_STATE"
    echo ""
    warn "Skip Step 7 watcher karena belum ter-register."
    exit 1
  fi
fi

# Start watcher
if is_running "depinzcash-relay watch"; then
  ok "Relay watcher sudah jalan"
else
  nohup "$RELAY_BIN" watch \
    --api "$API_URL" \
    --keypair "$KEYPAIR" \
    --state "$RELAY_STATE" \
    --node-rpc "http://127.0.0.1:$ZEBRA_RPC_PORT" \
    --interval-secs "$RELAY_INTERVAL" > "$RELAY_LOG" 2>&1 &
  sleep 3
  if is_running "depinzcash-relay watch"; then
    ok "Relay watcher started → log: $RELAY_LOG"
  else
    err "Relay gagal start. Cek log: tail -30 $RELAY_LOG"
    exit 1
  fi
fi

# ===== DONE =====
echo ""
printf "\033[1;32m═══════════════════════════════════════════════════════\033[0m\n"
printf "\033[1;32m  ✅ INSTALL COMPLETE\033[0m\n"
printf "\033[1;32m═══════════════════════════════════════════════════════\033[0m\n"
echo ""
[[ -n "$PUBKEY" ]] && echo "  Wallet address  : $PUBKEY"
echo "  Node label      : $LABEL"
echo "  Keypair file    : $KEYPAIR"
echo ""
echo "  Live monitoring:"
echo "    tail -f $RELAY_LOG"
echo "    tail -f $ZEBRA_LOG"
echo ""
echo "  Setelah server restart, jalankan:"
echo "    bash $0 --restart   # (atau script restart.sh)"
echo ""
warn "Backup keypair file ini ($KEYPAIR) — kalau hilang, reward Yang Mulia gak bisa diklaim."
