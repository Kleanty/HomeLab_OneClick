#!/usr/bin/env bash
# SSH'ı anahtar tabanlı girişe geçirir (parola girişini kapatır). Kendini kilitlememen için adım adım doğrulatır.
# Kullanım: bash harden-ssh.sh        (uygula)
#           bash harden-ssh.sh --geri-al   (parola girişini geri aç)
set -Eeuo pipefail
if [[ $EUID -eq 0 ]]; then echo "sudo ile değil, normal kullanıcıyla çalıştır." >&2; exit 1; fi
CONF=/etc/ssh/sshd_config.d/10-homelab-hardening.conf
command -v sshd >/dev/null 2>&1 || [[ -x /usr/sbin/sshd ]] || { echo "OpenSSH sunucusu kurulu değil." >&2; exit 1; }

if [[ "${1:-}" == "--geri-al" ]]; then
  sudo rm -f "$CONF"
  sudo /usr/sbin/sshd -t
  sudo systemctl reload ssh
  echo "SSH sertleştirme ayarı kaldırıldı; parola girişi eski haline döndü."
  exit 0
fi

AUTH="$HOME/.ssh/authorized_keys"
if [[ ! -s "$AUTH" ]] || ! grep -Eq '(^|[[:space:]])(ssh-ed25519|ssh-rsa|ecdsa-sha2-|sk-ssh-ed25519|sk-ecdsa-sha2-)' "$AUTH"; then
  cat <<MSG
Bu kullanıcıda kayıtlı SSH anahtarı yok ($AUTH). Parola girişini şimdi kapatırsan kilitlenirsin.
Önce anahtarını ekle. Girişe kullanacağın bilgisayarda (Linux/macOS/Windows PowerShell):

  ssh-keygen -t ed25519            # anahtar yoksa
  ssh-copy-id $(id -un)@$(hostname -s).local    # Windows'ta: anahtarı elle authorized_keys'e ekle

Sonra bu betiği tekrar çalıştır.
MSG
  exit 1
fi
# StrictModes: izinler yanlışsa anahtar girişi sessizce reddedilir.
[[ "$(stat -c %a "$HOME/.ssh")" =~ ^7[0-5]0$|^700$ ]] || { echo "UYARI: ~/.ssh izni 700 olmalı: chmod 700 ~/.ssh" >&2; exit 1; }
[[ "$(stat -c %a "$AUTH")" =~ ^[46]00$ ]] || { echo "UYARI: authorized_keys izni 600 olmalı: chmod 600 $AUTH" >&2; exit 1; }

cat <<MSG
Kayıtlı anahtar sayısı: $(grep -Ec '(^|[[:space:]])(ssh-ed25519|ssh-rsa|ecdsa-sha2-|sk-ssh-ed25519|sk-ecdsa-sha2-)' "$AUTH")

ÖNEMLİ: Bu pencereyi KAPATMADAN, başka bir bilgisayardan (veya yeni terminalden)
ANAHTARLA giriş yapabildiğini test et:  ssh $(id -un)@$(hostname -s).local
MSG
read -r -p "Anahtarla girişin çalıştığını doğrulamak için ANAHTAR-CALISIYOR yaz: " OK
[[ "$OK" == "ANAHTAR-CALISIYOR" ]] || { echo "İptal edildi; hiçbir şey değişmedi."; exit 0; }

sudo install -d -m 0755 /etc/ssh/sshd_config.d
sudo tee "$CONF" >/dev/null <<'CFG'
# HomeLab: anahtar tabanlı SSH. Geri almak için: bash harden-ssh.sh --geri-al
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
CFG
if ! sudo /usr/sbin/sshd -t; then
  sudo rm -f "$CONF"
  echo "sshd yapılandırması geçersiz çıktı; değişiklik geri alındı." >&2
  exit 1
fi
sudo systemctl reload ssh
# Başka bir sshd_config.d dosyası önce geliyorsa ayarımız etkisiz kalır; gerçek etkin değeri doğrula.
if ! sudo /usr/sbin/sshd -T | grep -qi '^passwordauthentication no$'; then
  sudo rm -f "$CONF"
  sudo systemctl reload ssh
  echo "HATA: PasswordAuthentication etkin değer olarak 'no' olmadı (başka bir ayar dosyası öncelikli olabilir); değişiklik geri alındı." >&2
  exit 1
fi
echo "Etkin ayar: $(sudo /usr/sbin/sshd -T | grep -i '^passwordauthentication')"
echo "Parola girişi kapatıldı. Mevcut oturumunu açık tut ve yeni bir pencereden tekrar anahtarla bağlanmayı dene."
echo "Sorun olursa (yerel konsoldan): bash $0 --geri-al"
