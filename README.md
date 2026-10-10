# Setup VPS — XFCE + xrdp

Setup otomatis VPS Ubuntu/Debian menjadi desktop XFCE yang bisa diakses lewat Remote Desktop (mstsc).

## Cara pakai

Login ke VPS lewat SSH (Termius), lalu jalankan:

```bash
curl -fsSL https://raw.githubusercontent.com/USER/REPO/main/setup-vps.sh -o setup-vps.sh && sudo bash setup-vps.sh
```

Script akan menanyakan password untuk user desktop, lalu berjalan sendiri 10–20 menit.

### Tanpa interaksi sama sekali

```bash
curl -fsSL https://raw.githubusercontent.com/USER/REPO/main/setup-vps.sh -o setup-vps.sh && sudo PASSWORD='FrasaRahasiaAnda' bash setup-vps.sh
```

### Mengubah pengaturan

Semua pengaturan di bagian atas script bisa ditimpa dari perintah:

```bash
sudo PASSWORD='...' RDP_PORT=23389 INSTALL_CHROME=no SWAP_SIZE=2G bash setup-vps.sh
```

| Variabel | Default | Keterangan |
|---|---|---|
| `USERNAME` | `ubuntu` | User desktop (tidak boleh root) |
| `PASSWORD` | — | Wajib; ditanyakan kalau tidak diberikan |
| `RDP_PORT` | `13389` | Port Remote Desktop |
| `SWAP_SIZE` | `auto` | `auto`, `2G`, `4G`, `8G`, `off` |
| `INSTALL_CHROME` | `yes` | Google Chrome |
| `INSTALL_PYTHON` | `yes` | venv + paket Python |
| `PROJECT_DIR` | `projects/bot1` | Lokasi venv, relatif ke home |
| `INSTALL_FAIL2BAN` | `no` | Proteksi brute-force |
| `REBOOT_MODE` | `auto` | `auto`, `end`, `no` |

## Setelah selesai

Dari Windows: `Win + R` → `mstsc` → `IP_VPS:13389`, login dengan user dan password tadi.

> Jangan pernah menulis password di file ini atau di repo — repo publik bisa dibaca siapa saja.
