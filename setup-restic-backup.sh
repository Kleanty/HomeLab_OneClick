#!/usr/bin/env bash
set -Eeuo pipefail
if [[ $EUID -ne 0 ]]; then
  echo "Bu araç root yetkisi ister: sudo bash setup-restic-backup.sh" >&2
  exit 1
fi
LOG_FILE=/var/log/homelab-installer-restic-setup.log
exec > >(tee -a "$LOG_FILE") 2>&1
on_error() {
  local rc="$?" line="$1" cmd="$2"
  trap - ERR
  echo >&2
  echo "HATA: Restic kurulumu $line. satırda durdu (çıkış kodu: $rc)." >&2
  echo "Çalıştırılan komut: $cmd" >&2
  echo "Ayrıntılı günlük: $LOG_FILE" >&2
  echo "Harici yedek deposu silinmedi. Tekrar çalıştırmadan önce /etc/restic durumunu incele." >&2
  exit "$rc"
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR
on_signal() {
  local signal="$1" rc="$2"
  trap - INT TERM ERR
  echo >&2
  echo "Restic kurulumu durduruldu ($signal, çıkış kodu: $rc)." >&2
  echo "Harici depo silinmedi; yerel yapılandırmayı incele. Günlük: $LOG_FILE" >&2
  exit "$rc"
}
trap 'on_signal INT 130' INT
trap 'on_signal TERM 143' TERM
command -v restic >/dev/null || { echo "Restic kurulu değil. Önce KUR.sh çalıştır." >&2; exit 1; }
command -v findmnt >/dev/null || { echo "findmnt bulunamadı." >&2; exit 1; }
if [[ -e /etc/restic/homelab.env || -e /etc/restic/homelab-password || -e /etc/systemd/system/homelab-restic-backup.service ]]; then
  echo "Restic yapılandırması zaten mevcut; mevcut yedek ayarlarını korumak için işlem durduruldu." >&2
  exit 1
fi

cat <<'MSG'
RESTIC YEDEKLEME KURULUMU
------------------------
Hedef, sistem diskinin dışında bağlanmış bir disk/dosya sistemi olmalıdır.
Örnek: /media/kullanici/YEDEK/restic
Aynı sistem diskine yedek almak disk arızasına karşı koruma sağlamaz.
MSG
echo "Bağlı harici disk adayları (/media ve /mnt altı):"
findmnt -rno TARGET,SOURCE,FSTYPE | awk '$1 ~ /^\/(media|mnt)\// {print "  " $1 "  (" $2 ", " $3 ")"}' || true
echo "Yol örneği: <bağlama noktası>/restic   (boşluk içeren ad kullanma). Boş bırakıp Enter = şimdilik atla."
REPO=""
for _ in 1 2 3; do
  read -r -p "Harici diskteki yedek deposu yolu: " REPO
  if [[ -z "$REPO" ]]; then
    echo "Restic kurulumu atlandı. Disk bağlayınca: sudo bash /srv/homelab/tools/setup-restic-backup.sh"
    exit 0
  fi
  [[ "$REPO" =~ ^/[A-Za-z0-9._/-]+$ ]] && break
  echo "Mutlak yol gerekli; boşluk ve özel karakter kullanma." >&2
  REPO=""
done
[[ -n "$REPO" ]] || { echo "Geçerli yol girilmedi; Restic kurulumu atlandı." >&2; exit 1; }
[[ "$REPO" != /srv/homelab* ]] || { echo "Yedek deposu /srv/homelab içinde olamaz." >&2; exit 1; }
PARENT="$(dirname -- "$REPO")"
[[ -d "$PARENT" ]] || { echo "Üst dizin mevcut değil: $PARENT" >&2; exit 1; }
MOUNT_TARGET="$(findmnt -n -o TARGET -T "$PARENT")"
MOUNT_SOURCE="$(findmnt -n -o SOURCE -T "$PARENT")"
[[ "$MOUNT_TARGET" != / ]] || {
  echo "Bu yol ayrı bir bağlanmış dosya sisteminde görünmüyor. Harici diski bağla ve tekrar dene." >&2
  exit 1
}
echo "Algılanan bağlama noktası: $MOUNT_TARGET ($MOUNT_SOURCE)"
ROOT_SOURCE="$(findmnt -n -o SOURCE -T / | sed 's/\[.*$//')"
BACKUP_SOURCE="${MOUNT_SOURCE%%\[*}"
if [[ -b "$ROOT_SOURCE" && -b "$BACKUP_SOURCE" ]]; then
  ROOT_DISKS="$(lsblk -s -nrpo NAME,TYPE "$ROOT_SOURCE" | awk '$2 == "disk" {print $1}' | sort -u)"
  BACKUP_DISKS="$(lsblk -s -nrpo NAME,TYPE "$BACKUP_SOURCE" | awk '$2 == "disk" {print $1}' | sort -u)"
  if [[ -n "$ROOT_DISKS" && -n "$BACKUP_DISKS" ]] && comm -12 <(printf '%s\n' "$ROOT_DISKS") <(printf '%s\n' "$BACKUP_DISKS") | grep -q .; then
    echo "Yedek hedefi sistem diskiyle aynı fiziksel diskte görünüyor. Bu disk arızasına karşı koruma sağlamaz." >&2
    exit 1
  fi
fi
case "$MOUNT_TARGET" in
  /media/*|/run/media/*)
    echo "UYARI: Bu yol masaüstü oturumu tarafından otomatik bağlanan bir disk olabilir."
    echo "Bilgisayar açık olsa bile kullanıcı oturumu açılmadan günlük 03:15 görevi diski göremeyebilir."
    echo "Kesintisiz otomasyon için diskin açılışta sabit bir noktaya UUID ile bağlandığından emin ol."
    read -r -p "Bu bağlama düzeninin zamanlayıcı çalışırken hazır olacağını doğruluyor musun? [e/H]: " MOUNT_CONFIRM
    [[ "$MOUNT_CONFIRM" =~ ^[EeYy]$ ]] || { echo "Önce kalıcı bağlama yapılandır; işlem iptal edildi." >&2; exit 1; }
    ;;
esac
read -r -p "Bu hedefin sistem diskinden ayrı bir yedek diski olduğunu doğruluyor musun? [e/H]: " CONFIRM
[[ "$CONFIRM" =~ ^[EeYy]$ ]] || { echo "İptal edildi."; exit 0; }

if [[ -e "$REPO" ]] && find "$REPO" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
  echo "Hedef dizin boş değil; mevcut verileri korumak için işlem durduruldu: $REPO" >&2
  exit 1
fi
read -r -s -p "Restic şifreleme parolası (en az 20 karakter): " PASS1; echo
read -r -s -p "Parolayı tekrar gir: " PASS2; echo
[[ ${#PASS1} -ge 20 ]] || { echo "Parola en az 20 karakter olmalı." >&2; exit 1; }
[[ "$PASS1" == "$PASS2" ]] || { echo "Parolalar eşleşmiyor." >&2; exit 1; }

install -d -o root -g root -m 0700 /etc/restic /var/lib/homelab-restic /var/lib/homelab-restic/cache
mkdir -p -- "$REPO"
chmod 0700 "$REPO" 2>/dev/null || echo "Not: Bu dosya sistemi izin ayarını desteklemiyor (exFAT/NTFS olabilir); yedek şifreli olduğu için devam ediliyor."
( umask 077; printf '%s\n' "$PASS1" > /etc/restic/homelab-password )
chmod 0600 /etc/restic/homelab-password
unset PASS1 PASS2
cat > /etc/restic/homelab.env <<EOF_ENV
RESTIC_REPOSITORY=$REPO
RESTIC_PASSWORD_FILE=/etc/restic/homelab-password
RESTIC_CACHE_DIR=/var/lib/homelab-restic/cache
EOF_ENV
chmod 0600 /etc/restic/homelab.env

if [[ -n "$(find "$REPO" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
  echo "Depo oluşturulurken hedef boş olmaktan çıktı; işlem durduruldu." >&2
  exit 1
fi
set -a
# shellcheck disable=SC1091
source /etc/restic/homelab.env
set +a
restic init

cat > /usr/local/sbin/homelab-restic-backup <<'EOF_BACKUP'
#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/restic/homelab.env
export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE RESTIC_CACHE_DIR

PARENT="$(dirname -- "$RESTIC_REPOSITORY")"
[[ -d "$PARENT" ]] || { echo "Yedek diski bulunamadı: $PARENT" >&2; exit 2; }
MOUNT_TARGET="$(findmnt -n -o TARGET -T "$PARENT")"
[[ "$MOUNT_TARGET" != / ]] || { echo "Yedek diski bağlı değil; sistem diskine yedek alınmayacak." >&2; exit 2; }

STAGE=/var/lib/homelab-restic/staging
rm -rf "$STAGE"
install -d -o root -g root -m 0700 "$STAGE/sqlite"

# SQLite uygulama veritabanları için canlı veritabanından tutarlı kopya üret.
if [[ -d /srv/homelab/appdata ]]; then
  while IFS= read -r -d '' DB; do
    if sqlite3 "$DB" 'PRAGMA quick_check;' 2>/dev/null | grep -qx 'ok'; then
      REL="${DB#/srv/homelab/}"
      DEST="$STAGE/sqlite/$REL.snapshot"
      install -d -o root -g root -m 0700 "$(dirname -- "$DEST")"
      if sqlite3 "$DB" ".backup '$DEST'"; then
        chmod 0600 "$DEST"
      else
        echo "UYARI: $DB için tutarlı kopya alınamadı; dosya doğrudan yedeklenecek." >&2
        rm -f -- "$DEST"
      fi
    fi
  done < <(find /srv/homelab/appdata -type f \( -name '*.sqlite' -o -name '*.sqlite3' -o -name '*.db' \) -print0)
fi

PATHS=(/srv/homelab /etc/ssh /etc/samba /var/lib/samba /etc/docker /etc/fail2ban \
  /etc/fstab /etc/hostname /etc/hosts /etc/apt/sources.list.d /var/lib/homelab-restic/staging)
for EXTRA in /etc/systemd/system/homelab-admin-panel.service /etc/sudoers.d/homelab-admin-panel; do
  [[ -e "$EXTRA" ]] && PATHS+=("$EXTRA")
done
if [[ -n "${HOMELAB_BACKUP_HOME:-}" && -d "$HOMELAB_BACKUP_HOME/.ssh" ]]; then
  PATHS+=("$HOMELAB_BACKUP_HOME/.ssh")
fi

restic backup --tag homelab --exclude '**/.venv' --exclude '**/node_modules' \
  --exclude '**/__pycache__' --exclude '**/.cache' --exclude '**/*.log' \
  "${PATHS[@]}"
restic forget --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --prune
EOF_BACKUP
chmod 0750 /usr/local/sbin/homelab-restic-backup

cat > /etc/systemd/system/homelab-restic-backup.service <<'EOF_SERVICE'
[Unit]
Description=Encrypted HomeLab backup with Restic
OnFailure=homelab-notify-failure@%n.service
Wants=network-online.target
After=network-online.target local-fs.target

[Service]
Type=oneshot
User=root
EnvironmentFile=/etc/restic/homelab.env
Environment=HOMELAB_BACKUP_HOME=__HOME_DIR__
ExecStart=/usr/local/sbin/homelab-restic-backup
Nice=19
IOSchedulingClass=best-effort
IOSchedulingPriority=7
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/var/lib/homelab-restic __REPO_PARENT__
TimeoutStartSec=6h
EOF_SERVICE
OWNER_HOME="${SUDO_USER_HOME:-}"
if [[ -z "$OWNER_HOME" && -n "${SUDO_USER:-}" ]]; then OWNER_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"; fi
OWNER_HOME="${OWNER_HOME:-/root}"
sed -i "s|__HOME_DIR__|$OWNER_HOME|g; s|__REPO_PARENT__|$PARENT|g" /etc/systemd/system/homelab-restic-backup.service

cat > /etc/systemd/system/homelab-restic-backup.timer <<'EOF_TIMER'
[Unit]
Description=Daily HomeLab Restic backup

[Timer]
OnCalendar=*-*-* 03:15:00
Persistent=true
RandomizedDelaySec=30m
Unit=homelab-restic-backup.service

[Install]
WantedBy=timers.target
EOF_TIMER

cat > /etc/systemd/system/homelab-restic-check.service <<'EOF_CHECK_SERVICE'
[Unit]
Description=Weekly Restic repository integrity check
OnFailure=homelab-notify-failure@%n.service
Wants=network-online.target
After=network-online.target local-fs.target

[Service]
Type=oneshot
User=root
EnvironmentFile=/etc/restic/homelab.env
ExecStart=/usr/bin/restic check --read-data-subset=5%
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/var/lib/homelab-restic/cache __REPO_PARENT__
EOF_CHECK_SERVICE
sed -i "s|__REPO_PARENT__|$PARENT|g" /etc/systemd/system/homelab-restic-check.service

cat > /etc/systemd/system/homelab-restic-check.timer <<'EOF_CHECK_TIMER'
[Unit]
Description=Weekly Restic repository check

[Timer]
OnCalendar=Sun *-*-* 05:00:00
Persistent=true
RandomizedDelaySec=20m
Unit=homelab-restic-check.service

[Install]
WantedBy=timers.target
EOF_CHECK_TIMER

systemctl daemon-reload
systemctl enable --now homelab-restic-backup.timer homelab-restic-check.timer
install -d -o root -g root -m 0700 /var/lib/homelab-installer/markers
touch /var/lib/homelab-installer/markers/restic-created
printf '\nRestic kuruldu. İlk yedek için: sudo systemctl start homelab-restic-backup.service\n'
printf 'Yedek parolasını ayrıca parola kasasında sakla; parola kaybolursa yedek açılamaz.\n'
