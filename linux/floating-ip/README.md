# Floating IP

اسکریپت مدیریت دائمی Floating IP برای Ubuntu/Hetzner با Netplan.

## دانلود

```bash
curl -fsSL https://raw.githubusercontent.com/KAJOOSH/OpsVault/refs/heads/main/linux/floating-ip/floating-ip.sh  -o /usr/local/bin/floating-ip

chmod +x /usr/local/bin/floating-ip
```

## استفاده

### اضافه کردن IP

```bash
sudo floating-ip add [IP]
```

### حذف IP

```bash
sudo floating-ip remove [IP]
```

### نمایش IPهای تنظیم‌شده

```bash
sudo floating-ip list
```

IPها به‌صورت دائمی در `/etc/netplan/60-floating-ip.yaml` ثبت می‌شوند و بعد از reboot باقی می‌مانند.

> پیش‌فرض اسکریپت برای Interface با نام `eth0` است.
