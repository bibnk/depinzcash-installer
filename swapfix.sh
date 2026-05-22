#!/usr/bin/env bash
# Standalone swap fixer untuk VPS yang sudah terlanjur kena stall.
# Aman dijalankan walau zebrad lagi running — tidak butuh restart.
#
# Usage: bash swapfix.sh

set -euo pipefail

log()  { printf "\033[1;36m==>\033[0m %s\n" "$*"; }
ok()   { printf "\033[1;32m ✓ \033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m ! \033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m ✗ \033[0m %s\n" "$*" >&2; }

asroot() {
  if [[ $EUID -eq 0 ]]; then "$@"
  elif command -v sudo >/dev/null 2>&1; then sudo "$@"
  else err "Bukan root dan sudo tidak ada."; exit 1
  fi
}

SWAP_SIZE="${SWAP_SIZE:-4G}"
SWAP_FILE="${SWAP_FILE:-/swapfile}"

log "Cek kondisi memory & swap"
free -h
echo ""

CURRENT_SWAP_MB=$(free -m | awk '/^Swap:/{print $2}')
if [[ "$CURRENT_SWAP_MB" -gt 0 ]]; then
  ok "Swap sudah aktif: ${CURRENT_SWAP_MB} MB"
  warn "Tidak melakukan apa-apa. Kalau mau resize, hapus dulu swap lama."
  exit 0
fi

log "Buat swap file ${SWAP_SIZE} di ${SWAP_FILE}"
if [[ -f "$SWAP_FILE" ]]; then
  warn "$SWAP_FILE sudah ada — pakai yang ada."
else
  asroot fallocate -l "$SWAP_SIZE" "$SWAP_FILE" || \
    asroot dd if=/dev/zero of="$SWAP_FILE" bs=1M count=4096 status=progress
fi
asroot chmod 600 "$SWAP_FILE"
asroot mkswap "$SWAP_FILE" >/dev/null
asroot swapon "$SWAP_FILE"
ok "Swap aktif"

log "Persist di /etc/fstab"
if ! grep -q "^${SWAP_FILE}" /etc/fstab; then
  echo "${SWAP_FILE} none swap sw 0 0" | asroot tee -a /etc/fstab >/dev/null
  ok "Ditambah ke /etc/fstab"
else
  ok "Sudah ada di /etc/fstab"
fi

log "Tune swappiness (jangan terlalu agresif swap)"
if ! grep -q '^vm.swappiness' /etc/sysctl.conf; then
  echo 'vm.swappiness=10' | asroot tee -a /etc/sysctl.conf >/dev/null
fi
asroot sysctl -q vm.swappiness=10 2>/dev/null || true
ok "swappiness=10"

echo ""
log "Hasil akhir:"
free -h
echo ""
ok "Done. Zebrad seharusnya mulai sync stabil dalam 10-15 menit."
echo "    Monitor: tail -f ~/zebrad.log | grep current_height"
