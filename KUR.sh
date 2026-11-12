#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $EUID -eq 0 ]]; then echo "Bu dosyayı sudo ile değil, normal kullanıcıyla çalıştır: ./KUR.sh"; exit 1; fi
USER_NAME="$(id -un)"
USER_GROUP="$(id -gn)"
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
LOG_DIR="$HOME/HomeLab_Logs"
mkdir -p "$LOG_DIR"
chmod 0700 "$LOG_DIR"
LOG_FILE="$LOG_DIR/kurulum-$(date +%Y%m%d-%H%M%S).log"
exec 3>&1
exec > >(tee -a "$LOG_FILE") 2>&1
on_error() {
  local rc="$?" line="$1" cmd="$2"
  trap - ERR
  echo
  echo "HATA: Kurulum $line. satırda durdu (çıkış kodu: $rc)." >&2
  echo "Çalıştırılan komut: $cmd" >&2
  echo "Ayrıntılı günlük: $LOG_FILE" >&2
  echo "Bu dosyayı paylaşırken parola/token içermediğini kontrol et." >&2
  exit "$rc"
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR
on_signal() {
  local signal="$1" rc="$2"
  trap - INT TERM ERR
  echo >&2
  echo "Kurulum kullanıcı tarafından durduruldu ($signal, çıkış kodu: $rc)." >&2
  echo "Yarım kurulum otomatik geri alınmadı; günlük: $LOG_FILE" >&2
  exit "$rc"
}
trap 'on_signal INT 130' INT
trap 'on_signal TERM 143' TERM

source /etc/os-release
[[ "${ID:-}" == linuxmint && "${UBUNTU_CODENAME:-}" == noble ]] || {
  echo "Bu paket Linux Mint 22.x (Ubuntu noble tabanı) içindir."; exit 1;
}
[[ "$(dpkg --print-architecture)" == amd64 ]] || { echo "Yalnızca amd64/x86_64 destekleniyor."; exit 1; }
BASE=/srv/homelab
APP="$BASE/admin-panel"
STACKS="$BASE/compose"

# Uzun komut çıktısını ekrana basmaz; yalnızca günlüğe yazar. Hata olursa son satırları gösterir.
quiet_run() {
  local rc=0 out
  out="$(mktemp)"
  "$@" >"$out" 2>&1 || rc=$?
  cat "$out" >> "$LOG_FILE"
  if (( rc != 0 )); then
    echo "  ! Komut başarısız (kod $rc): $*" >&2
    tail -n 15 "$out" >&2
  fi
  rm -f "$out"
  return "$rc"
}
APT_Q=(sudo env DEBIAN_FRONTEND=noninteractive apt-get -y -qq)

# Parolayı iki kez sorar; kısa veya uyuşmuyorsa nedenini söyleyip baştan sorar.
ask_new_password() {
  local label="$1" min="$2" var="$3" p1 p2
  while true; do
    read -r -s -p "$label (en az $min karakter): " p1; echo
    if (( ${#p1} < min )); then echo "  ! En az $min karakter olmalı, tekrar dene."; continue; fi
    read -r -s -p "$label (tekrar): " p2; echo
    if [[ "$p1" != "$p2" ]]; then echo "  ! İki parola aynı değil, baştan gir."; continue; fi
    printf -v "$var" '%s' "$p1"
    return 0
  done
}
ask_username() {
  local u
  while true; do
    read -r -p "Kullanıcı adı (panel, RustDesk, ntfy, Syncthing için) [$USER_NAME]: " u
    u="${u:-$USER_NAME}"
    if [[ "$u" =~ ^[A-Za-z0-9._@-]{1,64}$ ]]; then ACCOUNT_USER="$u"; return 0; fi
    echo "  ! Kullanıcı adı yalnızca harf, rakam, . _ @ - içerebilir (örnek: admin). Parola bir sonraki adımda sorulur, buraya yazma."
  done
}

ADGUARD_INSTALL=no
ADGUARD_IP=""
TS_INSTALL_OK=no
INSTALL_WARNINGS=()
OLLAMA_MODEL=qwen2.5:1.5b-instruct-q4_K_M

echo "======================================================"
echo " HOMELAB - TEK PAKET KURULUM"
echo "======================================================"
echo "Linux kullanıcısı : $USER_NAME"
echo "Kurulum dizini    : $BASE"
echo
echo "Bu kurulum Docker, SSH, Samba, Syncthing ve yönetim panelini hazırlar."
echo "Tailscale ve RustDesk de otomatik kurulur."
echo "Kurulum günlüğü: $LOG_FILE"
echo "Mevcut /srv/homelab Compose dosyaları varsa üzerine yazılmayacaktır."
echo "Cloudflare, DNS, router, UFW ve Tailscale yapılandırması izinsiz değiştirilmez."
echo
# Fail early if the ZIP was extracted incompletely or expected tools are missing.
REQUIRED_FILES=(
  "$SCRIPT_DIR/admin-panel/app.py"
  "$SCRIPT_DIR/admin-panel/requirements.txt"
  "$SCRIPT_DIR/homelab-docker-control"
  "$SCRIPT_DIR/homelab-docker-lan-only"
  "$SCRIPT_DIR/setup-restic-backup.sh"
  "$SCRIPT_DIR/configure-beszel-agent.sh"
  "$SCRIPT_DIR/reset-panel-password.sh"
  "$SCRIPT_DIR/harden-ssh.sh"
  "$SCRIPT_DIR/homelab-notify"
  "$SCRIPT_DIR/homelab-health-check"
  "$SCRIPT_DIR/TANI.sh"
)
for REQUIRED in "${REQUIRED_FILES[@]}"; do
  [[ -s "$REQUIRED" ]] || { echo "PAKET HATASI: Gerekli dosya eksik/boş: $REQUIRED"; exit 1; }
done
for TOOL in sudo curl apt-get python3 ss lsblk; do
  command -v "$TOOL" >/dev/null 2>&1 || { echo "SİSTEM HATASI: Gerekli komut bulunamadı: $TOOL"; exit 1; }
done
ROOT_FREE_KB="$(df -Pk / | awk 'NR==2 {print $4}')"
if [[ -n "$ROOT_FREE_KB" && "$ROOT_FREE_KB" -lt 10485760 ]]; then
  echo "UYARI: Kök diskte 10 GiB'tan az boş alan var. Ollama modelleri için ek alan gerekebilir."
fi
for PORT in 5001 8090 3001 8080 5678 8081 8088 2586; do
  if ss -Hlnpt "sport = :$PORT" 2>/dev/null | grep -q .; then
    echo "UYARI: TCP $PORT portu zaten dinleniyor; ilgili konteyner başlatılırken çakışma olabilir."
  fi
done
echo "Ön kontrol tamamlandı."
echo
sudo -v
# Uzun kurulum sırasında sudo parolası tekrar istenmesin.
( while true; do sudo -n true; sleep 50; done ) >/dev/null 2>&1 &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT

echo "Kurulum için bir kullanıcı adı ve bir parola gerekiyor. Bu parola panel, Samba, RustDesk, ntfy ve Syncthing için aynı olacak."
echo "(Samba, kullanıcı adı olarak Linux hesabını '$USER_NAME' kullanır; bunu değiştirmiyoruz.)"
ACCOUNT_USER=""; ACCOUNT_PW=""
ask_username
ask_new_password "Parola" 14 ACCOUNT_PW
echo "Bilgiler alındı. Kurulum 5 saniye içinde başlıyor (iptal: Ctrl+C)..."
sleep 5
sudo install -d -m 0700 -o root -g root /var/lib/homelab-installer/markers

echo "Sistem anlık görüntüsü (Timeshift)"
if command -v timeshift >/dev/null 2>&1; then
  if quiet_run sudo timeshift --create --scripted --comments "HomeLab kurulumu oncesi" --tags O; then
    echo "Timeshift anlık görüntüsü alındı."
  else
    echo "UYARI: Timeshift anlık görüntüsü alınamadı (ayarlanmamış olabilir); kurulum devam ediyor."
    INSTALL_WARNINGS+=("Timeshift anlık görüntüsü alınamadı; Timeshift'i açıp yedek diskini seç")
  fi
else
  echo "Timeshift kurulu değil; anlık görüntü atlandı."
fi
PACKAGE_CANDIDATES=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin restic smartmontools nvme-cli sqlite3 lm-sensors fail2ban samba syncthing openssh-server ufw rustdesk tailscale pciutils avahi-daemon libnss-mdns unattended-upgrades)
PREEXISTING_TMP="$(mktemp)"
for PKG in "${PACKAGE_CANDIDATES[@]}"; do
  if dpkg-query -W -f='${db:Status-Status}' "$PKG" 2>/dev/null | grep -qx installed; then
    echo "$PKG" >> "$PREEXISTING_TMP"
  fi
done
sudo install -o root -g root -m 0600 "$PREEXISTING_TMP" /var/lib/homelab-installer/markers/preexisting-packages
rm -f "$PREEXISTING_TMP"

echo "[1/13] Sistem paketleri"
echo "  paket listesi güncelleniyor ve paketler kuruluyor (birkaç dakika sürebilir)..."
quiet_run "${APT_Q[@]}" update
quiet_run "${APT_Q[@]}" install ca-certificates curl wget gnupg lsb-release \
  python3 python3-venv python3-pip samba syncthing openssh-server ufw \
  restic smartmontools nvme-cli sqlite3 lm-sensors fail2ban \
  pciutils avahi-daemon libnss-mdns

echo "[1/13] Donanım algılandı"
echo "İşlemci:"
lscpu | grep -E '^(Model name|CPU\(s\)):' | head -n 2 || true
echo "Bellek:"
free -h | awk 'NR == 2 {print "RAM toplam: " $2}'
echo "Ekran kartları:"
if command -v lspci >/dev/null 2>&1; then
  lspci -nn | grep -Ei 'VGA compatible controller|3D controller|Display controller' || true
fi

echo "Not: Ekran kartı sürücüsü kurulmaz; Ollama CPU ile çalışır."

echo "[2/13] Docker Engine ve Compose"
sudo install -m 0755 -d /etc/apt/keyrings
if [[ ! -s /etc/apt/keyrings/docker.asc ]]; then
  sudo touch /var/lib/homelab-installer/markers/docker-key-created
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
fi
sudo chmod a+r /etc/apt/keyrings/docker.asc
if [[ ! -f /etc/apt/sources.list.d/docker.sources ]]; then
  sudo touch /var/lib/homelab-installer/markers/docker-source-created
  sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: noble
Components: stable
Architectures: amd64
Signed-By: /etc/apt/keyrings/docker.asc
EOF
fi
echo "  Docker kuruluyor..."
quiet_run "${APT_Q[@]}" update
quiet_run "${APT_Q[@]}" install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
quiet_run sudo systemctl enable --now docker
if ! sudo test -e /var/lib/homelab-installer/markers/docker-group-added \
  && ! sudo test -e /var/lib/homelab-installer/markers/docker-group-preexisting; then
  if id -nG "$USER_NAME" | tr ' ' '\n' | grep -Fxq docker; then
    sudo touch /var/lib/homelab-installer/markers/docker-group-preexisting
  else
    sudo touch /var/lib/homelab-installer/markers/docker-group-added
  fi
fi
sudo usermod -aG docker "$USER_NAME"
# Default log rotation; preserve a pre-existing Docker daemon configuration.
if [[ ! -e /etc/docker/daemon.json ]]; then
  sudo touch /var/lib/homelab-installer/markers/docker-daemon-json-created
  sudo install -d -m 0755 /etc/docker
  sudo tee /etc/docker/daemon.json >/dev/null <<'EOF_DOCKER'
{
  "log-driver": "local",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF_DOCKER
  quiet_run sudo systemctl restart docker
else
  echo "Mevcut /etc/docker/daemon.json korundu; log rotasyonu elle gözden geçirilmeli."
fi

echo "[3/13] Tailscale"
if [[ ! -e /etc/apt/sources.list.d/tailscale.list ]]; then sudo touch /var/lib/homelab-installer/markers/tailscale-source-created; fi
if quiet_run bash -c 'set -o pipefail; curl -fsSL https://tailscale.com/install.sh | sh'; then
  quiet_run sudo systemctl enable --now tailscaled
  TS_INSTALL_OK=yes
  echo "Tailscale kuruldu. Oturum açma bağlantısı kurulumun sonunda gösterilecek."
else
  echo "Tailscale kurulumu başarısız oldu; ana kurulum devam ediyor."
  INSTALL_WARNINGS+=("Tailscale kurulamadı")
fi

echo "[4/13] RustDesk uzaktan masaüstü"
RUSTDESK_OK=no
RUSTDESK_ID=""
if dpkg-query -W -f='${db:Status-Status}' rustdesk 2>/dev/null | grep -qx installed; then
  echo "RustDesk zaten kurulu; indirme atlandı."
  RUSTDESK_OK=yes
else
  RD_DIR="$(mktemp -d)"
  chmod 0755 "$RD_DIR"
  echo "  RustDesk son sürümü GitHub'dan indiriliyor..."
  RD_URL=""; RD_SHA=""
  if RD_INFO="$(curl -fsSL --max-time 30 https://api.github.com/repos/rustdesk/rustdesk/releases/latest 2>/dev/null | python3 -c '
import json, re, sys
d = json.load(sys.stdin)
for a in d.get("assets", []):
    if re.fullmatch(r"rustdesk-[0-9][0-9A-Za-z.\-]*-x86_64\.deb", a.get("name", "")):
        print(a["browser_download_url"], (a.get("digest") or "").replace("sha256:", ""))
        break
' 2>/dev/null)" && [[ -n "$RD_INFO" ]]; then
    read -r RD_URL RD_SHA <<<"$RD_INFO"
  fi
  if [[ -n "$RD_URL" ]] && curl -fsSL --max-time 600 -o "$RD_DIR/rustdesk.deb" "$RD_URL" \
    && { [[ -z "$RD_SHA" ]] || echo "$RD_SHA  $RD_DIR/rustdesk.deb" | sha256sum -c --quiet -; } \
    && chmod 0644 "$RD_DIR/rustdesk.deb" \
    && quiet_run "${APT_Q[@]}" install "$RD_DIR/rustdesk.deb"; then
    RUSTDESK_OK=yes
  else
    echo "RustDesk kurulumu başarısız oldu (indirme, doğrulama veya paket hatası); ana kurulum devam ediyor."
    INSTALL_WARNINGS+=("RustDesk kurulamadı; https://rustdesk.com adresinden elle kurabilirsin")
  fi
  rm -rf "$RD_DIR"
fi
if [[ "$RUSTDESK_OK" == yes ]]; then
  quiet_run sudo systemctl enable --now rustdesk || INSTALL_WARNINGS+=("RustDesk servisi etkinleştirilemedi: RustDesk > Ayarlar > Güvenlik'ten 'Servisi etkinleştir' seç")
  if sudo timeout 30 rustdesk --password "$ACCOUNT_PW" >/dev/null 2>&1; then
    quiet_run sudo systemctl restart rustdesk || true
    echo "RustDesk kuruldu ve parolan ayarlandı."
  else
    echo "UYARI: RustDesk parolası komutla ayarlanamadı."
    INSTALL_WARNINGS+=("RustDesk parolası ayarlanamadı; RustDesk > Ayarlar > Güvenlik > Kalıcı parola'dan kendin belirle")
  fi
  RUSTDESK_ID="$(sudo timeout 20 rustdesk --get-id 2>/dev/null | tail -n 1 || true)"
  [[ "$RUSTDESK_ID" =~ ^[0-9]+$ ]] || RUSTDESK_ID=""
fi

echo "[5/13] AdGuard Home (yerel DNS)"
ADGUARD_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
if [[ "$ADGUARD_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && ip -4 -o addr show | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$ADGUARD_IP"; then
  ADGUARD_INSTALL=yes
  echo "AdGuard yalnızca $ADGUARD_IP üzerinde DNS/kurulum portları açacak. Router DNS ayarı değiştirilmeyecek."
else
  echo "Sunucunun yerel ağ IPv4 adresi bulunamadı; AdGuard bu kurulumda atlanacak."
  ADGUARD_IP=""
  INSTALL_WARNINGS+=("AdGuard için LAN IP bulunamadı, kurulmadı")
fi

echo "[6/13] Syncthing, temel servisler ve güç düğmesi"
if ! sudo test -e /var/lib/homelab-installer/markers/linger-added \
  && ! sudo test -e /var/lib/homelab-installer/markers/linger-preexisting; then
  if [[ "$(sudo loginctl show-user "$USER_NAME" -p Linger --value 2>/dev/null || true)" == yes ]]; then
    sudo touch /var/lib/homelab-installer/markers/linger-preexisting
  else
    sudo touch /var/lib/homelab-installer/markers/linger-added
  fi
fi
sudo loginctl enable-linger "$USER_NAME" || true
quiet_run sudo systemctl enable --now "syncthing@${USER_NAME}.service"
for _ in $(seq 1 30); do
  syncthing cli show system >/dev/null 2>&1 && break
  sleep 2
done
if syncthing cli config gui user set "$ACCOUNT_USER" >/dev/null 2>&1 \
  && syncthing cli config gui password set "$ACCOUNT_PW" >/dev/null 2>&1; then
  quiet_run sudo systemctl restart "syncthing@${USER_NAME}.service" || true
  echo "Syncthing arayüz girişi ayarlandı."
else
  echo "UYARI: Syncthing arayüz kullanıcı/parolası ayarlanamadı."
  INSTALL_WARNINGS+=("Syncthing: http://127.0.0.1:8384 > Ayarlar > GUI'den kullanıcı/parola belirle")
fi
quiet_run sudo systemctl enable --now ssh
quiet_run sudo systemctl enable --now smbd
if ! quiet_run sudo systemctl enable --now avahi-daemon; then
  echo "UYARI: mDNS servisi başlatılamadı; yerel ağda .local adı kullanılamayabilir."
  INSTALL_WARNINGS+=("Avahi/mDNS başlatılamadı; sunucuya LAN IP adresiyle eriş")
fi

# Güç düğmesine basıldığında Cinnamon onay penceresi yerine doğrudan kapatır.
# Önceki kullanıcı ayarı yedeklenir; KALDIR.sh çalıştırılırsa geri yüklenebilir.
if command -v gsettings >/dev/null 2>&1 && gsettings writable org.cinnamon.settings-daemon.plugins.power button-power >/dev/null 2>&1; then
  sudo install -d -m 0700 /var/lib/homelab-installer
  if ! sudo test -f /var/lib/homelab-installer/cinnamon-button-power.before; then
    PREVIOUS_POWER_ACTION="$(gsettings get org.cinnamon.settings-daemon.plugins.power button-power 2>/dev/null || true)"
    if [[ -n "$PREVIOUS_POWER_ACTION" ]]; then
      printf '%s\n' "$PREVIOUS_POWER_ACTION" | sudo tee /var/lib/homelab-installer/cinnamon-button-power.before >/dev/null
      sudo chmod 0600 /var/lib/homelab-installer/cinnamon-button-power.before
    fi
  fi
  if gsettings set org.cinnamon.settings-daemon.plugins.power button-power 'shutdown'; then
    echo "Cinnamon güç düğmesi: doğrudan kapat."
  else
    echo "UYARI: Cinnamon güç düğmesi ayarı yazılamadı; Ayarlar > Güç Yönetimi bölümünden 'Hemen kapat' seç."
  fi
else
  echo "UYARI: Cinnamon gsettings oturumu bulunamadı; güç düğmesi ayarını masaüstü oturumunda tamamla."
fi
sudo install -d -m 0755 /etc/systemd/logind.conf.d
if [[ ! -f /etc/systemd/logind.conf.d/90-homelab-installer-power-button.conf ]]; then
  sudo touch /var/lib/homelab-installer/markers/logind-power-created
  sudo tee /etc/systemd/logind.conf.d/90-homelab-installer-power-button.conf >/dev/null <<'EOF_POWER'
[Login]
HandlePowerKey=poweroff
EOF_POWER
fi
echo "systemd güç düğmesi ayarı yazıldı; tam etkisi için yeniden başlatma gerekir."

echo "Uyku modu kapatılıyor (sunucu uyumasın)"
for SLEEP_TARGET in sleep suspend hibernate hybrid-sleep; do
  if [[ "$(systemctl is-enabled "$SLEEP_TARGET.target" 2>/dev/null || true)" != masked ]]; then
    sudo touch "/var/lib/homelab-installer/markers/sleep-masked-$SLEEP_TARGET"
  fi
done
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target >/dev/null 2>&1 \
  || INSTALL_WARNINGS+=("Uyku hedefleri kilitlenemedi (systemctl mask)")
sudo install -d -m 0755 /etc/systemd/logind.conf.d
if [[ ! -f /etc/systemd/logind.conf.d/91-homelab-installer-no-sleep.conf ]]; then
  sudo touch /var/lib/homelab-installer/markers/logind-nosleep-created
fi
sudo tee /etc/systemd/logind.conf.d/91-homelab-installer-no-sleep.conf >/dev/null <<'EOF_NOSLEEP'
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
IdleAction=ignore
EOF_NOSLEEP
sudo systemctl kill -s HUP systemd-logind >/dev/null 2>&1 || true
if command -v gsettings >/dev/null 2>&1 && gsettings writable org.cinnamon.settings-daemon.plugins.power button-power >/dev/null 2>&1; then
  SLEEP_BACKUP=/var/lib/homelab-installer/gsettings-sleep.before
  SLEEP_SETTINGS=(
    "org.cinnamon.settings-daemon.plugins.power|sleep-inactive-ac-type|'nothing'"
    "org.cinnamon.settings-daemon.plugins.power|sleep-inactive-battery-type|'nothing'"
    "org.cinnamon.settings-daemon.plugins.power|sleep-inactive-ac-timeout|0"
    "org.cinnamon.settings-daemon.plugins.power|sleep-inactive-battery-timeout|0"
    "org.cinnamon.settings-daemon.plugins.power|sleep-display-ac|0"
    "org.cinnamon.settings-daemon.plugins.power|sleep-display-battery|0"
    "org.cinnamon.settings-daemon.plugins.power|lid-close-ac-action|'nothing'"
    "org.cinnamon.settings-daemon.plugins.power|lid-close-battery-action|'nothing'"
    "org.cinnamon.desktop.session|idle-delay|uint32 0"
    "org.cinnamon.desktop.screensaver|lock-enabled|false"
  )
  SLEEP_FIRST=no
  sudo test -f "$SLEEP_BACKUP" || SLEEP_FIRST=yes
  SLEEP_TMP="$(mktemp)"
  SLEEP_FAIL=0
  for ENTRY in "${SLEEP_SETTINGS[@]}"; do
    IFS='|' read -r SCHEMA KEY VALUE <<<"$ENTRY"
    if gsettings writable "$SCHEMA" "$KEY" >/dev/null 2>&1; then
      [[ "$SLEEP_FIRST" == yes ]] && printf '%s|%s|%s\n' "$SCHEMA" "$KEY" "$(gsettings get "$SCHEMA" "$KEY")" >> "$SLEEP_TMP"
      gsettings set "$SCHEMA" "$KEY" "$VALUE" 2>/dev/null || SLEEP_FAIL=1
    fi
  done
  if [[ "$SLEEP_FIRST" == yes && -s "$SLEEP_TMP" ]]; then sudo install -o root -g root -m 0600 "$SLEEP_TMP" "$SLEEP_BACKUP"; fi
  rm -f "$SLEEP_TMP"
  if (( SLEEP_FAIL )); then
    INSTALL_WARNINGS+=("Bazı Cinnamon uyku ayarları yazılamadı; Ayarlar > Güç Yönetimi'nden kontrol et")
  fi
  echo "Uyku, ekran kapanması, kapak kapanışı ve ekran kilidi kapatıldı."
else
  echo "UYARI: Cinnamon gsettings oturumu yok; Cinnamon uyku ayarları atlandı (systemd uykusu yine de kilitlendi)."
fi

echo "Otomatik oturum açma"
if [[ -d /etc/lightdm ]]; then
  if grep -qsE '^[[:space:]]*autologin-user=' /etc/lightdm/lightdm.conf; then
    echo "Otomatik giriş zaten /etc/lightdm/lightdm.conf içinde ayarlı; dokunulmadı."
  else
    sudo install -d -m 0755 /etc/lightdm/lightdm.conf.d
    if [[ ! -f /etc/lightdm/lightdm.conf.d/70-homelab-installer-autologin.conf ]]; then
      sudo touch /var/lib/homelab-installer/markers/autologin-created
    fi
    sudo tee /etc/lightdm/lightdm.conf.d/70-homelab-installer-autologin.conf >/dev/null <<EOF_AUTOLOGIN
[Seat:*]
autologin-user=${USER_NAME}
autologin-user-timeout=0
EOF_AUTOLOGIN
    echo "Otomatik giriş açıldı (sonraki açılıştan itibaren)."
  fi
else
  echo "LightDM bulunamadı; otomatik giriş ayarlanmadı."
fi

echo "Otomatik güvenlik güncellemeleri"
if quiet_run "${APT_Q[@]}" install unattended-upgrades; then
  if [[ ! -e /etc/apt/apt.conf.d/52homelab-unattended-upgrades ]]; then
    sudo touch /var/lib/homelab-installer/markers/unattended-created
    # Mint'te ${distro_id} "LinuxMint" olduğundan varsayılan kaynak eşleşmez; Ubuntu güvenlik deposu açıkça yazılır.
    UU_UBUNTU_CODENAME="$(. /etc/os-release; echo "${UBUNTU_CODENAME:-noble}")"
    UU_MINT_CODENAME="$(. /etc/os-release; echo "${VERSION_CODENAME:-zena}")"
    # Mint'in varsayılan 50unattended-upgrades dosyası TÜM Mint güncellemelerini (yalnız güvenlik değil) açar; burada temizlenir.
    sudo tee /etc/apt/apt.conf.d/52homelab-unattended-upgrades >/dev/null <<EOF_UU
#clear Unattended-Upgrade::Allowed-Origins;
#clear Unattended-Upgrade::Origins-Pattern;
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
Unattended-Upgrade::Origins-Pattern { "origin=Ubuntu,codename=${UU_UBUNTU_CODENAME}-security"; "origin=Linuxmint,archive=${UU_MINT_CODENAME}-security"; };
Unattended-Upgrade::Package-Blacklist { "docker-ce"; "docker-ce-cli"; "containerd.io"; "docker-compose-plugin"; "docker-buildx-plugin"; };
Unattended-Upgrade::Automatic-Reboot "false";
EOF_UU
  fi
else
  echo "UYARI: unattended-upgrades kurulamadı; otomatik güvenlik güncellemesi etkin değil."
  INSTALL_WARNINGS+=("unattended-upgrades kurulamadı")
fi

echo "[7/13] HomeLab klasörleri ve Compose dosyaları"
sudo mkdir -p "$BASE"/{data/shared,data/documents,data/projects,data/media,backups,tools,web/public,config/caddy,appdata/{ntfy/{cache,lib},dockge,beszel,beszel-agent,uptime-kuma,filebrowser,n8n,ollama,scrutiny/{config,influxdb},caddy/{data,config},adguardhome/{work,conf}},compose/{dockge,monitoring,cloud,ai,storage,web,adguard,monitoring-agent,notify}}
# Compose dosyalarının sahipliği: kurulumdan önce var olan (bize ait olmayan) dosyalar KALDIR.sh tarafından silinmez.
for STACK_NAME in dockge monitoring cloud ai storage web notify adguard monitoring-agent; do
  if [[ ! -e "$STACKS/$STACK_NAME/compose.yaml" ]]; then
    sudo touch "/var/lib/homelab-installer/markers/compose-owned-$STACK_NAME"
  elif ! sudo test -e "/var/lib/homelab-installer/markers/compose-owned-$STACK_NAME"; then
    sudo touch "/var/lib/homelab-installer/markers/compose-foreign-$STACK_NAME"
  fi
done
sudo chown "$USER_NAME:$USER_GROUP" "$BASE/data" "$BASE/data/shared" "$BASE/data/documents" "$BASE/data/projects" "$BASE/data/media"
sudo chown root:"$USER_GROUP" "$BASE"
sudo chmod 750 "$BASE"
# Common Docker images use UID/GID 1000 for writable application data.
# Only empty directories are adjusted; existing user data is never recursively chowned.
for APPDATA_DIR in dockge beszel uptime-kuma filebrowser n8n caddy/data caddy/config; do
  TARGET="$BASE/appdata/$APPDATA_DIR"
  if [[ -d "$TARGET" ]] && ! find "$TARGET" -mindepth 1 -print -quit | grep -q .; then
    sudo chown 1000:1000 "$TARGET"
  fi
done
# Yalnızca olmayan dosyaları oluştur; mevcut yapılandırmalar korunur.
if [[ ! -f "$STACKS/dockge/compose.yaml" ]]; then
sudo tee "$STACKS/dockge/compose.yaml" >/dev/null <<EOF
services:
  dockge:
    image: louislam/dockge:1
    container_name: dockge
    restart: unless-stopped
    ports: ["0.0.0.0:5001:5001"]
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - $STACKS:$STACKS
      - $BASE/appdata/dockge:/app/data
    environment:
      DOCKGE_STACKS_DIR: $STACKS
EOF
fi
if [[ ! -f "$STACKS/monitoring/compose.yaml" ]]; then
sudo tee "$STACKS/monitoring/compose.yaml" >/dev/null <<EOF
services:
  beszel:
    image: henrygd/beszel:latest
    container_name: beszel
    restart: unless-stopped
    ports: ["0.0.0.0:8090:8090"]
    volumes: [$BASE/appdata/beszel:/beszel_data]
  uptime-kuma:
    image: louislam/uptime-kuma:2
    container_name: uptime-kuma
    restart: unless-stopped
    ports: ["0.0.0.0:3001:3001"]
    volumes: [$BASE/appdata/uptime-kuma:/app/data]
EOF
fi
if [[ ! -f "$STACKS/cloud/compose.yaml" ]]; then
sudo tee "$STACKS/cloud/compose.yaml" >/dev/null <<EOF
services:
  filebrowser:
    image: ghcr.io/gtsteffaniak/filebrowser:stable-slim
    container_name: filebrowser
    restart: unless-stopped
    ports: ["0.0.0.0:8080:80"]
    volumes:
      - $BASE/data:/folder
      - $BASE/appdata/filebrowser:/home/filebrowser/data
EOF
fi
if [[ ! -f "$STACKS/ai/compose.yaml" ]]; then
sudo tee "$STACKS/ai/compose.yaml" >/dev/null <<EOF
# HOMELAB_MANAGED_AI_STACK
services:
  ollama:
    image: ollama/ollama:latest
    container_name: ollama
    restart: unless-stopped
    ports: ["127.0.0.1:11434:11434"]
    volumes: [$BASE/appdata/ollama:/root/.ollama]
  n8n:
    image: n8nio/n8n:latest
    container_name: n8n
    restart: unless-stopped
    ports: ["0.0.0.0:5678:5678"]
    environment:
      TZ: Europe/Istanbul
      GENERIC_TIMEZONE: Europe/Istanbul
      # LAN'da http:// ile açıldığı için gerekli; HTTPS/Cloudflare Tunnel kurulunca true yap veya satırı sil.
      N8N_SECURE_COOKIE: "false"
    volumes: [$BASE/appdata/n8n:/home/node/.n8n]
    depends_on: [ollama]
EOF
fi
# Samba paylaşımı: yalnızca bölüm yoksa ekle.
if ! sudo grep -q '^\[Paylasim\]' /etc/samba/smb.conf; then
sudo touch /var/lib/homelab-installer/markers/samba-share-created
sudo tee -a /etc/samba/smb.conf >/dev/null <<EOF

[Paylasim]
   path = $BASE/data/shared
   browseable = yes
   read only = no
   guest ok = no
   valid users = $USER_NAME
   create mask = 0664
   directory mask = 0775
EOF
fi
quiet_run sudo testparm -s
quiet_run sudo systemctl restart smbd
# SSH brute-force mitigation; no firewall rules or router changes are made.
sudo install -d -m 0755 /etc/fail2ban/jail.d
if [[ ! -f /etc/fail2ban/jail.d/homelab-sshd.local ]]; then
  sudo touch /var/lib/homelab-installer/markers/fail2ban-created
  sudo tee /etc/fail2ban/jail.d/homelab-sshd.local >/dev/null <<'EOF_FAIL2BAN'
[sshd]
enabled = true
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
EOF_FAIL2BAN
fi
quiet_run sudo systemctl enable --now fail2ban
# Keep persistent system journals bounded; preserve an existing custom drop-in.
sudo install -d -m 0755 /etc/systemd/journald.conf.d
if [[ ! -f /etc/systemd/journald.conf.d/homelab.conf ]]; then
  sudo touch /var/lib/homelab-installer/markers/journald-created
  sudo tee /etc/systemd/journald.conf.d/homelab.conf >/dev/null <<'EOF_JOURNAL'
[Journal]
Storage=persistent
SystemMaxUse=500M
SystemMaxFileSize=50M
MaxRetentionSec=1month
EOF_JOURNAL
  sudo install -d -o root -g systemd-journal -m 2755 /var/log/journal
  quiet_run sudo systemctl restart systemd-journald
fi

# New, isolated Compose stacks are created only when their files do not exist.
if [[ ! -f "$STACKS/storage/compose.yaml" ]]; then
  DISK_LINES=""
  NVME_CONTROLLERS=""
  while IFS= read -r DISK_LINE; do
    DEVICE="" DISK_TYPE="" DISK_TRAN="" DISK_RM="0"
    [[ "$DISK_LINE" =~ NAME=\"([^\"]*)\" ]] && DEVICE="${BASH_REMATCH[1]}"
    [[ "$DISK_LINE" =~ TYPE=\"([^\"]*)\" ]] && DISK_TYPE="${BASH_REMATCH[1]}"
    [[ "$DISK_LINE" =~ TRAN=\"([^\"]*)\" ]] && DISK_TRAN="${BASH_REMATCH[1]}"
    [[ "$DISK_LINE" =~ RM=\"([^\"]*)\" ]] && DISK_RM="${BASH_REMATCH[1]}"
    [[ "$DISK_TYPE" == disk && "$DEVICE" =~ ^/dev/[A-Za-z0-9_]+$ ]] || continue
    # USB/çıkarılabilir diskler çıkarılınca Scrutiny konteyneri başlayamaz; zram gerçek disk değildir.
    if [[ "$DISK_TRAN" == usb || "$DISK_RM" == 1 || "$DEVICE" == /dev/zram* ]]; then
      echo "Scrutiny: $DEVICE (USB/çıkarılabilir/zram) izleme listesine eklenmedi."
      continue
    fi
    if [[ "$DEVICE" =~ ^/dev/nvme[0-9]+n[0-9]+$ ]]; then
      CONTROLLER="${DEVICE%n*}"
      if [[ -e "$CONTROLLER" ]] && ! grep -Fq "$CONTROLLER:$CONTROLLER" <<<"$NVME_CONTROLLERS"; then
        NVME_CONTROLLERS+="      - $CONTROLLER:$CONTROLLER"$'\n'
      fi
    else
      DISK_LINES+="      - $DEVICE:$DEVICE"$'\n'
    fi
  done < <(lsblk -dnPpo NAME,TYPE,TRAN,RM)
  DISK_LINES+="$NVME_CONTROLLERS"
  SCRUTINY_NVME_CAP=""
  if [[ -n "$NVME_CONTROLLERS" ]]; then
    echo "NVMe disk bulundu; Scrutiny'ye geniş SYS_ADMIN yetkisi verilmedi (güvenli varsayılan)."
  fi
  {
    cat <<EOF_SCRUTINY
services:
  scrutiny:
    image: ghcr.io/analogj/scrutiny:v0.10.0-omnibus
    container_name: scrutiny
    restart: unless-stopped
    cap_add:
      - SYS_RAWIO
EOF_SCRUTINY
    if [[ -n "$SCRUTINY_NVME_CAP" ]]; then printf '      - SYS_ADMIN\n'; fi
    cat <<EOF_SCRUTINY2
    ports:
      - "0.0.0.0:8081:8080"
    volumes:
      - /run/udev:/run/udev:ro
      - $BASE/appdata/scrutiny/config:/opt/scrutiny/config
      - $BASE/appdata/scrutiny/influxdb:/opt/scrutiny/influxdb
EOF_SCRUTINY2
    if [[ -n "$DISK_LINES" ]]; then printf '    devices:
%s' "$DISK_LINES"; fi
  } | sudo tee "$STACKS/storage/compose.yaml" >/dev/null
fi

if [[ ! -f "$STACKS/web/compose.yaml" ]]; then
  if [[ ! -f "$BASE/config/caddy/Caddyfile" ]]; then
    sudo tee "$BASE/config/caddy/Caddyfile" >/dev/null <<'EOF_CADDY'
:80 {
    root * /srv
    encode zstd gzip
    file_server
}
EOF_CADDY
    sudo chown "$USER_NAME:$USER_GROUP" "$BASE/config/caddy/Caddyfile"
  fi
  if [[ ! -f "$BASE/web/public/index.html" ]]; then
    sudo tee "$BASE/web/public/index.html" >/dev/null <<'EOF_SITE'
<!doctype html>
<html lang="tr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>HomeLab</title>
<style>body{font-family:system-ui,sans-serif;max-width:760px;margin:12vh auto;padding:0 24px;line-height:1.6;color:#202936}h1{font-size:2.4rem}p{color:#596579}</style></head>
<body><h1>HomeLab</h1><p>Kişisel web sitesi için başlangıç sayfası. Alan adı ve içerik yapılandırması sonraki aşamada yapılacaktır.</p></body></html>
EOF_SITE
    sudo chown "$USER_NAME:$USER_GROUP" "$BASE/web/public/index.html"
  fi
  sudo chown "$USER_NAME:$USER_GROUP" "$BASE/web" "$BASE/web/public" "$BASE/config/caddy"
  sudo tee "$STACKS/web/compose.yaml" >/dev/null <<EOF_CADDY_COMPOSE
services:
  caddy:
    image: caddy:2
    container_name: caddy
    restart: unless-stopped
    ports:
      - "127.0.0.1:8088:80"
    volumes:
      - $BASE/config/caddy:/etc/caddy:ro
      - $BASE/web/public:/srv:ro
      - $BASE/appdata/caddy/data:/data
      - $BASE/appdata/caddy/config:/config
EOF_CADDY_COMPOSE
fi

if [[ ! -f "$STACKS/adguard/compose.yaml" && "$ADGUARD_INSTALL" == yes ]]; then
  sudo tee "$STACKS/adguard/.env" >/dev/null <<EOF_ADGUARD_ENV
ADGUARD_BIND_IP=$ADGUARD_IP
EOF_ADGUARD_ENV
  sudo chmod 600 "$STACKS/adguard/.env"
  sudo tee "$STACKS/adguard/compose.yaml" >/dev/null <<'EOF_ADGUARD_COMPOSE'
services:
  adguardhome:
    image: adguard/adguardhome:v0.107.80
    container_name: adguardhome
    restart: unless-stopped
    ports:
      - "${ADGUARD_BIND_IP}:53:53/tcp"
      - "${ADGUARD_BIND_IP}:53:53/udp"
      - "${ADGUARD_BIND_IP}:3000:3000/tcp"
      - "${ADGUARD_BIND_IP}:3002:80/tcp"
    volumes:
      - /srv/homelab/appdata/adguardhome/work:/opt/adguardhome/work
      - /srv/homelab/appdata/adguardhome/conf:/opt/adguardhome/conf
EOF_ADGUARD_COMPOSE
fi

# Beszel Agent is kept in a separate Compose file until its Hub-generated key/token exist.
if [[ ! -f "$STACKS/monitoring-agent/compose.yaml" ]]; then
  sudo tee "$STACKS/monitoring-agent/compose.yaml" >/dev/null <<EOF_AGENT
services:
  beszel-agent:
    image: henrygd/beszel-agent:latest
    container_name: beszel-agent
    restart: unless-stopped
    network_mode: host
    volumes:
      - $BASE/appdata/beszel-agent:/var/lib/beszel-agent
      - /var/run/docker.sock:/var/run/docker.sock:ro
    environment:
      LISTEN: 45876
      KEY: \${BESZEL_AGENT_KEY}
      TOKEN: \${BESZEL_AGENT_TOKEN}
EOF_AGENT
fi


if [[ ! -f "$STACKS/notify/compose.yaml" ]]; then
  HOST_SHORT="$(hostname -s)"
  sudo tee "$STACKS/notify/compose.yaml" >/dev/null <<EOF_NTFY_COMPOSE
services:
  ntfy:
    image: binwiederhier/ntfy:latest
    container_name: ntfy
    command: serve
    restart: unless-stopped
    environment:
      TZ: Europe/Istanbul
      NTFY_BASE_URL: http://${HOST_SHORT}.local:2586
      NTFY_CACHE_FILE: /var/cache/ntfy/cache.db
      NTFY_AUTH_FILE: /var/lib/ntfy/user.db
      NTFY_AUTH_DEFAULT_ACCESS: deny-all
    ports:
      - "0.0.0.0:2586:80"
    volumes:
      - $BASE/appdata/ntfy/cache:/var/cache/ntfy
      - $BASE/appdata/ntfy/lib:/var/lib/ntfy
EOF_NTFY_COMPOSE
fi

echo "Docker portları yerel ağa kilitleniyor (internet kaynaklı yeni bağlantılar engellenir)."
sudo install -o root -g root -m 0750 "$SCRIPT_DIR/homelab-docker-lan-only" /usr/local/sbin/homelab-docker-lan-only
sudo touch /var/lib/homelab-installer/markers/lan-lock-created
sudo tee /etc/systemd/system/homelab-docker-lan-only.service >/dev/null <<'EOF_LAN_UNIT'
[Unit]
Description=Restrict Docker published ports to LAN/Tailscale sources (HomeLab)
After=docker.service network-online.target
Requires=docker.service
PartOf=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/homelab-docker-lan-only apply
ExecStop=/usr/local/sbin/homelab-docker-lan-only remove

[Install]
WantedBy=multi-user.target
EOF_LAN_UNIT
sudo systemctl daemon-reload
LAN_LOCK_OK=no
if quiet_run sudo systemctl enable --now homelab-docker-lan-only.service \
  && sudo iptables -S DOCKER-USER 2>/dev/null | grep -q 'HOMELAB-LAN-ONLY'; then
  LAN_LOCK_OK=yes
else
  echo "UYARI: Docker port kilidi etkinleştirilemedi veya doğrulanamadı; portlar LAN dışına açık kalabilir."
  INSTALL_WARNINGS+=("Docker port kilidi (LAN-only) doğrulanamadı: sudo journalctl -u homelab-docker-lan-only")
fi

echo "[8/13] Docker servisleri doğrulanıyor ve başlatılıyor"
for f in "$STACKS/dockge/compose.yaml" "$STACKS/monitoring/compose.yaml" "$STACKS/cloud/compose.yaml" "$STACKS/ai/compose.yaml" "$STACKS/storage/compose.yaml" "$STACKS/web/compose.yaml" "$STACKS/notify/compose.yaml"; do
  STACK_NAME="$(basename -- "$(dirname -- "$f")")"
  # Bir stack başlamazsa (imaj indirilemedi, port çakıştı vb.) kurulumun geri kalanı yine de tamamlansın.
  if ! sudo docker compose -f "$f" config -q; then
    echo "UYARI: $STACK_NAME Compose dosyası doğrulanamadı; başlatılmadı."
    INSTALL_WARNINGS+=("$STACK_NAME Compose dosyası geçersiz; başlatılmadı")
  elif ! { echo "[Docker] $STACK_NAME indiriliyor/başlatılıyor (ilerleme çubuğu gizli, birkaç dakika sürebilir)..."; sudo docker compose --progress quiet -f "$f" up -d --quiet-pull; }; then
    echo "UYARI: $STACK_NAME stack'i başlatılamadı (imaj indirme veya port sorunu olabilir)."
    INSTALL_WARNINGS+=("$STACK_NAME stack'i başlatılamadı; sudo docker compose -f $f up -d ile tekrar dene")
  fi
done
if [[ -f "$STACKS/adguard/compose.yaml" && "$ADGUARD_INSTALL" == yes && -f "$STACKS/adguard/.env" ]]; then
  if ! sudo docker compose --env-file "$STACKS/adguard/.env" -f "$STACKS/adguard/compose.yaml" config -q; then
    echo "UYARI: AdGuard Compose dosyası doğrulanamadı; başlatılmadı."
    INSTALL_WARNINGS+=("AdGuard Compose dosyası geçersiz; başlatılmadı")
    ADGUARD_INSTALL=no
  fi
fi
if [[ -f "$STACKS/adguard/compose.yaml" && "$ADGUARD_INSTALL" == yes && -f "$STACKS/adguard/.env" ]]; then
  # Do not steal DNS if another process already listens on wildcard or the selected LAN address.
  DNS_LISTENERS="$(sudo ss -Hlnptun 'sport = :53' 2>/dev/null || true)"
  if grep -Eq '(^|[[:space:]])(0\.0\.0\.0|\*|\[::\]):53([[:space:]]|$)' <<<"$DNS_LISTENERS" || grep -Fq "$ADGUARD_IP:53" <<<"$DNS_LISTENERS"; then
    echo "Port 53 zaten kullanımda; AdGuard Compose dosyası hazırlandı ancak konteyner başlatılmadı."
    INSTALL_WARNINGS+=("Port 53 kullanımda olduğu için AdGuard başlatılmadı")
  elif ! { echo "[Docker] adguard indiriliyor/başlatılıyor..."; sudo docker compose --progress quiet --env-file "$STACKS/adguard/.env" -f "$STACKS/adguard/compose.yaml" up -d --quiet-pull; }; then
    echo "UYARI: AdGuard başlatılamadı."
    INSTALL_WARNINGS+=("AdGuard başlatılamadı")
  fi
fi

echo "İlk kurulumun sabit Ollama modeli indiriliyor."
ROOT_FREE_KB="$(df -Pk "$BASE" | awk 'NR == 2 {print $4}')"
if [[ ! "$ROOT_FREE_KB" =~ ^[0-9]+$ ]] || ((ROOT_FREE_KB < 2097152)); then
  echo "Diskte en az 2 GiB boş alan bulunamadı; $OLLAMA_MODEL indirmesi atlandı."
  INSTALL_WARNINGS+=("Yeterli disk alanı olmadığı için Ollama modeli indirilmedi")
else
  echo "İlk kurulum modeli: $OLLAMA_MODEL (Q4_K_M, model dosyası yaklaşık 986 MB; CPU üzerinde çalışır)"
  MODEL_READY=no
  for _ in $(seq 1 60); do
    if curl -fsS http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
      MODEL_READY=yes
      break
    fi
    sleep 2
  done
  if [[ "$MODEL_READY" == yes ]] \
    && { echo "  model indiriliyor: $OLLAMA_MODEL (boyuta göre uzun sürebilir, ilerleme gizli)..."; quiet_run sudo docker compose -f "$STACKS/ai/compose.yaml" exec -T ollama ollama pull "$OLLAMA_MODEL"; }; then
    echo "Ollama modeli indirildi: $OLLAMA_MODEL"
  else
    echo "Ollama modeli şu anda indirilemedi. Docker hizmetini ve günlükleri kontrol edip daha sonra modeli elle çekebilirsin."
    INSTALL_WARNINGS+=("Ollama modeli indirilemedi")
  fi
fi

echo "Bildirim sistemi (ntfy) ve sağlık denetimi hazırlanıyor"
sudo install -o root -g root -m 0750 "$SCRIPT_DIR/homelab-notify" /usr/local/sbin/homelab-notify
sudo install -o root -g root -m 0750 "$SCRIPT_DIR/homelab-health-check" /usr/local/sbin/homelab-health-check
sudo touch /var/lib/homelab-installer/markers/notify-created
sudo tee /etc/systemd/system/homelab-notify-failure@.service >/dev/null <<'EOF_NOTIFY_UNIT'
[Unit]
Description=HomeLab failure notification for %i

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/homelab-notify "Servis basarisiz" "%i basarisiz oldu. Ayrinti: journalctl -u %i" 4 rotating_light
EOF_NOTIFY_UNIT
NTFY_CONF=/etc/homelab-installer/ntfy.env
if sudo docker container inspect ntfy >/dev/null 2>&1 && ! sudo test -f "$NTFY_CONF"; then
  for _ in $(seq 1 30); do
    curl -fsS --max-time 3 http://127.0.0.1:2586/v1/health >/dev/null 2>&1 && break
    sleep 2
  done
  NTFY_ADMIN_USER=homelab
  [[ "$ACCOUNT_USER" == homelab ]] && NTFY_ADMIN_USER=homelab-bot
  NTFY_ADMIN_PASS="$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')"
  NTFY_TOPIC_NAME="homelab-installer-$(python3 -c 'import secrets; print(secrets.token_hex(6))')"
  if sudo env NTFY_PASSWORD="$NTFY_ADMIN_PASS" docker compose -f "$STACKS/notify/compose.yaml" exec -T -e NTFY_PASSWORD ntfy ntfy user add --role=admin "$NTFY_ADMIN_USER"; then
    sudo install -d -m 0700 -o root -g root /etc/homelab-installer
    ( umask 077; sudo tee "$NTFY_CONF" >/dev/null <<EOF_NTFY_ENV
NTFY_URL=http://127.0.0.1:2586
NTFY_TOPIC=$NTFY_TOPIC_NAME
NTFY_USER=$NTFY_ADMIN_USER
NTFY_PASSWORD=$NTFY_ADMIN_PASS
EOF_NTFY_ENV
    )
    sudo chmod 0600 "$NTFY_CONF"
    sudo /usr/local/sbin/homelab-notify "HomeLab" "Bildirim sistemi kuruldu ve çalışıyor." 3 tada \
      || INSTALL_WARNINGS+=("ntfy test bildirimi gönderilemedi")
  else
    echo "UYARI: ntfy kullanıcısı oluşturulamadı; bildirimler etkin değil."
    INSTALL_WARNINGS+=("ntfy kullanıcısı oluşturulamadı; elle: sudo docker exec -it ntfy ntfy user add --role=admin homelab")
  fi
  unset NTFY_ADMIN_PASS
fi
if sudo docker container inspect ntfy >/dev/null 2>&1; then
  # Telefondan girmek için senin kullanıcı adın ve parolanla ayrı bir ntfy hesabı.
  if ! sudo env NTFY_PASSWORD="$ACCOUNT_PW" docker compose -f "$STACKS/notify/compose.yaml" exec -T -e NTFY_PASSWORD ntfy ntfy user add --role=admin "$ACCOUNT_USER" >/dev/null 2>&1 \
    && ! sudo env NTFY_PASSWORD="$ACCOUNT_PW" docker compose -f "$STACKS/notify/compose.yaml" exec -T -e NTFY_PASSWORD ntfy ntfy user change-pass "$ACCOUNT_USER" >/dev/null 2>&1; then
    INSTALL_WARNINGS+=("ntfy hesabın oluşturulamadı; elle: sudo docker exec -it ntfy ntfy user add --role=admin $ACCOUNT_USER")
  fi
fi
if sudo test -f "$NTFY_CONF"; then
  sudo tee /etc/systemd/system/homelab-health-check.service >/dev/null <<'EOF_HEALTH_SVC'
[Unit]
Description=HomeLab health check

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/homelab-health-check
EOF_HEALTH_SVC
  sudo tee /etc/systemd/system/homelab-health-check.timer >/dev/null <<'EOF_HEALTH_TIMER'
[Unit]
Description=Run HomeLab health check every 10 minutes

[Timer]
OnBootSec=3min
OnUnitActiveSec=10min

[Install]
WantedBy=timers.target
EOF_HEALTH_TIMER
  sudo systemctl daemon-reload
  quiet_run sudo systemctl enable --now homelab-health-check.timer || INSTALL_WARNINGS+=("homelab-health-check.timer etkinleştirilemedi")
fi

echo "[9/13] Yönetim paneli hazırlanıyor"
sudo mkdir -p "$APP" "$BASE/tools"
sudo install -o "$USER_NAME" -g "$(id -gn)" -m 0755 "$SCRIPT_DIR/setup-restic-backup.sh" "$BASE/tools/setup-restic-backup.sh"
sudo install -o "$USER_NAME" -g "$(id -gn)" -m 0755 "$SCRIPT_DIR/configure-beszel-agent.sh" "$BASE/tools/configure-beszel-agent.sh"
sudo install -o "$USER_NAME" -g "$(id -gn)" -m 0755 "$SCRIPT_DIR/reset-panel-password.sh" "$BASE/tools/reset-panel-password.sh"
sudo install -o "$USER_NAME" -g "$(id -gn)" -m 0755 "$SCRIPT_DIR/harden-ssh.sh" "$BASE/tools/harden-ssh.sh"
sudo cp -a "$SCRIPT_DIR/admin-panel/." "$APP/"
sudo chown -R "$USER_NAME:$USER_GROUP" "$APP"
cd "$APP"
python3 -m venv .venv
echo "  panel bağımlılıkları kuruluyor..."
quiet_run .venv/bin/python -m pip install -q --disable-pip-version-check --upgrade pip
quiet_run .venv/bin/python -m pip install -q --disable-pip-version-check -r requirements.txt
mkdir -p instance
chmod 700 instance
if [[ ! -f .env ]]; then
  ACCOUNT_USER="$ACCOUNT_USER" ACCOUNT_PW="$ACCOUNT_PW" .venv/bin/python - <<'PY'
import os, secrets
from werkzeug.security import generate_password_hash
u=os.environ["ACCOUNT_USER"]; p=os.environ["ACCOUNT_PW"]
data=("APP_ENV=production\n"
      f"SECRET_KEY={secrets.token_urlsafe(48)}\n"
      f"ADMIN_USERNAME={u}\n"
      f"ADMIN_PASSWORD_HASH={generate_password_hash(p)}\n"
      "ADMIN_SERVICES_FILE=/srv/homelab/admin-panel/instance/admin-services.json\n"
      "LOGIN_THROTTLE_DB=/srv/homelab/admin-panel/instance/login-attempts.sqlite3\n")
fd=os.open(".env",os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
with os.fdopen(fd,"w") as f: f.write(data)
print("Parola hash'i ve rastgele anahtar .env dosyasına kaydedildi.")
PY
else
  ACCOUNT_USER="$ACCOUNT_USER" ACCOUNT_PW="$ACCOUNT_PW" .venv/bin/python - <<'PY_UPDATE'
import os
from werkzeug.security import generate_password_hash
vals={"ADMIN_USERNAME":os.environ["ACCOUNT_USER"],"ADMIN_PASSWORD_HASH":generate_password_hash(os.environ["ACCOUNT_PW"])}
out=[]; seen=set()
for line in open(".env",encoding="utf-8").read().splitlines():
    k=line.split("=",1)[0]
    if k in vals: out.append(f"{k}={vals[k]}"); seen.add(k)
    else: out.append(line)
out += [f"{k}={v}" for k,v in vals.items() if k not in seen]
fd=os.open(".env.tmp",os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600)
with os.fdopen(fd,"w") as f: f.write("\n".join(out)+"\n")
os.replace(".env.tmp",".env")
print("Mevcut panel hesabı yeni kullanıcı adı ve parolayla güncellendi.")
PY_UPDATE
fi
chmod 600 .env
if [[ ! -f instance/admin-services.json ]]; then
  install -m 600 config/admin-services.example.json instance/admin-services.json
  .venv/bin/python - "$ADGUARD_INSTALL" "$STACKS/monitoring-agent/.env" <<'PY_FILTER'
import json, sys
from pathlib import Path
p=Path("instance/admin-services.json")
data=json.loads(p.read_text(encoding="utf-8"))
install_adguard=sys.argv[1] == "yes"
agent_env=Path(sys.argv[2]).exists()
if not install_adguard:
    data=[x for x in data if x.get("id") != "adguardhome"]
if not agent_env:
    data=[x for x in data if x.get("id") != "beszel-agent"]
p.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY_FILTER
  chmod 600 instance/admin-services.json
fi

echo "[10/13] Sınırlı Docker yönetim yardımcısı"
sudo install -o root -g root -m 0750 "$SCRIPT_DIR/homelab-docker-control" /usr/local/sbin/homelab-docker-control
SUDOERS=/etc/sudoers.d/homelab-admin-panel
sudo tee "$SUDOERS" >/dev/null <<EOF
$USER_NAME ALL=(root) NOPASSWD: /usr/local/sbin/homelab-docker-control
EOF
sudo chmod 0440 "$SUDOERS"
sudo visudo -cf "$SUDOERS"

echo "[11/13] Yönetim paneli systemd servisi hazırlanıyor"
UNIT=/etc/systemd/system/homelab-admin-panel.service
sudo tee "$UNIT" >/dev/null <<EOF
[Unit]
Description=HomeLab private admin panel
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
User=$USER_NAME
Group=$USER_GROUP
WorkingDirectory=$APP
EnvironmentFile=$APP/.env
ExecStart=$APP/.venv/bin/waitress-serve --listen=127.0.0.1:8000 app:app
Restart=on-failure
RestartSec=5
UMask=0077
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$APP/instance
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
quiet_run sudo systemctl enable --now homelab-admin-panel.service
quiet_run sudo systemctl restart homelab-admin-panel.service

echo "[12/13] Samba ve Restic yedekleme yapılandırması"
printf '%s\n%s\n' "$ACCOUNT_PW" "$ACCOUNT_PW" | sudo smbpasswd -a -s "$USER_NAME" >/dev/null
echo "Restic kuruldu. Yedek, harici disk gerektirir; diski bağlayınca: sudo bash $BASE/tools/setup-restic-backup.sh"
TS_LOGIN_URL=""
if [[ "$TS_INSTALL_OK" == yes ]] && ! sudo tailscale ip -4 >/dev/null 2>&1; then
  TS_OUT="$(mktemp)"
  sudo timeout 15 tailscale up >"$TS_OUT" 2>&1 || true
  TS_LOGIN_URL="$(grep -Eo 'https://login\.tailscale\.com/[^[:space:]]+' "$TS_OUT" | head -n 1 || true)"
  rm -f "$TS_OUT"
fi

# Record only packages that were absent before this installer and are installed now.
INSTALLED_TMP="$(mktemp)"
while IFS= read -r PKG; do
  if ! sudo grep -Fxq "$PKG" /var/lib/homelab-installer/markers/preexisting-packages && dpkg-query -W -f='${db:Status-Status}' "$PKG" 2>/dev/null | grep -qx installed; then
    echo "$PKG" >> "$INSTALLED_TMP"
  fi
done < <(printf '%s\n' "${PACKAGE_CANDIDATES[@]}")
sudo install -o root -g root -m 0600 "$INSTALLED_TMP" /var/lib/homelab-installer/markers/installed-packages
rm -f "$INSTALLED_TMP"

SERVER_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
SERVER_IP="${SERVER_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
SERVER_IP="${SERVER_IP:-SUNUCU-IP}"
TS_IP="$(tailscale ip -4 2>/dev/null | head -n 1 || true)"
SUMMARY_FILE="$LOG_DIR/kurulum-ozeti-$(date +%Y%m%d-%H%M%S).txt"
NTFY_URL_S=""; NTFY_TOPIC_S=""
if sudo test -f /etc/homelab-installer/ntfy.env; then
  while IFS='=' read -r K V; do
    if [[ "$K" == NTFY_TOPIC ]]; then NTFY_TOPIC_S="$V"; fi
  done < <(sudo cat /etc/homelab-installer/ntfy.env)
  NTFY_URL_S="http://$SERVER_IP:2586"
fi
FB_PASS="$(sudo docker logs filebrowser 2>&1 | grep -i 'password' | tail -n 1 || true)"
(
  umask 077
  {
    echo "HOMELAB KURULUM ÖZETİ - $(date '+%d.%m.%Y %H:%M')   (bu dosya gizli bilgi içerir; paylaşma)"
    echo "======================================================================"
    echo "Sunucu adı        : $(hostname)"
    echo "Yerel ağ IP       : $SERVER_IP"
    echo "Tailscale IP      : ${TS_IP:-bağlı değil}"
    if [[ -z "$TS_IP" && "$TS_INSTALL_OK" == yes ]]; then
      echo "Tailscale girişi  : ${TS_LOGIN_URL:-sudo tailscale up}   (tarayıcıda aç; çalışmazsa 'sudo tailscale up' ile yeni bağlantı al)"
    fi
    echo
    echo "YEREL WEB SAYFASI (sunucunun kendi tarayıcısında): http://127.0.0.1:8088"
    echo "YÖNETİM PANELİ    : http://127.0.0.1:8000   kullanıcı: $ACCOUNT_USER   parola: kurulumda belirlediğin (hepsinde aynı)"
    echo
    echo "AĞDAN ERİŞİLENLER (aynı ağdaki bilgisayar/telefon):"
    echo "  Dockge       http://$SERVER_IP:5001"
    echo "  Beszel       http://$SERVER_IP:8090"
    echo "  Uptime Kuma  http://$SERVER_IP:3001"
    echo "  Scrutiny     http://$SERVER_IP:8081"
    echo "  Syncthing    http://127.0.0.1:8384   kullanıcı: $ACCOUNT_USER   parola: aynı"
    echo "  File Browser http://$SERVER_IP:8080   kullanıcı: admin   ${FB_PASS:-ilk parola: sudo docker logs filebrowser 2>&1 | grep -i password}"
    echo "  n8n          http://$SERVER_IP:5678"
    if [[ "$ADGUARD_INSTALL" == yes ]]; then echo "  AdGuard      http://$ADGUARD_IP:3000 (ilk kurulum) / http://$ADGUARD_IP:3002"; fi
    echo "  Samba        \\\\$SERVER_IP\\Paylasim   kullanıcı: $USER_NAME   parola: kurulumda sen belirledin"
    echo
    echo "UZAKTAN MASAÜSTÜ (RustDesk): ID: ${RUSTDESK_ID:-bulunamadı (RustDesk uygulamasında görünür)}   parola: kurulumda sen belirledin"
    if [[ -n "$NTFY_URL_S" ]]; then
      echo
      echo "BİLDİRİM (ntfy): adres: $NTFY_URL_S"
      echo "  kullanıcı: $ACCOUNT_USER   parola: aynı"
      echo "  konu     : $NTFY_TOPIC_S   (telefondaki ntfy uygulamasına bu adres, kullanıcı ve konuyu ekle)"
    fi
    echo
    echo "İLK GİRİŞTE hesabı SEN açan servisler (Dockge, Beszel, Uptime Kuma, n8n, AdGuard): kullanıcı adı olarak $ACCOUNT_USER ve aynı parolayı gir."
    echo
    echo "Beszel Agent anahtarı: Beszel'de sistem ekleyince çıkar; sonra: bash $BASE/tools/configure-beszel-agent.sh"
    echo "Kurulum günlüğü: $LOG_FILE"
  } > "$SUMMARY_FILE"
)
echo "[13/13] Son durum ve erişim bilgileri"
echo
echo "================ KURULUM TAMAMLANDI ================"
echo "Kurulum günlüğü: $LOG_FILE"
if ((${#INSTALL_WARNINGS[@]})); then
  echo "DURUM: Ana kurulum tamamlandı ancak isteğe bağlı bazı bileşenler kurulamadı."
  for WARNING in "${INSTALL_WARNINGS[@]}"; do echo "  - $WARNING"; done
  echo "Bu bileşenleri ve günlükleri tamamlanma mesajından önce kontrol et."
else
  echo "DURUM: Seçilen kurulum adımları tamamlandı."
fi
echo "Yerel web sayfası (sunucuda): http://127.0.0.1:8088"
echo "Panel (yalnızca sunucu): http://127.0.0.1:8000"
echo "Dockge       : http://$SERVER_IP:5001"
echo "Beszel       : http://$SERVER_IP:8090"
echo "Uptime Kuma  : http://$SERVER_IP:3001"
echo "Scrutiny     : http://$SERVER_IP:8081"
echo "File Browser : http://$SERVER_IP:8080"
echo "n8n          : http://$SERVER_IP:5678"
echo "ntfy (bildirim): http://$SERVER_IP:2586  (telefon uygulamasına bu adresi ekle; kullanıcı/parola/konu: sudo cat /etc/homelab-installer/ntfy.env)"
echo "Ollama       : http://127.0.0.1:11434"
if [[ "$ADGUARD_INSTALL" == yes ]]; then echo "AdGuard ilk kurulum: http://$ADGUARD_IP:3000 ; sonrası: http://$ADGUARD_IP:3002"; fi
echo "Syncthing    : http://127.0.0.1:8384"
echo "Yerel ad     : http://$(hostname -s).local:8090 (mDNS destekleyen ağ/cihazlarda)"
echo "Samba        : \\\\$SERVER_IP\\Paylasim"
echo
echo "Kontrol: sudo docker ps"
echo "Panel:   sudo systemctl status homelab-admin-panel"
echo "Beszel Agent ayarı: bash $BASE/tools/configure-beszel-agent.sh"
echo "Restic yedekleme:   sudo bash $BASE/tools/setup-restic-backup.sh"
echo "SSH anahtar girişi: bash $BASE/tools/harden-ssh.sh   (önce anahtarını ekle; kendini kilitlemeden doğrular)"
echo "Panel parolası sıfırla: bash $BASE/tools/reset-panel-password.sh"
echo "Panel log: sudo journalctl -u homelab-admin-panel -n 80 --no-pager"
echo
echo "================ İLK GİRİŞTE HEMEN YAP ================"
echo "Bu servislerin ilk hesabını SEN oluştur (ilk açan kişi yönetici olur). Kullanıcı adı: $ACCOUNT_USER, parola: kurulumda belirlediğin aynı parola:"
echo "  Dockge       : http://$SERVER_IP:5001  -> yönetici hesabı oluştur"
echo "  Beszel       : http://$SERVER_IP:8090  -> yönetici hesabı oluştur"
echo "  Uptime Kuma  : http://$SERVER_IP:3001  -> yönetici hesabı oluştur"
echo "  n8n          : http://$SERVER_IP:5678  -> sahip (owner) hesabı oluştur"
echo "  File Browser : kullanıcı 'admin'; ilk parola rastgele üretilir ve günlüğe yazılır:"
echo "                 sudo docker logs filebrowser 2>&1 | grep -i password   (girişten sonra değiştir)"
echo "  Scrutiny     : giriş ekranı YOKTUR; yalnızca yerel ağda kalmalı."
echo "  AdGuard      : kurulum sihirbazında yönetici hesabı oluştur"
if [[ "${LAN_LOCK_OK:-no}" == yes ]]; then
  echo "Docker portları internetten gelen yeni IPv4 bağlantılarına kapatıldı (yerel ağ ve Tailscale açık)."
else
  echo "UYARI: Docker port kilidi doğrulanamadı; portlar LAN dışına açık olabilir. Router'da port yönlendirme yapma."
fi
echo "Beszel Agent (45876) ve SSH/Samba ana makine servisleridir; router'dan yönlendirme yapma."
echo "UFW etkinleştirilmedi; SSH/RustDesk erişimini kilitlememek için."
echo "Cloudflare/DNS/router ayarlarına dokunulmadı."
echo "ÖNEMLİ: Router'da servis portlarını internete yönlendirme."

unset ACCOUNT_PW
sleep 1
echo
echo "Özet dosyası (gizli bilgi içerir): $SUMMARY_FILE"
echo "Aşağıdaki özet güvenlik için kurulum günlüğüne yazılmaz; yalnızca ekranda ve özet dosyasında bulunur."
echo
cat "$SUMMARY_FILE" >&3
