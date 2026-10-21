# Floating IP

برای اضافه‌کردن آی‌پی شناور و استفاده از آن به‌عنوان آی‌پی خروجی سرور.

ابتدا آی‌پی شناور را در پنل Hetzner به سرور اختصاص دهید. در دستورهای زیر، به‌جای `FLOATING_IP` آی‌پی شناور خودتان را بنویسید.

## نصب

این بلوک را کامل در ترمینال سرور اجرا کنید:

```bash
(
  set -e
  script=$(mktemp)
  trap 'rm -f "$script"' EXIT
  curl -fsSL https://raw.githubusercontent.com/KAJOOSH/OpsVault/refs/heads/main/linux/floating-ip/floating-ip.sh -o "$script"
  sudo bash "$script" install
)
```

## افزودن آی‌پی و فعال‌کردن خروجی

```bash
sudo floating-ip add FLOATING_IP --snat
```

آی‌پی اصلی سرور خودکار شناسایی می‌شود. تنظیمات بعد از روشن‌شدن دوبارهٔ سرور هم باقی می‌مانند.

اگر فقط می‌خواهید آی‌پی را اضافه کنید و خروجی تغییر نکند:

```bash
sudo floating-ip add FLOATING_IP
```

برای فعال‌کردن خروجی روی آی‌پی‌ای که قبلاً اضافه شده است:

```bash
sudo floating-ip snat add FLOATING_IP
```

## مشاهدهٔ وضعیت

نمایش آی‌پی‌های اضافه‌شده:

```bash
sudo floating-ip list
```

نمایش تنظیمات خروجی:

```bash
sudo floating-ip snat list
```

## حذف

برای غیرفعال‌کردن خروجی شناور و نگه‌داشتن خود آی‌پی:

```bash
sudo floating-ip snat remove
```

برای حذف کامل آی‌پی و تنظیمات خروجی مربوط به آن:

```bash
sudo floating-ip remove FLOATING_IP
```

## به‌روزرسانی

```bash
sudo floating-ip update
```

اگر نسخهٔ جدیدی موجود باشد، نصب می‌شود و تنظیمات قبلی حفظ می‌شوند. اجرای دوبارهٔ بلوک نصب هم نسخهٔ جدید را نصب می‌کند.

برای مشاهدهٔ نسخهٔ نصب‌شده:

```bash
floating-ip version
```

اگر از نسخهٔ قدیمی استفاده می‌کنید و دستور `update` شناخته نمی‌شود، بلوک نصب را دوباره اجرا کنید.

برای تنظیمات خاص یا رفع مشکل، [راهنمای فنی](TECHNICAL.md) را ببینید.
