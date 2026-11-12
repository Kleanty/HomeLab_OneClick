#!/usr/bin/env bash
set -Eeuo pipefail
LOG_DIR="$HOME/HomeLab_Logs"
mkdir -p "$LOG_DIR"
chmod 0700 "$LOG_DIR"
LOG_FILE="$LOG_DIR/beszel-agent-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
trap 'rc=$?; echo "HATA: Beszel Agent ayarı satır $LINENO üzerinde durdu (çıkış kodu: $rc). Komut: $BASH_COMMAND. Günlük: $LOG_FILE" >&2; exit "$rc"' ERR
BASE=/srv/homelab
STACK="$BASE/compose/monitoring-agent"

if [[ $EUID -eq 0 ]]; then
  echo "Bu aracı sudo ile değil normal kullanıcıyla çalıştır: bash configure-beszel-agent.sh" >&2
  exit 1
fi
[[ -f "$STACK/compose.yaml" ]] || { echo "Agent Compose dosyası bulunamadı. Önce KUR.sh çalıştır." >&2; exit 1; }
command -v docker >/dev/null || { echo "Docker bulunamadı." >&2; exit 1; }

if sudo test -e "$STACK/.env"; then
  echo "Mevcut Beszel Agent kimlik bilgileri bulundu."
  read -r -p "Bu kimlik bilgileri değiştirilsin mi? [e/H]: " REPLACE
  [[ "$REPLACE" =~ ^[EeYy]$ ]] || { echo "Mevcut dosya korundu; işlem iptal edildi."; exit 0; }
fi

cat <<'MSG'
BESZEL AGENT BAĞLANTISI
----------------------
Önce Beszel Hub'ı aç: http://SUNUCU-IP:8090
Add System bölümünde yeni sistem oluştur ve ekranda verilen KEY ve TOKEN değerlerini al.
Bu araç o değerleri korumalı .env dosyasına yazar ve Agent konteynerini başlatır.
MSG
read -r -p "Beszel Hub'daki KEY: " KEY
read -r -s -p "Beszel Hub'daki TOKEN: " TOKEN; echo
[[ -n "$KEY" && -n "$TOKEN" ]] || { echo "KEY ve TOKEN boş olamaz." >&2; exit 1; }
case "$KEY$TOKEN" in
  *'"'*|*'\'*|*'$'*|*$'\n'*)
    echo "KEY/TOKEN beklenmeyen karakter içeriyor. Hub'dan tekrar kopyala." >&2
    exit 1
    ;;
esac
TMP_ENV="$(mktemp)"
trap 'rm -f "$TMP_ENV"' EXIT
chmod 0600 "$TMP_ENV"
printf 'BESZEL_AGENT_KEY="%s"\nBESZEL_AGENT_TOKEN="%s"\n' "$KEY" "$TOKEN" > "$TMP_ENV"
sudo install -o root -g root -m 0600 "$TMP_ENV" "$STACK/.env"
rm -f "$TMP_ENV"
trap - EXIT
unset KEY TOKEN
cd "$STACK"
sudo docker compose -f compose.yaml config -q
sudo docker compose --progress quiet -f compose.yaml up -d --quiet-pull

# Add Agent to the private panel's allowlisted service list only after credentials exist.
ADMIN_SERVICES="$BASE/admin-panel/instance/admin-services.json"
if [[ -f "$ADMIN_SERVICES" ]]; then
  python3 - "$ADMIN_SERVICES" <<'PY_REGISTER'
import json, os, sys, tempfile
from pathlib import Path
p=Path(sys.argv[1])
try:
    data=json.loads(p.read_text(encoding="utf-8"))
except Exception as exc:
    print(f"Panel servis listesi okunamadı; Agent çalışıyor ancak panele eklenemedi: {exc}")
    raise SystemExit(0)
if not any(x.get("id") == "beszel-agent" for x in data):
    data.append({
        "id":"beszel-agent", "label":"Beszel Agent", "container":"beszel-agent",
        "compose_file":"/srv/homelab/compose/monitoring-agent/compose.yaml",
        "compose_service":"beszel-agent", "actions":["start", "stop", "restart"]
    })
    fd, tmp=tempfile.mkstemp(prefix=".admin-services-", dir=p.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
            f.write("\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, p)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
PY_REGISTER
fi

echo
echo "Agent konteyneri başlatıldı. Beszel Hub'daki sistem kaydında bu sunucunun LAN IP adresini ve 45876 portunu kullan."
echo "Beszel Agent günlüğü: $LOG_FILE"
echo "Durum: sudo docker ps --filter name=beszel-agent"
