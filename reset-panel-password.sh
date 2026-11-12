#!/usr/bin/env bash
# Yönetim paneli parolasını unutursan: bash /srv/homelab/tools/reset-panel-password.sh
set -Eeuo pipefail
if [[ $EUID -eq 0 ]]; then echo "sudo ile değil, normal kullanıcıyla çalıştır." >&2; exit 1; fi
APP=/srv/homelab/admin-panel
[[ -f "$APP/.env" && -x "$APP/.venv/bin/python" ]] || { echo "Panel kurulu görünmüyor ($APP). Önce KUR.sh çalıştır." >&2; exit 1; }
cd "$APP"
.venv/bin/python - <<'PY'
import getpass, os, tempfile
from pathlib import Path
from werkzeug.security import generate_password_hash
p = getpass.getpass("Yeni panel parolası (en az 14 karakter): ")
q = getpass.getpass("Parolayı tekrar girin: ")
if len(p) < 14: raise SystemExit("Parola en az 14 karakter olmalı.")
if p != q: raise SystemExit("Parolalar eşleşmiyor.")
env = Path(".env")
lines = env.read_text(encoding="utf-8").splitlines()
new_line = "ADMIN_PASSWORD_HASH=" + generate_password_hash(p)
out, done = [], False
for line in lines:
    if line.startswith("ADMIN_PASSWORD_HASH="):
        out.append(new_line); done = True
    else:
        out.append(line)
if not done: out.append(new_line)
fd, tmp = tempfile.mkstemp(dir=".", prefix=".env.")
try:
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write("\n".join(out) + "\n")
    os.replace(tmp, env)
finally:
    if os.path.exists(tmp): os.unlink(tmp)
print("Yeni parola hash'i .env dosyasına yazıldı.")
PY
rm -f instance/login-attempts.sqlite3
sudo systemctl restart homelab-admin-panel.service
echo "Panel yeniden başlatıldı; giriş denemesi sayaçları sıfırlandı. Yeni parolayla giriş yapabilirsin."
