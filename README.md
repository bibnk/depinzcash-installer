# DePINZcash Auto-Installer (Ubuntu)

Script otomatis untuk setup [DePINZcash](https://github.com/ZcashDePIN/DePINZcash) relay node di Ubuntu — tested di Ubuntu 22.04 / 24.04, fresh VPS.

> Adaptasi dari panduan **@cliviusss** ([pastebin](https://pastebin.com/787tFsc5)) dengan tambahan dependency fix yang sering kelewat (libssl-dev, protobuf-compiler, ~/.config dir).

## 📦 Requirements

- Ubuntu 22.04 / 24.04 (atau Debian)
- 4 CPU, 4-8 GB RAM, 120 GB SSD
- Akses root (atau user dengan sudo)
- Koneksi internet stabil (download crates + sync chain)

## 🚀 Install

### One-shot (interactive)
```bash
bash install.sh
```

### Non-interactive (untuk automation)
```bash
LABEL="bibnk-vps-01" bash install.sh
```

Total waktu: ~30-90 menit (tergantung CPU). Mostly compile time untuk `zebrad` dan `depinzcash-relay`.

## 📂 Files

| File | Fungsi |
|---|---|
| `install.sh` | Full installer: deps → Rust → zebrad → relay → register → start |
| `restart.sh` | Restart zebrad + relay setelah server reboot |
| `status.sh` | Cek status semua komponen + count accepted/rejected |

## 🔧 Yang Lerouta Tambahkan vs Panduan Original

Panduan original sering gagal di Ubuntu fresh karena:

| Masalah | Fix di script ini |
|---|---|
| `openssl-sys` build error | Auto-install `pkg-config libssl-dev` |
| `protoc not found` | Auto-install `protobuf-compiler` |
| `~/.config: NotFound` saat `zebrad generate` | Auto-`mkdir -p ~/.config` |
| Edit `[rpc]` manual via nano | Auto-patch via Python (idempotent) |
| Build ulang zebrad/relay walau sudah ada | Skip kalau binary exists |
| Tidak ada cara cek status | Ada `status.sh` |
| Manual register tiap reboot | State file di-cache, auto skip |

## 🔄 After Server Reboot

```bash
bash restart.sh
```

Lebih bersih daripada paste banyak `nohup ... &` lagi.

## 📊 Monitoring

```bash
bash status.sh        # snapshot semua status
tail -f ~/relay.log   # live relay activity
tail -f ~/zebrad.log  # live sync progress
```

Look for `verdict=accepted` di relay log = node Yang Mulia kerja & dapat reward.

## 💰 Wallet (Phantom Import)

Setelah install selesai, wallet address ditampilkan di output. Untuk import ke Phantom:

```bash
cat ~/DePINZcash/config/solana-keypair.json
```

Copy value `keypair_b58` (atau base58-encoded private key) → Phantom → Add Wallet → Import Private Key → Paste.

## 🔐 PENTING: Backup Keypair

```bash
cp ~/DePINZcash/config/solana-keypair.json ~/keypair-backup.json
```

Atau kirim ke storage aman (encrypted, jangan ke email biasa). **Kalau hilang, reward Yang Mulia tidak bisa diklaim — tidak ada recovery.**

## 🐛 Troubleshooting

### Build error `openssl-sys`
```bash
apt install -y pkg-config libssl-dev
```

### Build error `protoc not found`
```bash
apt install -y protobuf-compiler
```

### `~/.config: NotFound`
```bash
mkdir -p ~/.config
```

### Zebrad tidak nyala / port 8232 tidak respond
```bash
tail -50 ~/zebrad.log
```

Sync awal bisa makan 4-24 jam. Selama log menunjukkan progress (height naik), sabar saja.

### Relay log: `verdict=rejected`
Biasanya karena Zebra belum cukup sync. Tunggu sampai chain tip tercapai, biasanya `accepted` mulai muncul.

### OOM saat build
VPS 8 GB kadang masih OOM. Tambah swap:
```bash
fallocate -l 4G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
```

## 📜 Credit

- Original guide: **@cliviusss** ([pastebin](https://pastebin.com/787tFsc5))
- DePINZcash project: https://github.com/ZcashDePIN/DePINZcash
- Zcash Zebra full node: https://github.com/ZcashFoundation/zebra
