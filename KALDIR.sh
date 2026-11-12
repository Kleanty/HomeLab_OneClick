#!/usr/bin/env bash
set -Eeuo pipefail
LOG_DIR="$HOME/HomeLab_Logs"
mkdir -p "$LOG_DIR"
chmod 0700 "$LOG_DIR"
LOG_FILE="$LOG_DIR/kaldirma-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
on_error() {
  local rc="$?" line="$1" cmd="$2"
  trap - ERR
  echo >&2
  echo "HATA: Kaldırma $line. satırda durdu (çıkış kodu: $rc)." >&2
  echo "Çalıştırılan komut: $cmd" >&2
  echo "Ayrıntılı günlük: $LOG_FILE" >&2
  exit "$rc"
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

# HomeLab kurulum betiğinin oluşturduğu bilinen servisleri kaldırır.
# Varsayılan olarak kullanıcı verilerini ve işletim sistemi paketlerini silmez.

if [[ $EUID -eq 0 ]]; then
  echo "Bu dosyayı sudo ile değil normal kullanıcıyla çalıştır: bash KALDIR.sh" >&2
  exit 1
fi

SUDO_USER_NAME="$(id -un)"
BASE=/srv/homelab
STACKS="$BASE/compose"

cat <<'BANNER'
============================================================
 HOMELAB - KONTROLLÜ KALDIRMA ARACI
============================================================
Bu araç yalnızca HomeLab kurulumunda kullanılan bilinen
servisleri, paneli ve yardımcı yapılandırmaları hedefler.

Varsayılan davranış:
- Bilinen HomeLab konteynerlerini ve Compose ağlarını durdurur/kaldırır.
- Yönetim paneli ve Restic zamanlayıcılarını kaldırır.
- HomeLab'e ait sudoers, Fail2ban, journald ve Samba paylaşım
  yapılandırmalarını kaldırır.
- /srv/homelab içindeki dosyaları varsayılan olarak KORUR.
- Docker / SSH / Samba / Syncthing gibi sistem paketlerini
  varsayılan olarak KALDIRMAZ.
- Harici Restic yedek deposunu hiçbir koşulda silmez.

UYARI: Paket kaldırma seçeneği SSH erişimini ve diğer ağ
servislerini etkileyebilir. Uzaktan SSH oturumunda çalıştırma.
BANNER

echo
read -r -p "Devam etmek için TAM OLARAK HOMELAB-KALDIR yaz: " CONFIRM
[[ "$CONFIRM" == "HOMELAB-KALDIR" ]] || { echo "İptal edildi."; exit 0; }
sudo -v

remove_compose_stack() {
  local name="$1" file="$2" envfile="${3:-}"
  if sudo test -f "/var/lib/homelab-installer/markers/compose-foreign-$name"; then
    echo "[Docker] $name: Compose dosyası kurulumdan önce vardı; dokunulmadı."
    return 0
  fi
  if sudo test -f "$file" && sudo docker info >/dev/null 2>&1; then
    echo "[Docker] $name durduruluyor..."
    if [[ -n "$envfile" ]] && sudo test -f "$envfile"; then
      sudo docker compose --env-file "$envfile" -f "$file" down --remove-orphans || \
        echo "UYARI: $name Compose projesi tamamen kaldırılamadı; konteyner kontrolü ayrıca yapılacak."
    else
      sudo docker compose -f "$file" down --remove-orphans || \
        echo "UYARI: $name Compose projesi tamamen kaldırılamadı; konteyner kontrolü ayrıca yapılacak."
    fi
  fi
}

echo
echo "[1/7] HomeLab konteynerleri ve ağları"
if command -v docker >/dev/null 2>&1 && sudo docker info >/dev/null 2>&1; then
  remove_compose_stack dockge "$STACKS/dockge/compose.yaml"
  remove_compose_stack monitoring "$STACKS/monitoring/compose.yaml"
  remove_compose_stack cloud "$STACKS/cloud/compose.yaml"
  remove_compose_stack ai "$STACKS/ai/compose.yaml"
  remove_compose_stack storage "$STACKS/storage/compose.yaml"
  remove_compose_stack web "$STACKS/web/compose.yaml"
  remove_compose_stack notify "$STACKS/notify/compose.yaml"
  remove_compose_stack adguard "$STACKS/adguard/compose.yaml" "$STACKS/adguard/.env"
  remove_compose_stack monitoring-agent "$STACKS/monitoring-agent/compose.yaml" "$STACKS/monitoring-agent/.env"

  # Compose dosyası silinmiş/bozulmuş olsa da yalnızca bu paketin sabit konteyner adları hedeflenir.
  for c in dockge beszel uptime-kuma filebrowser ollama n8n scrutiny caddy adguardhome beszel-agent ntfy; do
    if sudo docker container inspect "$c" >/dev/null 2>&1; then
      # Yalnızca Compose çalışma dizini bu kurulumun yığın klasörlerinden biriyse ve dosya bize aitse sil.
      WD="$(sudo docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$c" 2>/dev/null || true)"
      if [[ "$WD" == "$STACKS"/* ]] && ! sudo test -f "/var/lib/homelab-installer/markers/compose-foreign-${WD##*/}"; then
        sudo docker rm -f "$c"
      else
        echo "[Docker] $c bu kurulumun Compose yığınına ait görünmüyor; dokunulmadı."
      fi
    fi
  done
else
  echo "Docker çalışmıyor veya kurulu değil; konteyner adımı atlandı."
fi

echo
echo "[2/7] HomeLab yönetim paneli ve Restic zamanlayıcıları"
sudo systemctl disable --now homelab-admin-panel.service >/dev/null 2>&1 || true
sudo rm -f /etc/systemd/system/homelab-admin-panel.service

# Restic bir önceki kurulum tarafından kurulmuş değilse kendi birimlerini kaldır.
if sudo test -f /var/lib/homelab-installer/markers/restic-created; then
  for unit in homelab-restic-backup.service homelab-restic-backup.timer homelab-restic-check.service homelab-restic-check.timer; do
    sudo systemctl disable --now "$unit" >/dev/null 2>&1 || true
  done
  sudo rm -f /etc/systemd/system/homelab-restic-backup.service \
    /etc/systemd/system/homelab-restic-backup.timer \
    /etc/systemd/system/homelab-restic-check.service \
    /etc/systemd/system/homelab-restic-check.timer \
    /usr/local/sbin/homelab-restic-backup
fi
sudo systemctl daemon-reload
sudo systemctl reset-failed >/dev/null 2>&1 || true

# Docker port kilidi (LAN-only) kuralları ve birimi
if sudo test -x /usr/local/sbin/homelab-docker-lan-only; then
  sudo /usr/local/sbin/homelab-docker-lan-only remove || true
fi
sudo systemctl disable --now homelab-docker-lan-only.service >/dev/null 2>&1 || true
sudo rm -f /etc/systemd/system/homelab-docker-lan-only.service /usr/local/sbin/homelab-docker-lan-only

# Sadece HomeLab kurulumuna ait sabit yönetim yardımcıları.
sudo rm -f /usr/local/sbin/homelab-docker-control /etc/sudoers.d/homelab-admin-panel

# Restic parolası ve yerel önbellek silinir; harici RESTIC_REPOSITORY korunur.
if sudo test -f /var/lib/homelab-installer/markers/restic-created; then
  if sudo test -f /etc/restic/homelab.env; then
    REPO_PATH="$(sudo sed -n 's/^RESTIC_REPOSITORY=//p' /etc/restic/homelab.env | head -n1)"
    [[ -z "$REPO_PATH" ]] || echo "Harici Restic deposu korunacak: $REPO_PATH"
  fi
  sudo rm -f /etc/restic/homelab.env /etc/restic/homelab-password
  sudo rmdir /etc/restic 2>/dev/null || true
  sudo rm -rf /var/lib/homelab-restic
else
  echo "Restic yapılandırması bu paket tarafından oluşturulmamış; korunuyor."
fi

# Kurulumun Cinnamon güç düğmesi ayarını, önceki değer kaydedildiyse geri yükle.
POWER_BACKUP=/var/lib/homelab-installer/cinnamon-button-power.before
if sudo test -f "$POWER_BACKUP" && command -v gsettings >/dev/null 2>&1; then
  PREVIOUS_POWER_ACTION="$(sudo cat "$POWER_BACKUP")"
  if [[ -n "$PREVIOUS_POWER_ACTION" ]] && gsettings set org.cinnamon.settings-daemon.plugins.power button-power "$PREVIOUS_POWER_ACTION" 2>/dev/null; then
    echo "Cinnamon güç düğmesi önceki ayarına döndürüldü."
  else
    echo "UYARI: Cinnamon güç düğmesi önceki ayarına otomatik döndürülemedi."
  fi
fi
if sudo test -f /var/lib/homelab-installer/markers/logind-power-created; then
  sudo rm -f /etc/systemd/logind.conf.d/90-homelab-installer-power-button.conf
  sudo rmdir /etc/systemd/logind.conf.d 2>/dev/null || true
fi
# Uyku engelini, otomatik girişi ve kaydedilen Cinnamon uyku ayarlarını geri al.
for SLEEP_TARGET in sleep suspend hibernate hybrid-sleep; do
  if sudo test -f "/var/lib/homelab-installer/markers/sleep-masked-$SLEEP_TARGET"; then
    sudo systemctl unmask "$SLEEP_TARGET.target" >/dev/null 2>&1 || true
  fi
done
if sudo test -f /var/lib/homelab-installer/markers/logind-nosleep-created; then
  sudo rm -f /etc/systemd/logind.conf.d/91-homelab-installer-no-sleep.conf
  sudo rmdir /etc/systemd/logind.conf.d 2>/dev/null || true
  sudo systemctl kill -s HUP systemd-logind >/dev/null 2>&1 || true
fi
if sudo test -f /var/lib/homelab-installer/gsettings-sleep.before && command -v gsettings >/dev/null 2>&1; then
  while IFS='|' read -r SCHEMA KEY VALUE; do
    [[ -n "$SCHEMA" && -n "$KEY" ]] && gsettings set "$SCHEMA" "$KEY" "$VALUE" 2>/dev/null || true
  done < <(sudo cat /var/lib/homelab-installer/gsettings-sleep.before)
  sudo rm -f /var/lib/homelab-installer/gsettings-sleep.before
  echo "Cinnamon uyku ayarları önceki değerlerine döndürüldü."
fi
if sudo test -f /var/lib/homelab-installer/markers/autologin-created; then
  sudo rm -f /etc/lightdm/lightdm.conf.d/70-homelab-installer-autologin.conf
  sudo rmdir /etc/lightdm/lightdm.conf.d 2>/dev/null || true
fi
# Yardımcı araçlar yalnızca /srv/homelab/tools altında bulunur; tüm veri dizini korunur.
sudo rm -f "$BASE/tools/setup-restic-backup.sh" "$BASE/tools/configure-beszel-agent.sh" "$BASE/tools/reset-panel-password.sh" "$BASE/tools/harden-ssh.sh"

# Bildirim sistemi ve sağlık denetimi
sudo systemctl disable --now homelab-health-check.timer >/dev/null 2>&1 || true
sudo rm -f /etc/systemd/system/homelab-health-check.timer /etc/systemd/system/homelab-health-check.service \
  /etc/systemd/system/homelab-notify-failure@.service /usr/local/sbin/homelab-notify /usr/local/sbin/homelab-health-check
sudo rm -rf /etc/homelab-installer
sudo rm -f /var/lib/homelab-installer/health-state
sudo systemctl daemon-reload

# Otomatik güvenlik güncellemesi ayarı (yalnızca bu kurulum oluşturduysa)
if sudo test -f /var/lib/homelab-installer/markers/unattended-created; then
  sudo rm -f /etc/apt/apt.conf.d/52homelab-unattended-upgrades
fi
if [[ -f /etc/ssh/sshd_config.d/10-homelab-hardening.conf ]]; then
  echo "Not: SSH sertleştirme ayarı (parola girişi kapalı) bilerek korundu. Geri almak için: sudo rm /etc/ssh/sshd_config.d/10-homelab-hardening.conf && sudo systemctl reload ssh"
fi
sudo rmdir "$BASE/tools" 2>/dev/null || true

echo
echo "[3/7] HomeLab'e ait sistem yapılandırmaları"
if sudo test -f /var/lib/homelab-installer/markers/docker-group-added \
  && getent group docker >/dev/null 2>&1; then
  if sudo gpasswd -d "$SUDO_USER_NAME" docker >/dev/null; then
    echo "Bu kurulumun eklediği Docker grup üyeliği kaldırıldı."
  else
    echo "UYARI: Docker grup üyeliği kaldırılamadı; gerekirse elle kaldır: sudo gpasswd -d $SUDO_USER_NAME docker"
  fi
fi
if sudo test -f /var/lib/homelab-installer/markers/linger-added; then
  sudo loginctl disable-linger "$SUDO_USER_NAME" || \
    echo "UYARI: Bu kurulumun eklediği lingering ayarı kaldırılamadı."
fi
if sudo test -f /var/lib/homelab-installer/markers/fail2ban-created; then
  sudo rm -f /etc/fail2ban/jail.d/homelab-sshd.local
  sudo rmdir /etc/fail2ban/jail.d 2>/dev/null || true
fi
if sudo test -f /var/lib/homelab-installer/markers/journald-created; then
  sudo rm -f /etc/systemd/journald.conf.d/homelab.conf
  sudo rmdir /etc/systemd/journald.conf.d 2>/dev/null || true
fi
if sudo systemctl is-active --quiet fail2ban 2>/dev/null; then sudo systemctl restart fail2ban || true; fi
if sudo systemctl is-active --quiet systemd-journald 2>/dev/null; then sudo systemctl restart systemd-journald || true; fi

# KUR.sh'ın eklediği [Paylasim] Samba bölümünü, diğer paylaşım tanımlarını koruyarak çıkar.
if sudo test -f /var/lib/homelab-installer/markers/samba-share-created && sudo test -f /etc/samba/smb.conf && sudo grep -q '^\[Paylasim\][[:space:]]*$' /etc/samba/smb.conf; then
  STAMP="$(date +%Y%m%d-%H%M%S)"
  sudo cp -a /etc/samba/smb.conf "/etc/samba/smb.conf.before-homelab-remove-$STAMP"
  sudo python3 - <<'PY'
from pathlib import Path
p = Path('/etc/samba/smb.conf')
lines = p.read_text(encoding='utf-8', errors='replace').splitlines(keepends=True)
out = []
skip = False
for line in lines:
    stripped = line.strip()
    if stripped.startswith('[') and stripped.endswith(']'):
        if stripped.lower() == '[paylasim]':
            skip = True
            continue
        skip = False
    if not skip:
        out.append(line)
p.write_text(''.join(out), encoding='utf-8')
PY
  if command -v testparm >/dev/null 2>&1; then sudo testparm -s >/dev/null; fi
  sudo systemctl reload smbd 2>/dev/null || sudo systemctl restart smbd 2>/dev/null || true
fi

# Docker daemon.json yalnızca kurulum betiğinin varsayılan log ayarıyla birebir eşleşiyorsa kaldırılır.
if sudo test -f /var/lib/homelab-installer/markers/docker-daemon-json-created && sudo test -f /etc/docker/daemon.json; then
  if sudo python3 - <<'PY'
import json
from pathlib import Path
p=Path('/etc/docker/daemon.json')
try:
    d=json.loads(p.read_text())
except Exception:
    raise SystemExit(1)
expected={'log-driver':'local','log-opts':{'max-size':'10m','max-file':'3'}}
raise SystemExit(0 if d == expected else 1)
PY
  then
    sudo rm -f /etc/docker/daemon.json
    if sudo systemctl is-active --quiet docker; then sudo systemctl restart docker; fi
  else
    echo "Mevcut /etc/docker/daemon.json farklı/özelleştirilmiş; korunuyor."
  fi
fi

# Bilinen HomeLab Compose tanımlarını kaldır. Başka isimli projelere dokunma.
for f in \
  "$STACKS/dockge/compose.yaml" \
  "$STACKS/monitoring/compose.yaml" \
  "$STACKS/cloud/compose.yaml" \
  "$STACKS/ai/compose.yaml" \
  "$STACKS/storage/compose.yaml" \
  "$STACKS/web/compose.yaml" \
  "$STACKS/notify/compose.yaml" \
  "$STACKS/adguard/compose.yaml" "$STACKS/adguard/.env" \
  "$STACKS/monitoring-agent/compose.yaml" "$STACKS/monitoring-agent/.env"; do
  STACK_OF="${f#"$STACKS"/}"; STACK_OF="${STACK_OF%%/*}"
  if sudo test -f "/var/lib/homelab-installer/markers/compose-foreign-$STACK_OF"; then continue; fi
  sudo rm -f "$f"
done

# Panel kaynakları kurulum tarafından kopyalanmıştı; kullanıcı verisi dizinleri burada tutulmaz.
# Panel klasörü ayrı onayla silinecek; diğer /srv/homelab içeriğine dokunulmaz.

echo
echo "[4/7] /srv/homelab dosyaları"
read -r -p "/srv/homelab içindeki TÜM dosyalar (appdata, paylaşılan dosyalar, Ollama modelleri, web sitesi ve yerel yedekler dahil) silinsin mi? [e/H]: " WIPE_DATA
if [[ "$WIPE_DATA" =~ ^[EeYy]$ ]]; then
  echo "Bu işlem geri alınamaz. Harici Restic deposu bu klasörün dışındaysa korunur."
  read -r -p "Onaylamak için TAM OLARAK HOMELAB-DATASI-SIL yaz: " WIPE_CONFIRM
  if [[ "$WIPE_CONFIRM" == "HOMELAB-DATASI-SIL" ]]; then
    sudo rm -rf --one-file-system -- "$BASE"
    echo "/srv/homelab tamamen silindi."
  else
    echo "Veri silme onayı eşleşmedi; /srv/homelab korundu."
  fi
else
  # Sadece yönetim paneli kodunu kaldır; appdata/data/web ve özel içerik korunur.
  sudo rm -rf "$BASE/admin-panel"
  sudo rmdir "$STACKS/dockge" "$STACKS/monitoring" "$STACKS/cloud" "$STACKS/ai" \
    "$STACKS/storage" "$STACKS/web" "$STACKS/adguard" "$STACKS/monitoring-agent" "$STACKS/notify" 2>/dev/null || true
  sudo rmdir "$STACKS" 2>/dev/null || true
  echo "Kullanıcı verileri korundu; yalnızca panel ve bilinen Compose tanımları kaldırıldı."
fi

echo
echo "[5/7] İsteğe bağlı sistem paketleri"
cat <<'PKGNOTE'
Aşağıdaki paketler KUR.sh tarafından kurulmuş olabilir. Ancak bunlardan bazıları
önceden de kurulu olabilir. Seçersen Docker, SSH, Samba ve Syncthing gibi sistem
bileşenleri kaldırılır. Özellikle SSH kaldırılırsa uzaktan bağlantın kesilir.
PKGNOTE
read -r -p "Docker, Restic, Samba, Syncthing, OpenSSH, Fail2ban, RustDesk ve Tailscale paketleri de kaldırılsın mı? [e/H]: " PURGE_PACKAGES
if [[ "$PURGE_PACKAGES" =~ ^[EeYy]$ ]]; then
  echo "UYARI: Bu işlem SSH dahil sistem servislerini kaldırabilir. Yerel konsolda olduğundan emin ol."
  read -r -p "Son onay için TAM OLARAK SISTEM-PAKETLERINI-SIL yaz: " PURGE_CONFIRM
  if [[ "$PURGE_CONFIRM" == "SISTEM-PAKETLERINI-SIL" ]]; then
    if sudo test -f /var/lib/homelab-installer/markers/installed-packages; then
      mapfile -t OWN_PACKAGES < <(sudo cat /var/lib/homelab-installer/markers/installed-packages | grep -E '^[a-z0-9][a-z0-9+.-]*$' || true)
      if ((${#OWN_PACKAGES[@]})); then
        printf 'Bu kurulumun eklediği paketler kaldırılacak: %s\n' "${OWN_PACKAGES[*]}"
        sudo apt-get purge -y "${OWN_PACKAGES[@]}" || echo "UYARI: Bazı paketler kaldırılamadı; apt çıktısını kontrol et."
      else
        echo "Bu kurulum tarafından eklenen paket bulunamadı; paketler korunuyor."
      fi
    else
      echo "Paket sahipliği kaydı yok; yanlışlıkla önceden kurulu paketleri silmemek için sistem paketleri korunuyor."
    fi
    if sudo test -f /var/lib/homelab-installer/markers/docker-source-created; then sudo rm -f /etc/apt/sources.list.d/docker.sources; fi
    if sudo test -f /var/lib/homelab-installer/markers/docker-key-created; then sudo rm -f /etc/apt/keyrings/docker.asc; fi
    if sudo test -f /var/lib/homelab-installer/markers/tailscale-source-created; then sudo rm -f /etc/apt/sources.list.d/tailscale.list; fi
    sudo apt-get update || true
  else
    echo "Sistem paketleri korunuyor."
  fi
else
  echo "Sistem paketleri korundu."
fi

echo
sudo rm -rf /var/lib/homelab-installer/markers
sudo rmdir /var/lib/homelab-installer 2>/dev/null || true
echo "[6/7] Son kontrol"
sudo systemctl daemon-reload
if command -v docker >/dev/null 2>&1 && sudo docker info >/dev/null 2>&1; then
  echo "Kalan konteynerler:"
  sudo docker ps -a --format 'table {{.Names}}\t{{.Status}}' || true
else
  echo "Docker etkin değil veya kaldırılmış."
fi
if sudo test -d "$BASE"; then
  echo "Korunan /srv/homelab üst düzey klasörleri:"
  sudo find "$BASE" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort
fi

echo
echo "[7/7] İşlem özeti"
echo "Bilinen HomeLab servisleri ve yönetim paneli kaldırma işleminden geçirildi."
echo "Harici Restic deposu silinmedi. Sistem paketleri seçimine göre korunmuş olabilir."
echo "Kaldırma tamamlandı. Ayrıntı gerekiyorsa terminaldeki çıktıyı paylaş."
