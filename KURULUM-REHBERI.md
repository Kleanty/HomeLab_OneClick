# HomeLab — Kurulum Rehberi

Bu kılavuz, **boş/yeni bir bilgisayara Linux Mint kurduktan sonra** HomeLab paketini kurmak içindir. `KUR.sh`, Linux Mint'i kurmaz; Mint masaüstü açıldıktan sonra Docker ve HomeLab servislerini hazırlar.

## 1. Kuruluma başlamadan önce

### Bilgisayar ve işletim sistemi

- Linux Mint **22.x Cinnamon 64-bit**, Ubuntu 24.04 `noble` tabanı ve `amd64` işlemci gerekir. Başka sürüm/mimari için bu kurulum betiği özellikle durur.
- Linux Mint'i USB'den bilgisayara kur, normal (root olmayan) bir kullanıcı oluştur ve masaüstüne giriş yap.
- İnternet bağlantısı gerekir. Docker, Python paketleri ve konteyner imajları indirilir; indirme süresi bağlantıya göre uzayabilir.
- Kurulum sırasında bilgisayar kapanmamalı ve terminal açık kalmalıdır.
- Kök diskte yaklaşık **10 GiB boş alanın** olması önerilir. Ollama model dosyaları için bunun çok üzerinde ek alan gerekebilir.
- Makineye fiziksel erişimin olsun. Kurulum SSH/Samba servislerini açar ve yeniden başlatma gerektiren ayarlar yapabilir.

### Bu aşamada hazırlaman gerekenler

- HomeLab paneli için kullanıcı adı ve **en az 14 karakterli** güçlü parola.
- Kullanacağın bir kullanıcı adı ve parola (Samba dahil hepsinde aynı parola).
- Restic otomatik yedekleme isteniyorsa, sistem diskinden ayrı bir harici disk. Yedekleme kurulumu ertelenebilir.
- Kurulum başında bir kullanıcı adı ve bir parola sorulur. Parola iki kez girilir; yanlışsa tekrar sorulur. Başka evet/hayır sorusu yoktur.

> Temiz kurulum hedefi seçildiği için mevcut sistem verileri korunacak bir güncelleme senaryosu yoktur. Linux Mint kurulumunda yanlış diski seçmek o diskteki verileri silebilir.

## 2. ZIP'i doğru aç

ZIP'i Linux Mint masaüstünde bir klasöre çıkar. Arşivdeki dosyaların aynı ana klasörde ve klasör yapısıyla kalması gerekir:

```text
HomeLab_OneClick/
├── KUR.sh
├── KURULUM-REHBERI.md
├── KALDIR.sh
├── TANI.sh
├── homelab-docker-control
├── homelab-docker-lan-only
├── homelab-notify
├── homelab-health-check
├── reset-panel-password.sh
├── harden-ssh.sh
├── setup-restic-backup.sh
├── configure-beszel-agent.sh
└── admin-panel/
    ├── app.py
    ├── requirements.txt
    ├── templates/
    └── static/
```

`KUR.sh` dosyasını tek başına başka yere kopyalama; yanındaki yardımcı dosyaları ve `admin-panel/` klasörünü bulması gerekir.

## 3. Kurulumu başlat

Terminali bu klasörde aç. Dosya yöneticisinde klasöre sağ tıklayıp “Terminalde aç” seçeneğini kullanabilir veya Terminal'de klasöre geçebilirsin. Ardından:

```bash
chmod +x KUR.sh
./KUR.sh
```

**`sudo ./KUR.sh` çalıştırma.** Betik normal Linux kullanıcısıyla başlar ve gerektiğinde `sudo` ile yetki ister. Root olarak başlatılırsa bilerek durur.

Ön kontrol başarısız olursa sistemde değişiklik yapmadan durması beklenir. Parolalar alındıktan sonra kurulum 5 saniye sonra başlar; iptal etmek için `Ctrl+C`. Kurulum başladıktan sonra durdurmak için `Ctrl+C` kullanabilirsin.

## 4. Kurulum sırasında sorulacak seçimler

**Kurulum başında sorulanlar:** kullanıcı adı (boş bırakırsan Linux hesap adın; yalnızca harf, rakam, `.` `_` `@` `-`) ve parola (en az 14 karakter, iki kez). Aynı bilgiler panel, RustDesk, ntfy ve Syncthing'e; parola ayrıca Samba'ya (kullanıcı adı Linux hesabı) uygulanır. Dockge, Beszel, Uptime Kuma, n8n ve AdGuard'ın ilk hesabını sen aynı bilgilerle açarsın. File Browser'ın ilk parolası rastgeledir (özet dosyasında).

| Bileşen | Nasıl kurulur |
|---|---|
| Timeshift anlık görüntüsü | Kuruluysa otomatik alınır; alınamazsa uyarı yazılır, kurulum devam eder. |
| Tailscale | Otomatik kurulur; sonundaki özette çıkan bağlantıyı tarayıcıda açıp giriş yaparsın (kurulum beklemez). |
| RustDesk | Resmî GitHub sürümünden indirilir, kurulur, başta verdiğin parola ayarlanır. ID özet dosyasında. |
| Otomatik oturum açma | Otomatik açılır (zaten ayarlıysa dokunulmaz). Monitörsüz sunucuda yeniden başlatma sonrası RustDesk için gerekir. |
| AdGuard Home | Otomatik kurulur; LAN IP otomatik bulunur. Router DNS ayarı değiştirilmez. |
| Ekran kartı / Ollama | Ekran kartı sürücüsü kurulmaz. Ollama CPU üzerinde çalışır. |
| Scrutiny NVMe yetkisi | `SYS_ADMIN` verilmez (güvenli varsayılan). |
| Yönetim paneli | Başta sorulan kullanıcı adı ve parolayla oluşur; parola düz metin saklanmaz. |
| ntfy / Syncthing | Aynı kullanıcı adı ve parolayla hesap/arayüz girişi ayarlanır. |
| Samba | Aynı parola ayarlanır; kullanıcı adı Linux hesabıdır. |
| Restic | Paket kurulur; yedek hedefi harici disk gerektirdiğinden diski bağlayınca `sudo bash /srv/homelab/tools/setup-restic-backup.sh` ile ayarlanır. |

AdGuard veya Restic gibi isteğe bağlı adımlar atlanırsa ana kurulum devam eder.

## 5. KUR.sh neler yapıyor?

Kurulum, aşağıdaki sırayla ilerler. Bir adımda kritik hata oluşursa betik hatayı kayda geçirip durur; sonraki aşamalara geçmez.

1. **Ön kontrol:** Linux Mint sürümü ve `amd64` mimarisini doğrular; gerekli komutları ve ZIP içindeki dosyaları kontrol eder; boş disk ve olası port çakışmalarını bildirir.
2. **Temel paketler:** Python/venv, Samba, Syncthing, OpenSSH, UFW paketi, Restic, Fail2ban ve disk/sensör teşhis araçlarını kurar. UFW kurulur ama otomatik etkinleştirilmez.
3. **Docker:** Docker Engine/Compose'u kurup servisi başlatır. Kullanıcıyı `docker` grubuna ekler ve yalnızca yeni kurulumda Docker log rotasyonu varsayılanını yazar. Docker grubu yüksek ayrıcalıktır.
4. **Uzaktan araçlar:** Tailscale ve RustDesk otomatik kurulur. Ayrıca uyku modu kilitlenir (sunucu uyumasın) ve otomatik oturum açma ayarlanır.
5. **İsteğe bağlı yerel DNS:** AdGuard Home için LAN IP'sini doğrular. Router veya istemcilerin DNS ayarını kendisi değiştirmez.
6. **Temel servisler:** Kullanıcı systemd oturumunu açılışta çalışabilecek şekilde ayarlar (linger), Syncthing, SSH, Samba ve mDNS servisini etkinleştirir. Cinnamon güç düğmesi ayarı için önceki değeri kaydetmeye çalışır.
7. **Dizinler ve Compose tanımları:** `/srv/homelab` altında verileri, uygulama ayarlarını ve Compose dosyalarını hazırlar. Var olan Compose dosyalarının üstüne yazmaz. Dockge, Beszel, Uptime Kuma, File Browser, Ollama+n8n, Scrutiny ve localhost başlangıç sitesi oluşturulur; AdGuard ve Beszel Agent isteğe bağlı/ayrı yapılandırılır.
8. **Konteynerler ve yerel AI:** Compose dosyaları doğrulanıp başlatılır. Bir stack başlamazsa kurulum durmaz, son ekrandaki uyarı listesine yazılır. RAM'den bağımsız olarak ilk kurulumda `qwen2.5:1.5b-instruct-q4_K_M` indirilir (model dosyası yaklaşık 986 MB, CPU'da çalışır). Yalnızca 2 GiB altı boş depolamada indirme atlanıp uyarı verilir.
9. **Özel yönetim paneli:** Flask/Waitress sanal ortamını kurar; kullanıcı adı, parola hash'i ve gizli anahtarı oluşturur.
10. **Sınırlı Docker yöneticisi:** Panelin doğrudan Docker socket kullanması yerine sabit servis/işlem allowlist'i olan root sahipli helper kurar. Sol menüdeki salt okunur konsol sabit durum raporlarını gösterir; keyfî shell, terminal veya PowerShell komutu kabul etmez.
11. **Panel servisi:** Yönetim panelini systemd ile başlatır; yalnızca `127.0.0.1:8000` üzerinde dinler.
12. **Samba ve yedekleme:** Samba kullanıcısını aynı parolayla hazırlar ve Restic paketini kurar. Yedek, harici disk gerektirdiğinden `setup-restic-backup.sh` ayrıca çalıştırılır.
13. **Sonuç:** Servis erişim adreslerini, durum kontrol komutlarını ve güvenlik uyarılarını gösterir. İsteğe bağlı bileşenlerden biri başarısız olduysa ayrı uyarı listeler.

## 6. Kurulumun oluşturduğu ana alanlar

| Yol | İçerik |
|---|---|
| `/srv/homelab/compose/` | Docker Compose servis tanımları |
| `/srv/homelab/appdata/` | Konteynerlerin kalıcı yapılandırma/verileri |
| `/srv/homelab/data/` | Paylaşılan belgeler, projeler ve medya |
| `/srv/homelab/web/public/` | Başlangıç web sayfası dosyaları |
| `/srv/homelab/admin-panel/` | Flask yönetim paneli kaynakları ve sanal ortamı |
| `/srv/homelab/tools/` | Beszel Agent ve Restic yardımcıları |
| `~/HomeLab_Logs/` | Kurulum, tanı ve yardımcı işlem günlükleri |

Panel parolası `.env` içinde Werkzeug hash'i olarak saklanır. Gerçek `.env` dosyasını veya Restic parolasını kimseyle paylaşma.

## 7. Başarılı kurulumdan sonra

Kurulum tamamlandığında önce yerel servisleri kontrol et:

```bash
sudo docker ps
sudo docker compose ls --all
sudo systemctl status homelab-admin-panel --no-pager
sudo systemctl status docker ssh smbd fail2ban --no-pager
```

Temel adresler:

| Uygulama | Adres |
|---|---|
| Panel | `http://127.0.0.1:8000` — yalnızca sunucuda |
| Dockge | `http://SUNUCU-IP:5001` |
| Beszel | `http://SUNUCU-IP:8090` |
| Uptime Kuma | `http://SUNUCU-IP:3001` |
| Scrutiny | `http://SUNUCU-IP:8081` |
| File Browser | `http://SUNUCU-IP:8080` |
| n8n | `http://SUNUCU-IP:5678` |
| Ollama API | `http://127.0.0.1:11434` |
| Başlangıç sitesi | `http://127.0.0.1:8088` |

`SUNUCU-IP` yerine Linux Mint bilgisayarının o anki yerel ağ IP adresini yaz. Ev bağlantısında sabit **genel** IP gerekmez: ileride kurulacak Cloudflare Tunnel sunucudan dışarı bağlantı kurar. Ancak Tunnel/Access bu pakette kurulmaz; alan adının Cloudflare DNS'inde olması, token ve hostname eşlemesi gerekir. Yerel IP DHCP ile değişebilir; router'da DHCP rezervasyonu isteğe bağlıdır. mDNS destekleyen ağ cihazlarında `http://bilgisayar-adi.local:8090` biçimindeki yerel ad kullanılabilir. Paneli başka cihazdan doğrudan açamazsın; bu kasıtlı güvenlik sınırıdır.

İlk kurulumdan sonra:

1. Beszel Hub'da yönetici hesabı oluştur, **Add System** ile KEY/TOKEN al ve `bash /srv/homelab/tools/configure-beszel-agent.sh` aracını çalıştır.
2. Uptime Kuma'da izlemek istediğin uygulamaları tanımla.
3. Harici yedek diski hazırladıktan sonra `sudo bash /srv/homelab/tools/setup-restic-backup.sh` ile Restic'i ayrıca yapılandır. İlk yedeği ve geri yükleme testini yap.
4. Paneli dışarı açmadan önce Cloudflare Tunnel ve `panel` hostname'inin tamamını kapsayan Cloudflare Access politikası ayrı yapılandırılmalıdır. Bu paket Cloudflare hesabına veya DNS'e bağlanmaz.
5. Router'da servis portlarını internete yönlendirme. Docker yayınladığı portlar UFW'yi atlayabilir.

## 8. Hata olursa: ne yapmalı?

### Kurulum betiği hata yakalama

`KUR.sh`, kritik Bash hatalarında otomatik olarak hata yakalama fonksiyonuna girer. Terminalde:

- hata satırını,
- çıkış kodunu,
- başarısız komutu,
- ayrıntılı günlük dosyasının yolunu

gösterir. Ana kurulum günlüğü normal kullanıcı hesabında `~/HomeLab_Logs/kurulum-YYYYMMDD-HHMMSS.log` konumuna yazılır. Kurulum tamamlanmadı mesajı görürsen bunu başarılı kurulum sayma.

Kurulumu `Ctrl+C` ile kesersen günlükte işlemin kullanıcı tarafından durdurulduğu yazılır. Yarım kalan sistem değişiklikleri otomatik silinmez; veriyi korumak için bu kasıtlıdır.

Tailscale, RustDesk ve Restic gibi **isteğe bağlı** kurulum adımları bazı hatalarda ana kurulumu durdurmadan atlanabilir. Böyle bir durumda son ekranda `UYARILAR` listesi gösterilir. “Kurulum tamamlandı” yazısını görsen bile uyarı listesini okuyup o bileşenin kurulup kurulmadığını kontrol et.

Günlüğü açmak için:

```bash
ls -lt ~/HomeLab_Logs/
less ~/HomeLab_Logs/kurulum-*.log
```

`less` içinden çıkmak için `q` tuşuna bas. Günlüğü destek için paylaşmadan önce kullanıcı adı, yerel IP, makine adı ve özel bilgileri gözden geçir.

### İlk tanı adımı

Kurulum yarıda kalırsa bu sırayı izle:

1. **`KALDIR.sh` çalıştırma ve `/srv/homelab` klasörünü silme.** Kurulum betiği arıza durumunda verileri otomatik silmez; bu koruyucu davranıştır. Yarım kalan paketleri veya servisleri hemen kaldırmaya çalışma.
2. Terminalde gösterilen ilk `HATA` satırını ve `Ayrıntılı günlük` yolunu not et. Günlükte genellikle asıl hata, daha sonra görünen hata yakalama satırından önce bulunur.
3. Günlüğün son kısmını aç:

   ```bash
   ls -lt ~/HomeLab_Logs/kurulum-*.log | head
   tail -n 120 ~/HomeLab_Logs/kurulum-EN_SONKI.log
   ```

   `kurulum-EN_SONKI.log` yerine `ls` çıktısındaki gerçek dosya adını yaz.
4. Tanı raporu al:

```bash
bash TANI.sh
```

Tanı raporu `~/HomeLab_Logs/tani-*.txt` altına yazılır. Rapor sistem, başarısız systemd servisleri, Docker/konteynerler, Compose dosyası doğrulaması, izlenen portlar ve Restic durumunu toplar. Parola ve tokenları yazdırmaması hedeflenmiştir; paylaşmadan önce yine de içeriği kontrol et.

5. Hata internet/indirme veya geçici APT kilidi gibi düzeltilebilir bir nedense, interneti düzeltip diğer paket yöneticisi işlemlerinin bitmesini bekle. Ardından **aynı çıkarılmış paketin içinden** normal kullanıcı olarak `./KUR.sh` komutunu yeniden başlat. Bu temiz kurulum senaryosunda tekrar deneme, eksik paket adımlarını tamamlar; mevcut `/srv/homelab` verisini ve panel `.env` parolasını otomatik silmez. Mevcut Compose projelerini yeniden doğrulayıp `up -d` ile başlatır. Bu yüzden tekrar deneme öncesi `TANI.sh` ve günlük çıktısını kontrol et; bilinmeyen bir hata varsa önce destek al.
6. Tekrar çalıştırmada aynı hata olursa tekrar tekrar denemeyi bırak. İlk hata mesajı, son 100-120 günlük satırı, `bash TANI.sh` sonucu ve bilgisayarın Linux Mint sürümünü paylaş. `.env`, parola, token veya Restic parola dosyasını paylaşma.

**Restic özel durumu:** Restic adımı ana kurulumdan ayrı çalışır. `setup-restic-backup.sh` parola/depo ayarlarını oluşturmaya başladıktan sonra hata verirse aynı yardımcı mevcut `/etc/restic` dosyalarını korumak için tekrar çalışmayı reddedebilir. Bu durumda depo veya `/etc/restic` içeriğini silme; `sudo tail -n 120 /var/log/homelab-installer-restic-setup.log` çıktısındaki gizli bilgileri kontrol et ve önce yardım al. Harici depo parolasını kaybetme.

### Servis günlüklerini kontrol et

```bash
sudo journalctl -u homelab-admin-panel -n 100 --no-pager
sudo journalctl -u docker -n 100 --no-pager
sudo docker ps -a
sudo docker compose -f /srv/homelab/compose/monitoring/compose.yaml logs --tail 100
```

Docker konteyneri başlamıyorsa önce `sudo docker ps -a` ve `docker compose ... logs` çıktısına bak. Panel açılmıyorsa panel systemd günlüğünü ve `sudo systemctl status homelab-admin-panel --no-pager` çıktısını kontrol et.

### Otomatik geri alma neden yapılmıyor?

Kurulum; APT paketleri, servisler, Docker konteynerleri, Samba paylaşımı, panel parolası ve olası harici Restic deposu gibi farklı alanlarda değişiklik yapar. Hata anında hepsini otomatik kaldırmak, çalışan Docker verisini, daha önceki ayarları veya yedek deposunu silebilir. Bu nedenle betik **otomatik rollback yapmaz**; yapılanları ve hatayı günlüğe kaydeder, veriyi korur. Temiz Linux kurulumu olduğu için çoğu geçici hatada çözüm, hatayı düzeltip `./KUR.sh` dosyasını yeniden çalıştırmaktır. Yalnızca Restic parola/depo adımı yarım kaldıysa önce destek al; dosyaları silerek “temizleme” yapma.

Docker, SSH, Samba veya DNS port çakışmasında hangi sürecin portu kullandığını belirlemeden servisi durdurma veya portu değiştirme.

## 9. Dış erişim ve güvenlik

- Panel `127.0.0.1:8000` ile sınırlıdır; UFW'yi açarak paneli dışarı yayınlama.
- Genel bir web sitesi ile özel panel farklı hostname'lerde olmalıdır. Örnek: genel `example` sitesi ve `panel.` alt alan adı.
- Dış erişim ancak HTTPS, Cloudflare Tunnel ve panel hostname'ini kapsayan Cloudflare Access ile planlanmalıdır. Access uygulaması olmadan Tunnel oluşturmak tek başına kullanıcı kimlik doğrulaması sağlamaz.
- Docker port kilidi (`homelab-docker-lan-only`) internetten gelen yeni bağlantıları Docker portlarında engeller; bu yine de router yönlendirmesi yapmaman gerektiği gerçeğini değiştirmez. Durumu: `sudo iptables -S HOMELAB-LAN-ONLY` ve `sudo systemctl status homelab-docker-lan-only`.
- Dockge, n8n, File Browser ve Docker API'sine erişim yüksek etki yaratabilir. Router port yönlendirmesi yapma.
- `KALDIR.sh` ayrı, yıkıcı sonuçları olabilecek bir araçtır. Kurulum için çalıştırılmaz. Verileri silme seçeneği ayrıca güçlü onay ister; emin değilsen kullanma.

## 10. Bu paketin yapmadıkları

- Linux Mint'i USB'ye yazmaz veya işletim sistemini kurmaz.
- Alan adı, DNS, Cloudflare Tunnel, Cloudflare Access veya router ayarlarını değiştirmez.
- Genel portfolyo sitesi, blog, yorum sistemi veya proje deposu arayüzü oluşturmaz; yalnızca başlangıç web sayfası koyar.
- Panelden genel terminal/PowerShell erişimi vermez.
- Ekran kartı (NVIDIA) sürücüsü ve GPU hızlandırma kurmaz; Ollama CPU üzerinde çalışır.
- İlk kurulumda RAM'den bağımsız `qwen2.5:1.5b-instruct-q4_K_M` (yaklaşık 986 MB model dosyası) indirilir; 2 GiB altı boş alan varsa atlanır ve uyarı gösterilir. Daha sonra başka bir modeli elle ekleyebilirsin. Ollama modelini indirmek için kullanıcı token'ı gerekmez.
- Ollama yanıt hızı işlemciye ve RAM miktarına bağlıdır; model çok yavaşsa daha küçük bir model elle eklenebilir.
- UPS/NUT veya yönlendirici DNS ayarı yapmaz.
- Gerçek sunucuda çalıştırılmadan donanım uyumu, SMART geçişi, yedek diskin açılışta bağlanması veya Cloudflare dış erişimi garanti edilemez.
