# HomeLab ve yönetim paneli inceleme notları

## Panelin gerçek kapsamı

- Flask paneli giriş, CSRF, oturum güvenliği ve SQLite tabanlı giriş deneme sınırı içerir.
- Servis durumu, son Docker günlükleri ve izin verilen başlat/durdur/yeniden başlat işlemleri sabit `homelab-docker-control` yardımcısından gelir.
- Flask süreci Docker soketine doğrudan bağlanmaz; helper sabit servis kimlikleri ve işlemler kullanır.
- Panel n8n çalışma geçmişi veya genel terminal/PowerShell erişimi sağlamaz. Salt okunur konsol yalnızca sabit host ve servis durum raporlarını görüntüler.
- Genel portfolyo sitesi, Cloudflare Tunnel/Access, DNS ve HTTPS bu pakette tamamlanmış değildir.

## Düzeltmeler

1. Restic haftalık `check` unit'i `ProtectSystem=strict` ile çalışırken `RESTIC_CACHE_DIR` için yazma iznine sahip değildi. Unit'e `/var/lib/homelab-restic/cache` yazma izni eklendi.
2. `admin-panel/install.sh` eski systemd-user paneline aitti; oluşturduğu servis JSON'u ve kurulum modeli mevcut Docker-helper tabanlı `app.py` ile uyumlu değildi. Yanlış kurulum yolu kaldırıldı. Bu panel yalnızca üst klasördeki `KUR.sh` tarafından kurulur.
3. Önceki inceleme metni güncel kodla uyuşmuyordu; panelin yalnızca systemd-user servisi yönettiği yönündeki yanlış anlatım bu notla değiştirildi.
4. Kaldırma betiği artık yalnızca HomeLab kurulumu sırasında eklenmiş Docker grup üyeliğini kaldırır; önceden var olan üyelik korunur.
5. Ana kurulum için ilk kurulum rehberi eklendi; kritik hatalar günlük/komut bilgisiyle raporlanıyor, Ctrl+C/TERM durdurmaları da kayıt altına alınıyor. Restic yardımcısında root yetkisi doğrulanmadan `/var/log` dosyası açılmaya çalışılması düzeltildi.
6. İsteğe bağlı kurulum soruları tutarlı hâle getirildi: `e`=Evet, `h`/Enter=Hayır; geçersiz cevap tekrar sorulur. Başarısız isteğe bağlı kurulumlar son ekranda listelenir. Rehbere kurulum yarıda kalınca izlenecek güvenli teşhis ve tekrar deneme adımları eklendi.
7. İlk kurulum modeli RAM'e göre değiştirilmez: her kurulum açıkça `qwen2.5:1.5b-instruct-q4_K_M` (resmî kütüphane dosya boyutu yaklaşık 986 MB) indirir ve CPU üzerinde çalıştırır. Yalnızca HomeLab diskinde 2 GiB'tan az boş alan varsa indirme atlanır ve uyarı yazılır.
8. **NVIDIA sürücüsü / GPU yapılandırması paketten tamamen çıkarıldı** (hata veriyordu): `ubuntu-drivers`, NVIDIA Container Toolkit, Docker GPU runtime, `configure-ollama-gpu.sh` (ayrıca CRLF satır sonu yüzünden bash'te sözdizimi hatası veriyordu), GPU systemd görevi ve KALDIR/TANI içindeki GPU adımları kaldırıldı. Ollama CPU ile çalışır.
9. Sabit public IP olmadan dış erişim için Cloudflare Tunnel'ın uygun olduğu belgelenmiştir; bu paket Cloudflare hesabı, DNS, Tunnel token'ı veya Access politikasını kurmaz. Yerel ağ `.local` adı için Avahi/mDNS denenir; DHCP rezervasyonu isteğe bağlıdır.
10. Panel ana sayfası koyu, sol gezinmeli bir sunucu özet ekranı olarak yenilendi. CPU/RAM, disk ve uptime metrikleri, konteyner başlat/durdur/yeniden başlatma ve log bağlantıları, Docker/SSH/Samba/Fail2ban/mDNS/Syncthing durumları ile Restic zamanlayıcı ve son yedek çalışma bilgisi eklendi. Terminal/serbest komut arayüzü yoktur.
11. Sol menüye salt okunur sunucu konsolu eklendi. Sabit rapor yalnızca host ve allowlist servis durumlarını okur; kullanıcı komutu, PowerShell/Bash girdisi veya sistemde değişiklik yolu sunmaz.
12. **Panel yedek durumu hiç görünmüyordu:** `panel.html` içindeki `{% set backup = ... %}` satırı, uygulamanın gönderdiği yedek bilgisini (`result`, `last_run`) ezip siliyordu; başarılı yedekte bile "yedek kaydı yok" yazıyordu. Satır kaldırıldı, testi eklendi.
13. **Kurulum tek bir Docker hatasında tamamen duruyordu:** bir imaj indirilemezse/port çakışırsa panel, sudoers ve Samba adımlarına hiç geçilmiyordu. Artık her stack ayrı denenir; başarısız olan uyarı listesine yazılır.
14. **Paket sahipliği kaydı yanlış çıkıyordu:** `preexisting-packages` dosyası root-only olduğu için normal kullanıcıyla okunamıyor, bu yüzden önceden kurulu paketler "bu kurulum ekledi" diye kaydedilip KALDIR.sh paket silmede kaldırılabiliyordu. `sudo grep` ile düzeltildi.
15. **n8n `http://SUNUCU-IP:5678` adresinden giriş yapılamıyordu** ("secure cookie" hatası). Compose'a `N8N_SECURE_COOKIE: "false"` eklendi (HTTPS/Cloudflare Tunnel kurulunca kaldırılmalı). Yalnızca yeni oluşturulan Compose dosyalarını etkiler; mevcut dosyalar elle güncellenmeli.
16. Caddy imaj etiketi `2.11.8` doğrulanamadı; mevcut ana sürüm etiketi `caddy:2` kullanıldı.
17. Restic: parola dosyası oluşturulurken kısa süre herkesçe okunabilir izinle yazılıyordu (umask 077 ile düzeltildi); exFAT/NTFS yedek diskinde `chown/chmod` hatası kurulumu durduruyordu; tek bir SQLite kopyası başarısız olunca tüm günlük yedek iptal oluyordu (artık uyarı verip devam eder).
18. Samba kullanıcı kontrolü `pipefail` + `grep -q` yüzünden hatalı çalışabiliyordu (`pdbedit -L -u` ile değiştirildi); öngörülebilir `/tmp` dosya adları `mktemp` ile değiştirildi.
19. **Eklendi (isteğin üzerine):** Docker port kilidi (`homelab-docker-lan-only`, izole ağ alanında kural ekleme/kaldırma/tekrar uygulama denendi); kurulum sonunda ilk giriş hatırlatma listesi (File Browser ilk parolası günlükte); Scrutiny'den USB/çıkarılabilir/zram disklerin çıkarılması.
20. **Web/panel incelemesi:** Caddy Caddyfile'ı artık tek dosya yerine klasör olarak bağlanır (editör dosyayı yeniden oluşturunca konteyner eski içerikte kalıyordu). Panelde uyarı mesajı artık URL'den (`?message=`) değil oturumdan gelir (sahte uyarı gösterme yolu kapandı); çalışma süresi "0s 8d" yerine "0 sa 8 dk" yazılır; logo noktası kutudan taşıyordu, mobilde bellek yazısı kesiliyordu (düzeltildi). Ekran görüntüleriyle masaüstü ve 390 px mobilde yatay taşma olmadığı doğrulandı.
21. **Eklendi (ikinci tur):** ntfy bildirim sistemi + `homelab-health-check` (durum değişiminde bildirim; mantığı sahte bildirimle denendi) ve Restic başarısızlık bildirimi; Timeshift öncesi anlık görüntü; isteğe bağlı otomatik güvenlik güncellemesi (Mint'te `${distro_id}` eşleşmediği için Ubuntu güvenlik deposu açıkça yazıldı, Docker paketleri dışlandı); kendini kilitlemeyi önleyen `harden-ssh.sh`; `reset-panel-password.sh`. Panel yetki listesine ntfy eklendi.
22. **Gerçek kurulum çıktısından düzeltmeler:** (a) Mint'in varsayılan `50unattended-upgrades` dosyası tüm Mint `zena` güncellemelerini açıyordu; artık `#clear` ile temizlenip yalnızca Ubuntu ve Mint güvenlik depoları bırakılıyor. (b) Restic yol sorusu boş girişte hata veriyordu; artık bağlı disk adaylarını listeler, 3 deneme verir, boş Enter = atla. Kurulum çıktısında doğrulananlar: Timeshift, Docker stack'leri, ntfy kullanıcı oluşturma, LAN kilidi, sağlık zamanlayıcısı, panel, Samba, Tailscale.

## Güvenlik ve kullanım sınırları

- Docker tarafından yayımlanan servis portları LAN arayüzlerinde dinleyebilir. Router'da bu portlara yönlendirme yapmayın. UFW tek başına Docker tarafından yayımlanan portları filtrelemeyebilir.
- Panel `127.0.0.1:8000` üzerinde çalışır. Dış erişim ancak ayrı yapılandırılmış Cloudflare Tunnel ve panel hostname'ini kapsayan Cloudflare Access politikasıyla planlanmalıdır.
- Docker grubuna eklenen Linux hesabı Docker üzerinden root seviyesinde yetki elde edebilir.
- Kurulum paketi temiz Linux Mint 22.x amd64 hedeflidir. Mevcut Docker/Compose sunucusuna uygulamadan önce mevcut servisler, portlar ve `/srv/homelab` yapılandırmaları ayrıca incelenmelidir.

## Yerel doğrulama

- Bash betikleri için sözdizimi denetimi: başarılı.
- Evet/Hayır istemlerinin otomatik davranış kontrolü: başarılı.
- Python derleme denetimi: başarılı.
- Yönetim paneli birim testleri: 11 test geçti.
- Panel Python derleme denetimi ve dashboard/komut girdisi olmayan salt-okunur konsol testleri başarılı.
- Gerçek Linux Mint/Docker sistemi bulunmadığından Docker/systemd/Samba/Restic adımları uçtan uca çalıştırılmamıştır.
- Gerçek Linux Mint, systemd, Docker, disk yedeklemesi veya Cloudflare üzerinde uçtan uca doğrulama yapılmadı.

## Dış inceleme sonrası düzeltmeler (10.11.2026)

Bağımsız bir inceleme 20 madde bildirdi; her biri koda karşı doğrulandı.

Düzeltilenler: Tailscale indirme hatasının maskelenmesi (pipefail), sağlık kontrolünün gönderilemeyen bildirimi kaydetmesi, SSH anahtar tanıma ve etkin ayarın doğrulanması, panel CPU yüzdesinde guest sayaçlarının çift sayımı, uyku hedeflerinin tek tek geri alınması, KALDIR.sh'nin kurulumdan önce var olan Compose dosyalarına/konteynerlere dokunmaması, LAN kilidinin konteynerlerden önce uygulanıp doğrulanması ve sonuç mesajının buna bağlanması, yayınlanan portların IPv4'e sabitlenmesi, panel hesabının tekrar kurulumda güncellenmesi, haftalık Restic kontrolüne `--read-data-subset=5%` eklenmesi, belge çelişkileri.

Doğrulanıp hata sayılmayanlar: `91-homelab-installer-no-sleep.conf`, `70-homelab-installer-autologin.conf` ve `/etc/homelab-installer` bu kuruluma özgü adlardır (başka bir yazılımın dosyası değil); paket sahipliği kayıtları KALDIR.sh'de silinmeden önce okunur; panel testindeki çağrı sayısı doğrudur.

Bilerek yapılmayanlar: Docker imaj sürümlerinin sabitlenmesi (kullanıcı kararı), host ağındaki Beszel Agent'ın filtrelenmesi, temiz sanal makinede otomatik kurulum/kaldırma testi (bu ortamda yapılamadı).
