# Yönetim paneli

Bu klasör, HomeLab paketindeki Flask yönetim panelinin kaynak kodudur. Panel, ana paketin `KUR.sh` betiğiyle kurulur; ayrı bir kurulum betiği yoktur çünkü panelin Docker işlemleri için ana paketin kurduğu root sahipli allowlist yardımcısına ve sudoers kuralına ihtiyacı vardır.

Giriş sonrası ana sayfa sunucu CPU/RAM kullanımını, kök ve HomeLab disk alanını, çalışma süresini, Docker servislerini, izin verilen servis işlemlerini, temel systemd servislerini ve Restic zamanlayıcısının/son yedek görevinin durumunu gösterir. **Salt okunur konsol** sabit durum raporlarını sunar; komut girdisi almaz ve sistemde değişiklik yapmaz. Sistem metrikleri sayfa yenilendiğinde alınır. Docker işlemleri sınırlı allowlist helper üzerinden yürütülür.

Kurulum, servis listesi, Cloudflare Access ve güvenlik sınırları için üst klasördeki `README.md` dosyasını izleyin. `KUR.sh` tamamlanmadan bu klasörü tek başına çalıştırmayın.
