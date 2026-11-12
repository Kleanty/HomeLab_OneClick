#!/usr/bin/env bash
set -Eeuo pipefail
if [[ $EUID -eq 0 ]]; then
  echo "Bu aracı sudo ile değil normal kullanıcıyla çalıştır: bash TANI.sh" >&2
  exit 1
fi
LOG_DIR="$HOME/HomeLab_Logs"
mkdir -p "$LOG_DIR"
chmod 0700 "$LOG_DIR"
REPORT="$LOG_DIR/tani-$(date +%Y%m%d-%H%M%S).txt"
exec > >(tee "$REPORT") 2>&1
trap 'rc=$?; echo "TANI HATASI: satır $LINENO, çıkış kodu $rc, komut: $BASH_COMMAND" >&2; echo "Rapor: $REPORT" >&2; exit "$rc"' ERR

BASE=/srv/homelab
STACKS="$BASE/compose"

echo "HOMELAB - OTOMATİK TANI RAPORU"
echo "Tarih: $(date --iso-8601=seconds)"
echo "Bilgisayar: $(hostname)"
echo "Kullanıcı: $(id -un)"
echo "Rapor: $REPORT"
echo
sudo -v

section() { printf '\n========== %s ==========\n' "$1"; }
section "SİSTEM"
cat /etc/os-release | grep -E '^(PRETTY_NAME|VERSION_CODENAME)=' || true
uname -a
df -h /
free -h

section "BAŞARISIZ SYSTEMD SERVİSLERİ"
systemctl --failed --no-pager || true

section "TEMEL SERVİSLER"
for unit in docker ssh smbd fail2ban avahi-daemon "syncthing@$(id -un)" homelab-admin-panel homelab-docker-lan-only; do
  printf '\n--- %s ---\n' "$unit"
  systemctl is-active "$unit" 2>/dev/null || true
  systemctl is-enabled "$unit" 2>/dev/null || true
done

section "UYKU ENGELİ"
systemctl is-enabled sleep.target suspend.target hibernate.target 2>/dev/null || true
if [[ -f /etc/systemd/logind.conf.d/91-homelab-installer-no-sleep.conf ]]; then echo "logind uyku engeli: var"; else echo "logind uyku engeli: yok"; fi

section "DOCKER"
if command -v docker >/dev/null 2>&1 && sudo docker info >/dev/null 2>&1; then
  sudo docker version --format 'Client={{.Client.Version}} Server={{.Server.Version}}' 2>&1 || true
  sudo docker compose version 2>&1 || true
  sudo docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' || true
else
  echo "Docker kurulu değil veya daemon çalışmıyor."
fi

section "DONANIM VE OLLAMA"
if command -v lspci >/dev/null 2>&1; then
  lscpu | grep -E '^(Model name|CPU\(s\)):' | head -n 2 || true
  free -h | awk 'NR == 2 {print "RAM: " $2}'
  lspci -nn | grep -Ei 'VGA compatible controller|3D controller|Display controller' || echo "Ekran kartı PCI listesinde bulunamadı."
fi
if sudo docker inspect ollama >/dev/null 2>&1; then
  sudo docker exec ollama ollama list 2>&1 || true
else
  echo "Ollama konteyneri çalışmıyor."
fi

section "DOCKER PORT KİLİDİ (LAN-ONLY)"
sudo iptables -w -S HOMELAB-LAN-ONLY 2>&1 | head -n 12 || echo "Kilit zinciri yok (homelab-docker-lan-only etkin değil)."

section "COMPOSE DOSYALARI"
for stack in dockge monitoring cloud ai storage web adguard monitoring-agent notify; do
  file="$STACKS/$stack/compose.yaml"
  [[ -f "$file" ]] || { echo "$stack: dosya yok (isteğe bağlı/henüz oluşturulmamış olabilir)"; continue; }
  echo -n "$stack: "
  if [[ -f "$STACKS/$stack/.env" ]]; then
    if sudo docker compose --env-file "$STACKS/$stack/.env" -f "$file" config -q >/dev/null 2>&1; then echo "YAML/Compose OK"; else echo "HATA - docker compose config başarısız"; fi
  else
    if sudo docker compose -f "$file" config -q >/dev/null 2>&1; then echo "YAML/Compose OK"; else echo "HATA - docker compose config başarısız veya .env eksik"; fi
  fi
done

section "PORT DİNLEYİCİLERİ"
ss -Hlnptu 2>/dev/null | grep -E ':(22|53|80|443|3000|3001|3002|5001|5678|8080|8081|8088|8090|2586|45876)([[:space:]]|$)' || echo "İzlenen portlarda dinleyici bulunamadı veya ss bilgisi kısıtlı."

section "RESTIC"
if command -v restic >/dev/null 2>&1; then
  restic version
else
  echo "Restic kurulu değil."
fi
for unit in homelab-restic-backup.timer homelab-restic-check.timer homelab-health-check.timer; do
  printf '%s: ' "$unit"
  systemctl is-active "$unit" 2>/dev/null || true
done
if sudo test -f /etc/restic/homelab.env; then
  echo "Restic yapılandırması mevcut (parola/depo yolu rapora yazdırılmadı)."
else
  echo "Restic deposu henüz yapılandırılmamış."
fi

section "BESZEL AGENT"
if sudo docker inspect beszel-agent >/dev/null 2>&1; then
  sudo docker inspect --format 'Durum={{.State.Status}}' beszel-agent || true
else
  echo "Agent henüz kurulmamış; Hub'da Add System sonrası configure-beszel-agent.sh çalıştır."
fi

echo
echo "TANI TAMAMLANDI. Rapor: $REPORT"
echo "Bu rapor parola/token değerlerini özellikle yazdırmaz. Paylaşmadan önce yerel IP ve bilgisayar adını gözden geçir."
