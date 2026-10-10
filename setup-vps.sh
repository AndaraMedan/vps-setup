#!/usr/bin/env bash
###############################################################################
#  SETUP VPS OTOMATIS  —  Ubuntu/Debian + XFCE + xrdp (Remote Desktop)
#  Berdasarkan "Panduan Setup VPS" — sekali jalan, tanpa interaksi.
#
#  CARA PAKAI (langsung dari GitHub — tanpa upload manual)
#
#     curl -fsSL https://raw.githubusercontent.com/USER/REPO/main/setup-vps.sh -o setup-vps.sh \
#       && sudo bash setup-vps.sh
#
#     Password akan ditanyakan saat script mulai. Untuk tanpa interaksi sama sekali:
#
#       sudo PASSWORD='FrasaRahasiaAnda' bash setup-vps.sh
#
#     Semua pengaturan di bawah bisa ditimpa dengan cara yang sama, contoh:
#       sudo PASSWORD='...' RDP_PORT=23389 INSTALL_CHROME=no bash setup-vps.sh
#
#  JANGAN tulis password di file ini — file ini publik di GitHub.
#
#  AMAN DIJALANKAN ULANG. Setiap langkah memeriksa kondisi lebih dulu,
#  jadi kalau terputus di tengah, jalankan lagi perintah yang sama.
###############################################################################

# Kalau script dilanjutkan otomatis setelah reboot, pengaturan run pertama
# dimuat dari sini (hanya root yang bisa membaca, dihapus saat selesai).
SAVED_CONF="/var/lib/setup-vps/config"
# shellcheck disable=SC1090
[ -r "$SAVED_CONF" ] && [ "$(id -u)" -eq 0 ] && . "$SAVED_CONF"

# ╔══════════ PENGATURAN — nilai default, bisa ditimpa dari perintah ═════════╗

  USERNAME="${USERNAME:-ubuntu}"                  # user desktop. xrdp menolak login root.
  PASSWORD="${PASSWORD:-}"                        # JANGAN diisi di sini. Ditanyakan saat jalan,
                                                  # atau beri lewat: sudo PASSWORD='...' bash ...
  RDP_PORT="${RDP_PORT:-13389}"                   # port RDP non-standar

  SWAP_SIZE="${SWAP_SIZE:-auto}"                  # auto | 2G | 4G | 8G | off
                                                  #   auto: RAM <6GB -> 4G, RAM >=6GB -> 8G

  ENABLE_UFW_IF_INACTIVE="${ENABLE_UFW_IF_INACTIVE:-no}"
                                                  # no  = ufw yang mati dibiarkan mati
                                                  # yes = nyalakan ufw dengan 22 + RDP_PORT terbuka

  INSTALL_CHROME="${INSTALL_CHROME:-yes}"         # Chrome + matikan akselerasi GPU
  INSTALL_GEANY="${INSTALL_GEANY:-yes}"           # editor teks ringan
  INSTALL_DRIVE_REDIRECT="${INSTALL_DRIVE_REDIRECT:-yes}"  # drive PC muncul di VPS lewat mstsc
  INSTALL_FAIL2BAN="${INSTALL_FAIL2BAN:-no}"
  MAKE_RDP_FILE="${MAKE_RDP_FILE:-yes}"           # file .rdp siap pakai untuk Windows

  INSTALL_PYTHON="${INSTALL_PYTHON:-yes}"
  PROJECT_DIR="${PROJECT_DIR:-projects/bot1}"     # relatif ke home user
  PYTHON_PACKAGES="${PYTHON_PACKAGES:-requests urllib3 beautifulsoup4 flask google-genai acme josepy cryptography PyYAML google-api-python-client google-auth}"

  REBOOT_MODE="${REBOOT_MODE:-auto}"              # auto = reboot di tengah HANYA kalau sistem
                                                  #        memintanya, lalu LANJUT SENDIRI
                                                  # end  = reboot sekali di akhir
                                                  # no   = tidak pernah reboot

# ╚══════════════════════════════════════════════════════════════════════════╝


set -Eeuo pipefail

LOG="/var/log/setup-vps.log"
START_TS=$(date +%s)
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
APT_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

if [ -t 1 ]; then
  C_R=$'\033[0m'; C_B=$'\033[1m'; C_G=$'\033[32m'; C_Y=$'\033[33m'
  C_RD=$'\033[31m'; C_C=$'\033[36m'; C_D=$'\033[2m'
else
  C_R=; C_B=; C_G=; C_Y=; C_RD=; C_C=; C_D=
fi

STEP_N=0
step() { STEP_N=$((STEP_N+1)); printf '\n%s\n%s[%02d/%02d]%s %s%s%s\n' \
  "$(printf '─%.0s' {1..70})" "$C_C" "$STEP_N" "$TOTAL_STEPS" "$C_R" "$C_B" "$1" "$C_R"; }
info() { printf '  %s\n' "$1"; }
ok()   { printf '  %s✓%s %s\n' "$C_G" "$C_R" "$1"; }
warn() { printf '  %s!%s %s\n' "$C_Y" "$C_R" "$1"; }
die()  { printf '\n%sGAGAL:%s %s\n' "$C_RD" "$C_R" "$1" >&2; exit 1; }

trap 'printf "\n%sGAGAL di baris %s:%s %s\n\nLog lengkap: %s\nPerbaiki lalu jalankan ulang script ini — langkah yang sudah selesai akan dilewati.\n" "$C_RD" "$LINENO" "$C_R" "$BASH_COMMAND" "$LOG" >&2' ERR

TOTAL_STEPS=12

# ─────────────────────────── helper ────────────────────────────────────────
APT_LOCKS=(/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock
           /var/lib/apt/lists/lock /var/cache/apt/archives/lock)

# Periksa file lock yang sebenarnya, BUKAN nama proses.
# Ubuntu menjalankan 'unattended-upgrade-shutdown' sebagai daemon permanen —
# mencocokkan nama proses membuat script menunggu sesuatu yang tidak akan pernah selesai.
apt_busy() {
  if have fuser; then
    fuser "${APT_LOCKS[@]}" >/dev/null 2>&1
  else
    pgrep -x apt >/dev/null 2>&1 || pgrep -x apt-get >/dev/null 2>&1 || pgrep -x dpkg >/dev/null 2>&1
  fi
}

wait_apt() {
  local waited=0 holder cmd
  apt_busy || return 0
  if have fuser; then
    holder=$(fuser "${APT_LOCKS[@]}" 2>/dev/null | tr -s ' ' '\n' | grep -E '^[0-9]+$' | head -1 || true)
    if [ -n "$holder" ] && [ -r "/proc/$holder/cmdline" ]; then
      cmd=$(tr '\0' ' ' < "/proc/$holder/cmdline" 2>/dev/null | cut -c1-70 || true)
      info "Lock apt dipegang PID $holder: $cmd"
    fi
  fi
  info "Menunggu apt lain selesai (biasanya unattended-upgrades saat boot pertama)..."
  while apt_busy; do
    sleep 10; waited=$((waited+10))
    [ $((waited % 60)) -eq 0 ] && info "  ...masih menunggu, ${waited} detik"
    if [ "$waited" -ge 480 ]; then
      warn "Lock belum lepas setelah 8 menit — lanjut saja, apt akan menunggu sendiri."
      return 0
    fi
  done
  ok "Lock apt bebas setelah ${waited} detik"
  return 0
}
apt_run() {
  local try
  for try in 1 2 3; do
    wait_apt
    if apt-get "$@"; then return 0; fi
    warn "apt gagal (percobaan $try/3), mengulang dalam 15 detik..."
    sleep 15
  done
  return 1
}
as_user() { sudo -u "$USERNAME" -H env HOME="$USER_HOME" "$@"; }
have()    { command -v "$1" >/dev/null 2>&1; }

# ─────────────────────────── preflight ─────────────────────────────────────
clear 2>/dev/null || true
printf '%s╔═══════════════════════════════════════════════════════════════╗\n' "$C_B"
printf '║   SETUP VPS OTOMATIS — XFCE + xrdp                            ║\n'
printf '╚═══════════════════════════════════════════════════════════════╝%s\n' "$C_R"

[ "$(id -u)" -eq 0 ] || die "Jalankan sebagai root:  sudo bash $0"
[ "$USERNAME" != "root" ] || die "USERNAME tidak boleh root — xrdp menolak login root."
# Password: dari variabel lingkungan, atau ditanyakan lewat terminal.
# Membaca dari /dev/tty supaya tetap jalan walau script dialirkan lewat pipa.
if [ -z "$PASSWORD" ]; then
  if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    while :; do
      printf '\n  Password untuk user %s (min. 8 karakter, tidak tampil): ' "$USERNAME" > /dev/tty
      IFS= read -rs P1 < /dev/tty; printf '\n' > /dev/tty
      printf '  Ulangi password: ' > /dev/tty
      IFS= read -rs P2 < /dev/tty; printf '\n' > /dev/tty
      if [ "$P1" != "$P2" ]; then printf '  Tidak sama, coba lagi.\n' > /dev/tty; continue; fi
      if [ ${#P1} -lt 8 ];   then printf '  Terlalu pendek, coba lagi.\n' > /dev/tty; continue; fi
      PASSWORD="$P1"; break
    done
    unset P1 P2
  else
    die "PASSWORD belum diisi. Jalankan:  sudo PASSWORD='frasa-rahasia' bash $0"
  fi
fi
[ ${#PASSWORD} -ge 8 ] || die "PASSWORD terlalu pendek (minimal 8 karakter)."
[[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "USERNAME tidak valid: $USERNAME"
[[ "$RDP_PORT" =~ ^[0-9]+$ ]] && [ "$RDP_PORT" -ge 1024 ] && [ "$RDP_PORT" -le 65535 ] \
  || die "RDP_PORT tidak valid: $RDP_PORT"
have apt-get || die "Script ini untuk Ubuntu/Debian (apt tidak ditemukan)."

exec > >(tee -a "$LOG") 2>&1
printf '%s' "$C_D"; echo "Log: $LOG · dimulai $(date '+%Y-%m-%d %H:%M:%S')"; printf '%s' "$C_R"

# Beberapa image root-only tidak punya sudo/curl. Pasang dulu, tanpa itu
# langkah-langkah berikutnya akan gagal dengan pesan yang membingungkan.
BOOTSTRAP=()
have sudo  || BOOTSTRAP+=(sudo)
have curl  || BOOTSTRAP+=(curl)
have ip    || BOOTSTRAP+=(iproute2)
have fuser || BOOTSTRAP+=(psmisc)     # dipakai untuk mendeteksi lock apt dengan benar
[ -s /etc/ssl/certs/ca-certificates.crt ] || BOOTSTRAP+=(ca-certificates)
if [ ${#BOOTSTRAP[@]} -gt 0 ]; then
  info "Memasang prasyarat: ${BOOTSTRAP[*]}"
  apt-get update -qq || true
  apt-get install -y -qq "${BOOTSTRAP[@]}" >/dev/null || die "Gagal memasang: ${BOOTSTRAP[*]}"
fi

get_pubip() {
  local ip
  ip=$(curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)
  [ -n "$ip" ] || ip=$(curl -fsS --max-time 8 https://ifconfig.me 2>/dev/null || true)
  [ -n "$ip" ] || ip=$(ip -4 -o addr show scope global 2>/dev/null \
                        | awk '{print $4}' | cut -d/ -f1 | head -1 || true)
  printf '%s' "${ip:-IP_SERVER}"
}

SELF=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)
STATE_DIR="/var/lib/setup-vps"
RESUME_UNIT="/etc/systemd/system/setup-vps-resume.service"
mkdir -p "$STATE_DIR"

# Unit resume hanya boleh jalan sekali. Kalau script sudah berjalan sekarang,
# unit-nya tidak diperlukan lagi — hapus supaya tidak menyala di boot berikutnya.
if [ -f "$RESUME_UNIT" ]; then
  systemctl disable setup-vps-resume.service >/dev/null 2>&1 || true
  rm -f "$RESUME_UNIT"
  systemctl daemon-reload >/dev/null 2>&1 || true
fi
[ -f "$STATE_DIR/rebooted" ] && info "Melanjutkan setelah reboot — langkah yang sudah selesai akan dilewati."

USER_HOME="/home/$USERNAME"
RAM_MB=$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo)
DISK_FREE_GB=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
PUBIP=$(get_pubip)

info "OS       : $( (. /etc/os-release && echo "$PRETTY_NAME") 2>/dev/null || echo unknown)"
info "RAM      : ${RAM_MB} MB   ·   Disk kosong: ${DISK_FREE_GB} GB"
info "IP publik: $PUBIP"
info "User     : $USERNAME   ·   Port RDP: $RDP_PORT"

# ═══ 01 · User non-root ════════════════════════════════════════════════════
step "Membuat user non-root"
if id -u "$USERNAME" >/dev/null 2>&1; then
  ok "User '$USERNAME' sudah ada"
else
  adduser --disabled-password --gecos "" "$USERNAME"
  ok "User '$USERNAME' dibuat"
fi
printf '%s:%s\n' "$USERNAME" "$PASSWORD" | chpasswd
usermod -aG sudo "$USERNAME" 2>/dev/null || usermod -aG wheel "$USERNAME" 2>/dev/null || true
USER_HOME=$(getent passwd "$USERNAME" | cut -d: -f6)
ok "Password diset, user masuk grup sudo · home: $USER_HOME"

# ═══ 02 · Update sistem ════════════════════════════════════════════════════
step "Update sistem (3–8 menit)"
apt_run update
apt_run "${APT_OPTS[@]}" upgrade
ok "Sistem diperbarui"

# Reboot di tengah — hanya kalau sistem sendiri yang memintanya (kernel/libc baru).
# Panduan menaruh reboot di sini; kenyataannya install XFCE/xrdp tetap berhasil di
# atas kernel lama. Jadi kita ikuti sistem, bukan reboot buta-buta.
if [ -f /var/run/reboot-required ] || [ -f /run/reboot-required ]; then
  if [ "$REBOOT_MODE" = "auto" ] && [ ! -f "$STATE_DIR/rebooted" ]; then
    warn "Sistem meminta reboot (kernel atau pustaka inti diperbarui)."
    info "Script akan reboot lalu MELANJUTKAN SENDIRI. Anda tidak perlu login lagi."
    if [ -z "$SELF" ] || [ ! -f "$SELF" ]; then
      warn "Script tidak dijalankan dari file (mis. lewat pipa) — tidak bisa melanjutkan otomatis."
      warn "Reboot dilewati; lakukan 'sudo reboot' setelah setup selesai."
    else
    touch "$STATE_DIR/rebooted"
    # Simpan pengaturan run ini agar dipakai lagi setelah reboot (root-only)
    ( umask 077
      for v in USERNAME PASSWORD RDP_PORT SWAP_SIZE ENABLE_UFW_IF_INACTIVE INSTALL_CHROME \
               INSTALL_GEANY INSTALL_DRIVE_REDIRECT INSTALL_FAIL2BAN MAKE_RDP_FILE \
               INSTALL_PYTHON PROJECT_DIR PYTHON_PACKAGES REBOOT_MODE; do
        printf '%s=%q\n' "$v" "${!v}"
      done > "$SAVED_CONF" )
    install -m 700 "$SELF" /usr/local/sbin/setup-vps.sh
    cat > "$RESUME_UNIT" <<EOF
[Unit]
Description=Lanjutkan setup VPS setelah reboot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash /usr/local/sbin/setup-vps.sh
TimeoutStartSec=3600
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable setup-vps-resume.service >/dev/null 2>&1 \
      || die "Gagal memasang unit resume — set REBOOT_MODE=\"end\" lalu jalankan ulang."
    printf '\n  %sReboot dalam 10 detik.%s Setup lanjut otomatis begitu server nyala.\n' "$C_Y$C_B" "$C_R"
    printf '  Masuk lagi lewat Termius ~1 menit kemudian dan pantau prosesnya:\n'
    printf '      %stail -f %s%s\n\n' "$C_B" "$LOG" "$C_R"
    sleep 10
    systemctl reboot
    exit 0
    fi
  else
    warn "Sistem meminta reboot — dilewati (REBOOT_MODE=$REBOOT_MODE). Reboot manual setelah selesai."
  fi
else
  ok "Tidak ada reboot yang dibutuhkan — lanjut"
fi

# ═══ 03 · Swap ═════════════════════════════════════════════════════════════
step "Menyiapkan swap"
if [ "$SWAP_SIZE" = "off" ]; then
  warn "Dilewati (SWAP_SIZE=off)"
elif swapon --show 2>/dev/null | grep -q .; then
  ok "Swap sudah aktif: $(free -h | awk '/^Swap:/{print $2}')"
else
  TARGET="$SWAP_SIZE"
  if [ "$SWAP_SIZE" = "auto" ]; then
    if   [ "$RAM_MB" -lt 6000 ]; then TARGET="4G"
    else                              TARGET="8G"; fi
    info "Ukuran otomatis dari RAM ${RAM_MB} MB → $TARGET"
  fi
  NEED_GB=${TARGET%G}
  if [ "$DISK_FREE_GB" -lt $((NEED_GB + 3)) ]; then
    warn "Disk kosong hanya ${DISK_FREE_GB} GB — swap diperkecil jadi 2G"
    TARGET="2G"; NEED_GB=2
  fi
  fallocate -l "$TARGET" /swapfile 2>/dev/null \
    || dd if=/dev/zero of=/swapfile bs=1M count=$((NEED_GB * 1024)) status=none
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  sysctl -qw vm.swappiness=10
  grep -q '^vm.swappiness' /etc/sysctl.conf || echo 'vm.swappiness=10' >> /etc/sysctl.conf
  ok "Swap aktif: $(free -h | awk '/^Swap:/{print $2}')"
fi

# ═══ 04 · Desktop XFCE + xrdp ══════════════════════════════════════════════
step "Install XFCE + xrdp (8–12 menit)"
echo "lightdm shared/default-x-display-manager select lightdm" | debconf-set-selections
echo "gdm3 shared/default-x-display-manager select lightdm"    | debconf-set-selections
apt_run "${APT_OPTS[@]}" install \
  xfce4 xfce4-goodies xrdp dbus-x11 \
  tmux htop git curl wget xclip xsel nano \
  python3-pip python3-venv python3-full
ok "Paket desktop terpasang"

info "Menghapus screen locker (mengunci sesi RDP dan tidak bisa dibuka)"
wait_apt
apt-get "${APT_OPTS[@]}" remove light-locker xfce4-screensaver >/dev/null 2>&1 || true
ok "Screen locker bersih"

# ═══ 05 · Konfigurasi xrdp ═════════════════════════════════════════════════
step "Mengonfigurasi xrdp di port $RDP_PORT"
printf 'xfce4-session\n' > "$USER_HOME/.xsession"
chmod +x "$USER_HOME/.xsession"
chown "$USERNAME:$USERNAME" "$USER_HOME/.xsession"

adduser xrdp ssl-cert >/dev/null 2>&1 || true

cp -n /etc/xrdp/xrdp.ini /etc/xrdp/xrdp.ini.bak 2>/dev/null || true
# hanya baris "port=3389" di [Globals] yang cocok; "port=-1" di [Xorg] tidak tersentuh
sed -i -E "s/^port=[0-9]+/port=$RDP_PORT/" /etc/xrdp/xrdp.ini
grep -qE "^port=$RDP_PORT\$" /etc/xrdp/xrdp.ini || die "Gagal mengubah port di /etc/xrdp/xrdp.ini"

# tampilan lebih enak lewat jaringan
sed -i -E 's/^max_bpp=.*/max_bpp=24/'                /etc/xrdp/xrdp.ini 2>/dev/null || true
sed -i -E 's/^crypt_level=.*/crypt_level=high/'      /etc/xrdp/xrdp.ini 2>/dev/null || true

systemctl enable xrdp >/dev/null 2>&1
systemctl restart xrdp
sleep 3
if ss -tlnp 2>/dev/null | grep -q ":$RDP_PORT "; then
  ok "xrdp LISTEN di port $RDP_PORT"
else
  systemctl status xrdp --no-pager -l || true
  die "xrdp tidak mendengarkan di port $RDP_PORT — lihat status di atas."
fi

info "Memasang aturan polkit (popup autentikasi berulang)"
mkdir -p /etc/polkit-1/rules.d
cat > /etc/polkit-1/rules.d/02-allow-colord.rules <<'EOF'
polkit.addRule(function(action, subject) {
  if (action.id.indexOf("org.freedesktop.color-manager.") == 0) {
    return polkit.Result.YES;
  }
});
EOF
cat > /etc/polkit-1/rules.d/03-allow-network-manager.rules <<'EOF'
polkit.addRule(function(action, subject) {
  if (action.id.indexOf("org.freedesktop.NetworkManager.") == 0 &&
      subject.isInGroup("sudo")) {
    return polkit.Result.YES;
  }
});
EOF
ok "Aturan polkit terpasang"

# ═══ 06 · Firewall ═════════════════════════════════════════════════════════
step "Mengatur firewall"
if ! have ufw; then
  warn "ufw tidak terpasang — tidak ada yang perlu diatur"
elif ufw status 2>/dev/null | grep -q "Status: active"; then
  info "ufw AKTIF — hanya menambah aturan (aman, port 22 tetap terbuka)"
  ufw allow 22/tcp            >/dev/null
  ufw allow "$RDP_PORT"/tcp   >/dev/null
  ufw reload                  >/dev/null 2>&1 || true
  ok "Diizinkan: 22/tcp dan $RDP_PORT/tcp"
  ufw status | sed 's/^/    /'
elif [ "$ENABLE_UFW_IF_INACTIVE" = "yes" ]; then
  warn "Mengaktifkan ufw — aturan ditambahkan LEBIH DULU, enable terakhir"
  ufw allow 22/tcp            >/dev/null
  ufw allow "$RDP_PORT"/tcp   >/dev/null
  ufw status numbered | grep -q "22/tcp" || die "Aturan port 22 tidak terpasang — ufw TIDAK diaktifkan."
  ufw --force enable          >/dev/null
  ok "ufw aktif dengan 22 + $RDP_PORT terbuka"
  ufw status verbose | sed 's/^/    /'
else
  ok "ufw nonaktif — dibiarkan mati (sesuai panduan)"
  info "Hanya SSH dan xrdp yang mendengarkan, port lain otomatis tertutup."
fi
warn "Cek juga firewall di panel penyedia (Vultr: Network → Firewall Groups · OVH: Network → IP → Edge Firewall)"

# ═══ 07 · fail2ban (opsional) ══════════════════════════════════════════════
step "fail2ban"
if [ "$INSTALL_FAIL2BAN" != "yes" ]; then
  ok "Dilewati (INSTALL_FAIL2BAN=no)"
else
  apt_run "${APT_OPTS[@]}" install fail2ban
  mkdir -p /etc/fail2ban/filter.d
  cat > /etc/fail2ban/filter.d/xrdp.conf <<'EOF'
[Definition]
failregex = ^.*login failed for user .*from <HOST>.*$
            ^.*Login failed for display .*from <HOST>.*$
ignoreregex =
EOF
  cat > /etc/fail2ban/jail.local <<EOF
[sshd]
enabled  = true
port     = 22
maxretry = 5
bantime  = 1h

[xrdp]
enabled  = true
port     = $RDP_PORT
filter   = xrdp
logpath  = /var/log/xrdp-sesman.log
maxretry = 5
bantime  = 1h
EOF
  touch /var/log/xrdp-sesman.log
  systemctl enable --now fail2ban >/dev/null 2>&1
  ok "fail2ban aktif"
fi

# ═══ 08 · Chrome + fix kotak hitam ═════════════════════════════════════════
step "Google Chrome dan perbaikan tampilan"
if [ "$INSTALL_CHROME" = "yes" ]; then
  if have google-chrome; then
    ok "Chrome sudah terpasang"
  else
    info "Mengunduh Chrome (.deb — versi snap Firefox bermasalah di xrdp)"
    TMPDEB=$(mktemp -d)
    if curl -fsSL --max-time 300 -o "$TMPDEB/chrome.deb" \
        https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb; then
      apt_run "${APT_OPTS[@]}" install "$TMPDEB/chrome.deb" && ok "Chrome terpasang"
    else
      warn "Unduhan Chrome gagal — lewati, pasang manual nanti"
    fi
    rm -rf "$TMPDEB"
  fi

  # Kebijakan level sistem: langsung berlaku tanpa harus buka Settings di dalam RDP
  mkdir -p /etc/opt/chrome/policies/managed
  cat > /etc/opt/chrome/policies/managed/vps-setup.json <<'EOF'
{
  "HardwareAccelerationModeEnabled": false,
  "HighEfficiencyModeEnabled": true,
  "BackgroundModeEnabled": false,
  "DefaultBrowserSettingEnabled": false
}
EOF
  ok "Akselerasi GPU Chrome dimatikan + Memory Saver aktif (kebijakan sistem)"
else
  warn "Chrome dilewati (INSTALL_CHROME=no)"
fi

# Matikan compositing XFCE — sumber utama kotak-kotak hitam
info "Mematikan compositing XFCE untuk user $USERNAME"
set_xfconf() {
  as_user dbus-run-session -- xfconf-query -c "$1" -p "$2" -s "$3" --create -t "$4" >/dev/null 2>&1
}
COMPOSIT_OK=no
if set_xfconf xfwm4 /general/use_compositing false bool; then
  VAL=$(as_user dbus-run-session -- xfconf-query -c xfwm4 -p /general/use_compositing 2>/dev/null || echo "")
  [ "$VAL" = "false" ] && COMPOSIT_OK=yes
fi
if [ "$COMPOSIT_OK" != "yes" ]; then
  info "xfconf-query tidak bisa dipakai headless — menulis file konfigurasi langsung"
  XFCONF_DIR="$USER_HOME/.config/xfconf/xfce-perchannel-xml"
  mkdir -p "$XFCONF_DIR"
  cat > "$XFCONF_DIR/xfwm4.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="use_compositing" type="bool" value="false"/>
  </property>
</channel>
EOF
  chown -R "$USERNAME:$USERNAME" "$USER_HOME/.config"
  COMPOSIT_OK=yes
fi
ok "Compositing XFCE dimatikan"

# Jangan biarkan layar blank / DPMS memutus sesi RDP
set_xfconf xfce4-power-manager /xfce4-power-manager/dpms-enabled false bool || true
set_xfconf xfce4-power-manager /xfce4-power-manager/blank-on-ac 0 int      || true
set_xfconf xfce4-session /shutdown/LockScreen false bool                   || true
ok "Screen blanking dan lock screen dimatikan"

if [ "$INSTALL_GEANY" = "yes" ]; then
  wait_apt
  if apt-get "${APT_OPTS[@]}" install geany >/dev/null 2>&1; then
    ok "Geany terpasang (editor Python dengan pewarnaan sintaks)"
  else
    warn "Geany gagal dipasang — Mousepad tetap tersedia"
  fi
fi

# ═══ 09 · Drive redirection ════════════════════════════════════════════════
step "Transfer file dari PC (drive redirection)"
if [ "$INSTALL_DRIVE_REDIRECT" = "yes" ]; then
  wait_apt
  apt-get "${APT_OPTS[@]}" install fuse3 >/dev/null 2>&1 \
    || apt-get "${APT_OPTS[@]}" install fuse >/dev/null 2>&1 || true
  touch /etc/fuse.conf
  grep -q '^user_allow_other' /etc/fuse.conf || echo "user_allow_other" >> /etc/fuse.conf
  if [ -f /etc/xrdp/sesman.ini ]; then
    sed -i -E 's/^EnableFuseMount=.*/EnableFuseMount=true/' /etc/xrdp/sesman.ini
    grep -q '^EnableFuseMount=true' /etc/xrdp/sesman.ini || warn "EnableFuseMount tidak ditemukan di sesman.ini — cek manual"
  fi
  systemctl restart xrdp
  ok "Drive PC akan muncul di $USER_HOME/thinclient_drives/ saat sesi RDP aktif"
  info "Di mstsc: Local Resources → More… → centang Drives"
else
  warn "Dilewati (INSTALL_DRIVE_REDIRECT=no)"
fi

# ═══ 10 · Python ═══════════════════════════════════════════════════════════
step "Python virtual environment"
if [ "$INSTALL_PYTHON" = "yes" ]; then
  VENV_PATH="$USER_HOME/$PROJECT_DIR/venv"
  as_user mkdir -p "$USER_HOME/$PROJECT_DIR"
  if [ -x "$VENV_PATH/bin/python" ]; then
    ok "venv sudah ada di $VENV_PATH"
  else
    [ -d "$VENV_PATH" ] && { warn "Menghapus venv setengah jadi"; rm -rf "$VENV_PATH"; }
    as_user python3 -m venv "$VENV_PATH" || die "Pembuatan venv gagal — pastikan python3-full terpasang."
    ok "venv dibuat"
  fi
  info "Memasang paket Python (1–3 menit)"
  PIP_OPTS=(--quiet --retries 3 --timeout 30)
  as_user "$VENV_PATH/bin/pip" install "${PIP_OPTS[@]}" --upgrade pip wheel \
    || warn "Upgrade pip gagal (jaringan?) — lanjut dengan pip bawaan"
  if [ -z "${PYTHON_PACKAGES// /}" ]; then
    ok "Tidak ada paket yang diminta (PYTHON_PACKAGES kosong)"
  elif as_user "$VENV_PATH/bin/pip" install "${PIP_OPTS[@]}" $PYTHON_PACKAGES; then
    ok "$(as_user "$VENV_PATH/bin/pip" list 2>/dev/null | wc -l) paket terpasang"
  else
    warn "Sebagian paket gagal dipasang. Ulangi manual nanti:"
    warn "  source $VENV_PATH/bin/activate && pip install $PYTHON_PACKAGES"
  fi
  # aktifkan venv otomatis di setiap terminal baru
  BRC="$USER_HOME/.bashrc"
  if ! grep -q 'setup-vps: auto venv' "$BRC" 2>/dev/null; then
    cat >> "$BRC" <<EOF

# setup-vps: auto venv
[ -f "$VENV_PATH/bin/activate" ] && source "$VENV_PATH/bin/activate"
EOF
    chown "$USERNAME:$USERNAME" "$BRC"
    ok "venv aktif otomatis di setiap terminal baru"
  fi
else
  warn "Dilewati (INSTALL_PYTHON=no)"
fi

# ═══ 11 · File .rdp untuk Windows ══════════════════════════════════════════
step "File koneksi Windows"
[ "$PUBIP" = "IP_SERVER" ] && PUBIP=$(get_pubip)
if [ "$MAKE_RDP_FILE" = "yes" ] && [ "$PUBIP" != "IP_SERVER" ]; then
  RDPFILE="$USER_HOME/${PUBIP}.rdp"
  cat > "$RDPFILE" <<EOF
full address:s:$PUBIP:$RDP_PORT
username:s:$USERNAME
screen mode id:i:2
use multimon:i:0
session bpp:i:24
compression:i:1
authentication level:i:0
prompt for credentials:i:0
promptcredentialonce:i:1
negotiate security layer:i:1
redirectclipboard:i:1
drivestoredirect:s:*
redirectprinters:i:0
audiomode:i:2
bitmapcachepersistenable:i:1
disable wallpaper:i:1
allow font smoothing:i:1
disable full window drag:i:1
disable menu anims:i:1
EOF
  chown "$USERNAME:$USERNAME" "$RDPFILE"
  ok "Dibuat: $RDPFILE"
  info "Unduh lewat Termius SFTP → klik dua kali di Windows → simpan password"
else
  warn "Dilewati (MAKE_RDP_FILE=no)"
fi

# ═══ 12 · Verifikasi ═══════════════════════════════════════════════════════
step "Verifikasi akhir"
FAIL=0
chk() { # nama · perintah
  if eval "$2" >/dev/null 2>&1; then printf '  %s✓%s %s\n' "$C_G" "$C_R" "$1"
  else printf '  %s✗%s %s\n' "$C_RD" "$C_R" "$1"; FAIL=$((FAIL+1)); fi
}
chk "User $USERNAME ada dan punya sudo"        "id -nG $USERNAME | grep -qw sudo"
chk "Password $USERNAME terpasang"             "grep -q '^$USERNAME:\\\$' /etc/shadow"
[ "$SWAP_SIZE" != "off" ] && chk "Swap aktif"  "swapon --show | grep -q ."
chk "xrdp berjalan"                            "systemctl is-active --quiet xrdp"
chk "xrdp enabled saat boot"                   "systemctl is-enabled --quiet xrdp"
chk "Port $RDP_PORT LISTEN"                    "ss -tlnp | grep -q ':$RDP_PORT '"
chk "Port 22 LISTEN"                           "ss -tlnp | grep -q ':22 '"
chk ".xsession berisi xfce4-session"           "grep -q xfce4-session $USER_HOME/.xsession"
chk "Compositing XFCE mati"                    "grep -q 'use_compositing\" type=\"bool\" value=\"false\"' $USER_HOME/.config/xfconf/xfce-perchannel-xml/xfwm4.xml 2>/dev/null || [ '$COMPOSIT_OK' = yes ]"
[ "$INSTALL_CHROME" = "yes" ] && chk "Chrome terpasang"          "command -v google-chrome"
[ "$INSTALL_CHROME" = "yes" ] && chk "GPU Chrome dimatikan"      "grep -q 'HardwareAccelerationModeEnabled\": false' /etc/opt/chrome/policies/managed/vps-setup.json"
[ "$INSTALL_PYTHON" = "yes" ] && chk "venv siap"                 "[ -x $USER_HOME/$PROJECT_DIR/venv/bin/python ]"
if have ufw && ufw status | grep -q "Status: active"; then
  chk "ufw: port 22 diizinkan"                 "ufw status | grep -q '^22/tcp .*ALLOW'"
  chk "ufw: port $RDP_PORT diizinkan"          "ufw status | grep -q '^$RDP_PORT/tcp .*ALLOW'"
fi

ELAPSED=$(( ($(date +%s) - START_TS) / 60 ))
printf '\n%s\n' "$(printf '═%.0s' {1..70})"
if [ "$FAIL" -eq 0 ]; then
  printf '%s  SELESAI — semua pemeriksaan lolos (%s menit)%s\n' "$C_G$C_B" "$ELAPSED" "$C_R"
else
  printf '%s  SELESAI dengan %s pemeriksaan gagal (%s menit)%s\n' "$C_Y$C_B" "$FAIL" "$ELAPSED" "$C_R"
fi
printf '%s\n\n' "$(printf '═%.0s' {1..70})"

cat <<EOF
  Sambungkan dari Windows
  ───────────────────────
    Win + R  →  mstsc  →  Computer:  ${C_B}${PUBIP}:${RDP_PORT}${C_R}
    Session: Xorg   ·   Username: ${C_B}${USERNAME}${C_R}   ·   Password: yang Anda set di script

  ${C_Y}Jangan tutup sesi SSH sampai koneksi RDP terbukti berhasil.${C_R}

  Catatan
  ───────
    · Kalau ada firewall di panel penyedia, buka TCP 22 dan $RDP_PORT di sana juga.
    · Di terminal VPS paste memakai Ctrl+Shift+V, bukan Ctrl+V.
    · Log lengkap: $LOG
EOF
[ "$INSTALL_PYTHON" = "yes" ] && printf '    · venv aktif otomatis. Jalankan script: python namafile.py\n'
[ "$MAKE_RDP_FILE" = "yes" ]  && printf '    · File .rdp siap pakai: %s\n' "$USER_HOME/${PUBIP}.rdp"
printf '\n'

rm -f /usr/local/sbin/setup-vps.sh "$SAVED_CONF"

if [ "$REBOOT_MODE" = "end" ]; then
  warn "Reboot dalam 15 detik... (Ctrl+C untuk membatalkan)"
  warn "Setelah nyala, xrdp jalan sendiri — langsung sambungkan mstsc."
  sleep 15
  systemctl reboot
elif [ -f /var/run/reboot-required ] || [ -f /run/reboot-required ]; then
  warn "Sistem masih menandai perlu reboot. Aman dilakukan kapan saja: sudo reboot"
  warn "xrdp sudah enabled, jadi setelah reboot langsung bisa disambungkan lagi."
fi

exit 0