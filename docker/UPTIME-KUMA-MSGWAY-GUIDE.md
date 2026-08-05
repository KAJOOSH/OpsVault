# راه‌اندازی Uptime Kuma با Docker Compose و ارسال پیامک از طریق MsgWay

این راهنما شامل نصب و مدیریت **Uptime Kuma** با Docker Compose، ایجاد مانیتور Ping، تنظیم ارسال پیامک از طریق Webhook سرویس **MsgWay** و جلوگیری از ارسال پیامک‌های تکراری هنگام قطعی است.

> [!IMPORTANT]
> اطلاعات حساس مانند `API Key` واقعی MsgWay و شماره موبایل شخصی را داخل مخزن عمومی GitHub قرار ندهید. تمام مقادیر این راهنما نمونه هستند و باید فقط داخل پنل Uptime Kuma با اطلاعات واقعی جایگزین شوند.

---

## قابلیت‌های این راه‌اندازی

- نصب Uptime Kuma با Docker Compose
- استفاده از آخرین نسخهٔ پایدار شاخهٔ 2
- نگهداری دائمی اطلاعات در `/opt/uptime-kuma/data`
- بررسی سرور با Ping در هر 60 ثانیه
- اعلام قطعی پس از 3 بررسی ناموفق متوالی
- ارسال فقط یک پیامک هنگام قطعی
- جلوگیری از ارسال پیامک تکراری تا زمان بازگشت سرور
- ارسال یک پیامک هنگام آنلاین‌شدن سرور
- استفاده از قالب پیامک شماره `6742` در MsgWay
- نمایش نام مانیتور و وضعیت با ایموجی و خطوط جداگانه

---

## نسخهٔ مورد استفاده

در زمان تدوین این راهنما، آخرین نسخهٔ پایدار Uptime Kuma نسخهٔ `2.5.0` است.

در فایل Compose از تگ زیر استفاده می‌شود:

```yaml
image: louislam/uptime-kuma:2
```

تگ `2` آخرین نسخهٔ پایدار شاخهٔ 2 را دریافت می‌کند. برای دریافت نسخهٔ جدید باید دستور `docker compose pull` اجرا شود؛ صرفاً استفاده از این تگ باعث به‌روزرسانی خودکار کانتینر نمی‌شود.

برای قفل‌کردن نصب روی یک نسخهٔ مشخص می‌توان از این مقدار استفاده کرد:

```yaml
image: louislam/uptime-kuma:2.5.0
```

---

## پیش‌نیازها

Docker و افزونهٔ Docker Compose باید نصب باشند:

```bash
docker --version
docker compose version
```

کاربر اجراکننده نیز باید اجازهٔ اجرای Docker را داشته باشد. در غیر این صورت دستورات را با `sudo` اجرا کنید.

---

## ساختار پوشه‌ها

فایل‌ها و اطلاعات برنامه در مسیر زیر قرار می‌گیرند:

```text
/opt/uptime-kuma/
├── compose.yaml
└── data/
```

پوشهٔ `data` شامل پایگاه داده، تنظیمات، مانیتورها، اعلان‌ها و سایر اطلاعات Uptime Kuma است.

> [!WARNING]
> پوشهٔ `/opt/uptime-kuma/data` را حذف نکنید. حذف آن باعث ازبین‌رفتن اطلاعات Uptime Kuma می‌شود.

Uptime Kuma استفاده از فایل‌سیستم‌هایی مانند NFS را برای مسیر داده پشتیبانی نمی‌کند؛ داده‌ها را روی دیسک محلی یا Docker Volume نگه دارید.

---

## ساخت پوشه‌های نصب

```bash
sudo mkdir -p /opt/uptime-kuma/data
sudo chown -R "$USER":"$USER" /opt/uptime-kuma
cd /opt/uptime-kuma
```

---

## فایل Docker Compose

فایل زیر را ایجاد کنید:

```bash
nano /opt/uptime-kuma/compose.yaml
```

محتوای فایل:

```yaml
services:
  uptime-kuma:
    image: louislam/uptime-kuma:2
    container_name: uptime-kuma
    hostname: uptime-kuma
    restart: unless-stopped

    ports:
      - "3001:3001"

    volumes:
      - /opt/uptime-kuma/data:/app/data

    environment:
      TZ: Asia/Tehran
```

### توضیح بخش‌های Compose

| گزینه | توضیح |
|---|---|
| `image` | استفاده از آخرین نسخهٔ پایدار شاخهٔ 2 |
| `container_name` | نام ثابت کانتینر |
| `restart: unless-stopped` | اجرای مجدد خودکار کانتینر پس از ریبوت یا خطا |
| `3001:3001` | انتشار پنل Uptime Kuma روی پورت 3001 سرور |
| `/app/data` | مسیر داخلی نگهداری داده‌های Uptime Kuma |
| `TZ` | منطقهٔ زمانی برنامه و تاریخ اعلان‌ها |

اگر Uptime Kuma پشت Reverse Proxy قرار می‌گیرد و نباید پورت آن مستقیماً از اینترنت قابل‌دسترسی باشد، قسمت `ports` را به شکل زیر تغییر دهید:

```yaml
ports:
  - "127.0.0.1:3001:3001"
```

---

## اجرای Uptime Kuma

```bash
cd /opt/uptime-kuma
docker compose pull
docker compose up -d
```

بررسی وضعیت کانتینر:

```bash
docker compose ps
```

مشاهدهٔ لاگ‌ها:

```bash
docker compose logs -f uptime-kuma
```

برای خروج از حالت نمایش زندهٔ لاگ‌ها کلیدهای `Ctrl + C` را فشار دهید؛ کانتینر متوقف نمی‌شود.

---

## ورود به پنل

در مرورگر آدرس زیر را باز کنید:

```text
http://SERVER-IP:3001
```

نمونه:

```text
http://192.168.1.10:3001
```

در ورود اول، نام کاربری و رمز عبور مدیر را ایجاد کنید.

---

# تنظیم ارسال پیامک با MsgWay

## اطلاعات قالب پیامک

در این راهنما از قالب زیر استفاده می‌شود:

```text
Template ID: 6742
```

متن قالب ثبت‌شده در MsgWay:

```text
تغییر وضعیت سرور: [param1]
```

مقدار `[param1]` توسط Uptime Kuma ساخته و به MsgWay ارسال می‌شود.

---

## ایجاد Notification در Uptime Kuma

در پنل Uptime Kuma وارد مسیر زیر شوید:

```text
Settings → Notifications → Setup Notification
```

نوع اعلان را روی گزینهٔ زیر قرار دهید:

```text
Webhook
```

مقادیر اصلی:

| فیلد | مقدار |
|---|---|
| Friendly Name | `MsgWay SMS` |
| Post URL | `https://api.msgway.com/send` |
| HTTP Method | `POST` |
| Request Body | `Custom Body` |

---

## هدرهای Webhook

گزینهٔ **Additional Headers** را فعال کنید و مقدار زیر را قرار دهید:

```json
{
  "Content-Type": "application/json",
  "accept-language": "fa",
  "apiKey": "MSGWAY_API_KEY"
}
```

مقدار زیر را با API Key واقعی حساب MsgWay جایگزین کنید:

```text
MSGWAY_API_KEY
```

> [!CAUTION]
> API Key را در فایل‌های عمومی GitHub، تصویر آموزشی، Issue، لاگ یا پیام عمومی منتشر نکنید.

---

## Body نهایی Webhook

در قسمت **Custom Body** کد زیر را قرار دهید:

```json
{
  "method": "sms",
  "mobile": "09XXXXXXXXX",
  "templateID": 6742,
  "params": [
    "{% if heartbeatJSON %}{% if heartbeatJSON['status'] == 0 %}\n🖥️ سرور «{{ name }}»\n🔴 از دسترس خارج شد!{% elsif heartbeatJSON['status'] == 1 %}\n🖥️ سرور «{{ name }}»\n🟢 آنلاین شد{% else %}\n🖥️ سرور «{{ name }}»\n🔔 وضعیت آن تغییر کرده است.{% endif %}{% else %}\n🧪 پیام آزمایشی «{{ name }}»\n✅ با موفقیت ارسال شد{% endif %}"
  ]
}
```

شمارهٔ زیر را با شمارهٔ مقصد واقعی جایگزین کنید:

```text
09XXXXXXXXX
```

---

## شکل نهایی پیام‌ها

### هنگام قطعی

```text
تغییر وضعیت سرور:
🖥️ سرور «Server-01»
🔴 از دسترس خارج شد!
```

### هنگام آنلاین‌شدن

```text
تغییر وضعیت سرور:
🖥️ سرور «Server-01»
🟢 آنلاین شد
```

### هنگام تست Notification

```text
تغییر وضعیت سرور:
🧪 پیام آزمایشی «Monitor Name not available»
✅ با موفقیت ارسال شد
```

در تست دستی Notification، اطلاعات مانیتور واقعی وجود ندارد؛ بنابراین ممکن است نام آزمایشی Uptime Kuma نمایش داده شود. هنگام رخداد واقعی، مقدار `{{ name }}` با نام واقعی مانیتور جایگزین می‌شود.

---

## متغیرهای قابل‌استفاده در قالب Webhook

Uptime Kuma در Custom Body از قالب Liquid استفاده می‌کند. مهم‌ترین متغیرها:

| متغیر | کاربرد |
|---|---|
| `{{ name }}` | نام مانیتور |
| `{{ status }}` | وضعیت متنی مانیتور |
| `{{ hostnameOrURL }}` | آدرس، دامنه یا IP مانیتور |
| `{{ msg }}` | پیام اصلی Uptime Kuma |
| `monitorJSON` | اطلاعات کامل مانیتور |
| `heartbeatJSON` | اطلاعات آخرین بررسی |

مقادیر مهم وضعیت:

```text
heartbeatJSON['status'] == 0  → Down
heartbeatJSON['status'] == 1  → Up
heartbeatJSON['status'] == 2  → Pending
heartbeatJSON['status'] == 3  → Maintenance
```

در Body این راهنما:

- وضعیت `0` پیام قطعی تولید می‌کند.
- وضعیت `1` پیام آنلاین‌شدن تولید می‌کند.
- نبودن `heartbeatJSON` به‌عنوان تست Notification در نظر گرفته می‌شود.

---

## آزمایش Webhook

پس از واردکردن Header و Body:

1. روی دکمهٔ **Test** کلیک کنید.
2. دریافت پیامک را بررسی کنید.
3. Notification را ذخیره کنید.
4. Notification ساخته‌شده را در تنظیمات مانیتور فعال کنید.

موفقیت دکمهٔ Test فقط نشان می‌دهد درخواست آزمایشی ارسال شده است. برای اطمینان کامل، یک مانیتور آزمایشی نیز ایجاد و وضعیت واقعی Down و Up را بررسی کنید.

---

# ساخت مانیتور Ping

در صفحهٔ اصلی Uptime Kuma روی **Add New Monitor** کلیک کنید.

مقادیر پایه:

| تنظیم | مقدار |
|---|---|
| Monitor Type | `Ping` |
| Friendly Name | نام دلخواه، مانند `Server-01` |
| Hostname | IP یا دامنهٔ سرور |
| Heartbeat Interval | `60` ثانیه |
| Retries | `2` |
| Heartbeat Retry Interval | `60` ثانیه |
| Request Timeout | `10` ثانیه |
| Ping Count | `1` |
| Resend Notification if Down X times consecutively | `0` یا `Resend disabled` |
| Notifications | فعال‌کردن `MsgWay SMS` |

گزینه‌های `Ping Count` و بعضی تنظیمات ممکن است در قسمت **Advanced** قرار داشته باشند.

---

## چرا Retries روی 2 قرار می‌گیرد؟

مقدار `Retries` تعداد تلاش‌های مجدد پس از شکست اولیه است:

```text
شکست اولیه + 2 تلاش مجدد = 3 بررسی ناموفق
```

بنابراین برای ارسال پیامک پس از 3 شکست متوالی باید مقدار زیر انتخاب شود:

```text
Retries = 2
```

قرار دادن `Retries = 3` باعث می‌شود سرویس پس از چهارمین شکست به‌عنوان Down ثبت شود.

---

## روند زمانی تشخیص قطعی

با تنظیم فاصلهٔ بررسی و Retry روی 60 ثانیه:

```text
زمان 00:00 → شکست اول → وضعیت Pending → بدون پیامک
زمان 01:00 → شکست دوم → وضعیت Pending → بدون پیامک
زمان 02:00 → شکست سوم → وضعیت Down → ارسال یک پیامک قطعی
```

پس از ثبت وضعیت Down، Uptime Kuma همچنان سرور را هر 60 ثانیه بررسی می‌کند.

به دلیل تنظیم زیر، در طول قطعی پیامک دیگری ارسال نمی‌شود:

```text
Resend Notification if Down X times consecutively = 0
```

هنگامی که یک بررسی موفق شود:

```text
Down → Up
```

یک پیامک آنلاین‌شدن ارسال می‌شود و شمارندهٔ خطا از ابتدا صفر خواهد شد.

---

## رفتار مورد انتظار

| رخداد | نتیجه |
|---|---|
| یک Ping ناموفق | بدون پیامک |
| دو Ping ناموفق متوالی | بدون پیامک |
| سه Ping ناموفق متوالی | یک پیامک قطعی |
| ادامهٔ قطعی | بدون پیامک تکراری |
| اولین Ping موفق پس از قطعی | یک پیامک آنلاین‌شدن |
| ادامهٔ آنلاین‌بودن | بدون پیامک تکراری |

---

# مدیریت کانتینر

## مشاهدهٔ وضعیت

```bash
cd /opt/uptime-kuma
docker compose ps
```

## مشاهدهٔ لاگ‌ها

```bash
docker compose logs --tail=200 uptime-kuma
```

نمایش زنده:

```bash
docker compose logs -f uptime-kuma
```

## توقف

```bash
docker compose stop
```

## اجرا

```bash
docker compose start
```

## راه‌اندازی مجدد

```bash
docker compose restart
```

## حذف کانتینر بدون حذف داده‌ها

```bash
docker compose down
```

این دستور کانتینر و شبکهٔ Compose را حذف می‌کند، اما پوشهٔ زیر باقی می‌ماند:

```text
/opt/uptime-kuma/data
```

اجرای مجدد:

```bash
docker compose up -d
```

---

# به‌روزرسانی Uptime Kuma

```bash
cd /opt/uptime-kuma
docker compose pull
docker compose up -d --remove-orphans
docker image prune -f
```

مشاهدهٔ نسخهٔ نصب‌شده:

```bash
docker exec uptime-kuma node -p "require('/app/package.json').version"
```

قبل از به‌روزرسانی‌های مهم، از داده‌ها نسخهٔ پشتیبان تهیه کنید.

---

# پشتیبان‌گیری

برای داشتن نسخهٔ سازگار از پایگاه داده، بهتر است هنگام تهیهٔ Backup کانتینر موقتاً متوقف شود.

```bash
cd /opt/uptime-kuma
docker compose stop

sudo tar -czf \
  "/opt/uptime-kuma-backup-$(date +%Y-%m-%d_%H-%M-%S).tar.gz" \
  -C /opt uptime-kuma

docker compose start
```

فایل Backup در مسیر `/opt` ساخته می‌شود.

بررسی فایل‌ها:

```bash
ls -lh /opt/uptime-kuma-backup-*.tar.gz
```

> [!IMPORTANT]
> Backup شامل تنظیمات Notification و احتمالاً API Key ذخیره‌شده در پایگاه داده است. فایل پشتیبان را عمومی نکنید.

---

# بازیابی نسخهٔ پشتیبان

ابتدا کانتینر را متوقف کنید:

```bash
cd /opt/uptime-kuma
docker compose down
```

از پوشهٔ فعلی نسخهٔ احتیاطی بگیرید:

```bash
sudo mv /opt/uptime-kuma /opt/uptime-kuma-before-restore
```

Backup را استخراج کنید:

```bash
sudo tar -xzf /opt/uptime-kuma-backup-YYYY-MM-DD_HH-MM-SS.tar.gz -C /opt
```

مجوز پوشه‌ها را اصلاح کنید:

```bash
sudo chown -R "$USER":"$USER" /opt/uptime-kuma
```

سپس سرویس را اجرا کنید:

```bash
cd /opt/uptime-kuma
docker compose up -d
```

---

# حذف کامل

> [!CAUTION]
> دستورات این قسمت تمام مانیتورها، تنظیمات، تاریخچه و Notificationها را حذف می‌کنند.

```bash
cd /opt/uptime-kuma
docker compose down
sudo rm -rf /opt/uptime-kuma
```

در صورت نیاز تصویر Docker را نیز حذف کنید:

```bash
docker image rm louislam/uptime-kuma:2
```

---

# نکات امنیتی

- API Key واقعی MsgWay را در GitHub قرار ندهید.
- شماره موبایل واقعی را در فایل عمومی قرار ندهید.
- برای پنل Uptime Kuma رمز عبور قوی انتخاب کنید.
- پورت `3001` را بدون محدودیت روی اینترنت منتشر نکنید.
- برای دسترسی عمومی از HTTPS و Reverse Proxy استفاده کنید.
- فایل‌های Backup را رمزگذاری و در محل امن نگهداری کنید.
- دسترسی پوشهٔ `/opt/uptime-kuma/data` را فقط به کاربران مورداعتماد بدهید.
- Uptime Kuma و تصویر Docker آن را مرتب به‌روزرسانی کنید.

---

# نکات مربوط به پیامک و ایموجی

- وجود ایموجی باعث Unicode شدن پیامک می‌شود.
- ظرفیت هر بخش پیامک Unicode کمتر از پیامک متنی معمولی است.
- متن طولانی یا ایموجی‌های زیاد ممکن است پیام را چندبخشی و هزینه را بیشتر کند.
- بعضی اپراتورها یا پنل‌ها ممکن است شکل ایموجی را متفاوت نمایش دهند.
- شکست خط در Body با `\n` ایجاد شده است.
- اگر MsgWay یا اپراتور شکست خط را حذف کند، متن ممکن است یک‌خطی نمایش داده شود.
- قالب MsgWay باید دقیقاً دارای `[param1]` باشد.

---

# عیب‌یابی

## پنل باز نمی‌شود

وضعیت کانتینر را بررسی کنید:

```bash
docker compose ps
docker compose logs --tail=200 uptime-kuma
```

در دسترس‌بودن پورت را بررسی کنید:

```bash
ss -lntp | grep 3001
```

فایروال سرور نیز باید دسترسی لازم را داشته باشد.

---

## پیامک ارسال نمی‌شود

موارد زیر را بررسی کنید:

1. `apiKey` صحیح باشد.
2. شماره موبایل با فرمت موردقبول MsgWay وارد شده باشد.
3. Template ID برابر `6742` باشد.
4. قالب MsgWay فعال و تأیید شده باشد.
5. متن قالب دارای `[param1]` باشد.
6. موجودی حساب MsgWay کافی باشد.
7. Header و Body از نظر JSON معتبر باشند.
8. Notification در خود مانیتور انتخاب شده باشد.
9. لاگ Uptime Kuma خطای HTTP نمایش ندهد.

مشاهدهٔ لاگ:

```bash
docker compose logs --tail=300 uptime-kuma
```

خطاهای رایج:

| خطا | علت احتمالی |
|---|---|
| `401` یا `403` | API Key اشتباه یا بدون دسترسی |
| `400` | Body، شماره موبایل یا قالب نامعتبر |
| `404` | آدرس API اشتباه |
| Timeout | اختلال اینترنت، DNS، فایروال یا سرویس MsgWay |
| Additional Headers is not a valid JSON | JSON هدرها نامعتبر است |

---

## Ping همیشه Down است

ممکن است ICMP در سرور مقصد یا فایروال مسدود باشد.

از خود میزبان Docker آزمایش کنید:

```bash
ping -c 3 SERVER-IP
```

اگر Ping عمداً بسته است، به‌جای Monitor نوع Ping از یکی از روش‌های زیر استفاده کنید:

- HTTP(s)
- TCP Port
- DNS
- Keyword

---

## پس از به‌روزرسانی اطلاعات حذف شده است

Mount مسیر داده را بررسی کنید:

```bash
docker inspect uptime-kuma \
  --format '{{ range .Mounts }}{{ .Source }} -> {{ .Destination }}{{ println }}{{ end }}'
```

خروجی باید شامل مسیر زیر باشد:

```text
/opt/uptime-kuma/data -> /app/data
```

---

## پیامک قطعی تکرار می‌شود

مقدار زیر را بررسی کنید:

```text
Resend Notification if Down X times consecutively = 0
```

در رابط کاربری ممکن است مقدار آن به‌صورت زیر نمایش داده شود:

```text
Resend disabled
```

---

## پیامک پس از یک خطا ارسال می‌شود

مقدار زیر باید دقیقاً `2` باشد:

```text
Retries = 2
```

همچنین مطمئن شوید تغییرات مانیتور ذخیره شده‌اند.

---

# منابع رسمی

- [مخزن رسمی Uptime Kuma](https://github.com/louislam/uptime-kuma)
- [نسخه‌های رسمی Uptime Kuma](https://github.com/louislam/uptime-kuma/releases)
- [راهنمای رسمی به‌روزرسانی Uptime Kuma](https://github.com/louislam/uptime-kuma/wiki/%F0%9F%86%99-How-to-Update)
- [کد رسمی Webhook در Uptime Kuma](https://github.com/louislam/uptime-kuma/blob/2.5.0/server/notification-providers/webhook.js)
- [متغیرهای قالب Notification در Uptime Kuma](https://github.com/louislam/uptime-kuma/blob/2.5.0/server/notification-providers/notification-provider.js)
- [منطق Retry و اعلان‌ها در Uptime Kuma](https://github.com/louislam/uptime-kuma/blob/2.5.0/server/model/monitor.js)
- [مستندات MsgWay](https://msgway.com/doc)
- [SDK رسمی PHP سرویس MsgWay](https://github.com/MessageWay/MessageWayPHP)

---

## خلاصهٔ تنظیم نهایی

```text
Uptime Kuma Image: louislam/uptime-kuma:2
Data Path: /opt/uptime-kuma/data
Panel Port: 3001
Monitor Type: Ping
Heartbeat Interval: 60
Retries: 2
Retry Interval: 60
Request Timeout: 10
Ping Count: 1
Resend Notification: 0 / Disabled
MsgWay Endpoint: https://api.msgway.com/send
MsgWay Template ID: 6742
```
