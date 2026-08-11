# Uptime Kuma + MsgWay

راه‌اندازی Uptime Kuma با Docker Compose و ارسال پیامک تغییر وضعیت از طریق MsgWay.

## اجرا

```bash
sudo mkdir -p /opt/uptime-kuma/data
cd docker/uptime-kuma-msgway
docker compose pull
docker compose up -d
```

پنل روی `http://SERVER-IP:3001` در دسترس است. در صورت استفاده از Reverse Proxy می‌توانید Port Mapping را به `127.0.0.1:3001:3001` محدود کنید.

## MsgWay Webhook

در Uptime Kuma یک Notification از نوع **Webhook** بسازید:

- Method: `POST`
- URL: `https://api.msgway.com/send`
- Template ID: `6742`

Headers:

```json
{
  "Content-Type": "application/json",
  "accept-language": "fa",
  "apiKey": "MSGWAY_API_KEY"
}
```

محتوای فایل [`msgway-webhook-body.json`](./msgway-webhook-body.json) را در **Custom Body** قرار دهید و `09XXXXXXXXX` را با شماره مقصد جایگزین کنید.

خروجی پیام هنگام قطعی و برقراری:

```text
🖥️ سرور «Server-01»
🔴 از دسترس خارج شد!
```

```text
🖥️ سرور «Server-01»
🟢 آنلاین شد
```

## تنظیم مانیتور Ping

| گزینه | مقدار |
|---|---:|
| Type | `Ping` |
| Heartbeat Interval | `60s` |
| Retries | `2` |
| Retry Interval | `60s` |
| Timeout | `10s` |
| Packet Count | `1` |
| Resend Notification | `0` |

با `Retries = 2` وضعیت Down بعد از سه بررسی ناموفق متوالی ثبت می‌شود. با `Resend Notification = 0` در زمان ادامه قطعی پیام تکراری ارسال نمی‌شود و پس از برقراری، یک پیام Up ارسال می‌شود.

## مدیریت و به‌روزرسانی

```bash
docker compose ps
docker compose logs -f --tail 100
docker compose restart
docker compose pull && docker compose up -d
```

## پشتیبان‌گیری

```bash
sudo tar -czf uptime-kuma-backup-$(date +%F).tar.gz -C /opt/uptime-kuma data
```

برای امنیت، API Key را فقط در تنظیمات Notification نگه دارید و آن را در Git، Issue یا لاگ عمومی منتشر نکنید.
