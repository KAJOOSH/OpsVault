# Xray User Monitor for Marzban Node

مانیتور سبک و دائمی برای نگه‌داری تاریخچه مصرف Xray و پیدا کردن کاربرانی که هنگام افزایش CPU بیشترین ترافیک یا اتصال را داشته‌اند.

> همه کاربران داخل Process مشترک Xray اجرا می‌شوند؛ بنابراین CPU دقیق هر Username مستقیماً از Linux قابل اندازه‌گیری نیست. این ابزار CPU Process را با آمار ترافیک، IPهای آنلاین و اتصال‌های TCP هم‌بسته می‌کند.

## نصب

```bash
curl -fsSL "https://raw.githubusercontent.com/KAJOOSH/OpsVault/refs/heads/main/xray/user-monitor/install-xray-user-monitor.sh" -o /tmp/install-xray-user-monitor.sh \
  && chmod +x /tmp/install-xray-user-monitor.sh \
  && sudo /tmp/install-xray-user-monitor.sh
```

Installer سرویس `systemd`، پایگاه SQLite، ابزار `xraymon` و `grpcurl` موردنیاز را آماده می‌کند.

## مسیرها

| مسیر | کاربرد |
|---|---|
| `/opt/xray-user-monitor/` | برنامه مانیتور و فایل Proto |
| `/etc/xray-user-monitor.conf` | تنظیمات |
| `/var/lib/xray-user-monitor/history.db` | تاریخچه SQLite |
| `/var/lib/xray-user-monitor/events.log` | رخدادهای مهم |
| `/usr/local/bin/xraymon` | CLI گزارش‌گیری |

## دستورات

```bash
xraymon status
xraymon events 168
xraymon show <EVENT-ID>
xraymon top 24
xraymon user <USERNAME> 24
xraymon size
watch -n 5 xraymon status
```

- `status`: آخرین وضعیت Xray و کاربران پرترافیک
- `events`: رخدادهای CPU بالا در بازه زمانی
- `show`: جزئیات یک رخداد و کاربران همان بازه
- `top`: کاربران پرترافیک در تاریخچه
- `user`: تاریخچه یک کاربر
- `size`: حجم پایگاه داده

## تنظیمات پیش‌فرض

```ini
XRAY_API_HOST=127.0.0.1
XRAY_API_PORT=62051
SAMPLE_INTERVAL=15
CPU_EVENT_THRESHOLD=100
CPU_CLEAR_THRESHOLD=70
EVENT_CLEAR_SAMPLES=3
TOP_USERS=10
RETENTION_DAYS=30
DEEP_SCAN_ON_HIGH_CPU=1
RPC_TIMEOUT=4
```

`100%` CPU در این گزارش معادل مصرف کامل یک Core توسط Process Xray است. Deep Scan فقط هنگام CPU بالا اجرا می‌شود تا سربار مانیتور پایین بماند.

پس از تغییر فایل تنظیمات:

```bash
sudo systemctl restart xray-user-monitor
```

## مدیریت سرویس

```bash
systemctl status xray-user-monitor --no-pager
journalctl -u xray-user-monitor -f
systemctl restart xray-user-monitor
```

اطلاعات تا `RETENTION_DAYS` روز نگه‌داری می‌شوند و پاک‌سازی تاریخچه به‌صورت خودکار انجام می‌شود.
