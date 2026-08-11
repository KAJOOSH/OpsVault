# Xray User Monitor for Marzban Node

یک مانیتور سبک و دائمی برای **Marzban Node / Xray-core** که به شما کمک می‌کند بعد از وقوع مصرف غیرعادی CPU، مشخص کنید در همان بازه زمانی کدام کاربران بیشترین ترافیک، IP آنلاین یا Connection را داشته‌اند.

این ابزار برای شرایطی طراحی شده که Xray ناگهان CPU زیادی مصرف می‌کند و حتی ممکن است مجبور شوید سرور را Restart کنید. اطلاعات قبل از Restart در SQLite ذخیره می‌شود و بعداً قابل بررسی است.

> **نکته مهم:** تمام کاربران Xray داخل یک Process مشترک اجرا می‌شوند. بنابراین Linux نمی‌تواند به‌صورت مستقیم بگوید «فلان Username دقیقاً 80% CPU مصرف کرده است». این ابزار با ثبت همزمان CPU هسته، ترافیک کاربران، IPهای آنلاین و Connectionها، یک **هم‌بستگی زمانی بسیار قوی** برای پیدا کردن کاربر یا رفتار مشکوک ایجاد می‌کند.

---

## قابلیت‌ها

- اجرای دائمی در پس‌زمینه با `systemd`
- شروع خودکار بعد از Reboot
- مصرف بسیار پایین CPU و I/O
- بدون اجرای Docker در حلقه Monitoring
- استفاده از `grpcurl` به‌صورت Native
- خواندن مستقیم `StatsService` هسته Xray
- ثبت CPU واقعی Process هسته Xray
- ثبت RAM و تعداد Threadهای Xray
- ثبت Upload / Download هر User
- ذخیره تاریخچه در SQLite
- تشخیص خودکار High CPU Incident
- ثبت زمان شروع و پایان Incident
- ثبت Peak CPU
- ثبت User دارای بیشترین Traffic در زمان Peak
- Deep Scan فقط هنگام High CPU
- بررسی IPهای آنلاین در صورت پشتیبانی Xray
- تخمین Connectionهای TCP کاربر هنگام Incident
- نگهداری Top-N کاربران برای جلوگیری از بزرگ شدن دیتابیس
- پاک‌سازی خودکار History قدیمی
- ادامه صحیح Monitoring بعد از Restart شدن Xray
- ابزار CLI با نام `xraymon`
- امکان بررسی Incident حتی بعد از Reboot کامل سرور

---

# معماری

در حالت عادی Monitor هر چند ثانیه یک Sample بسیار سبک می‌گیرد:

```text
                    ┌─────────────────┐
                    │   Xray Process  │
                    └────────┬────────┘
                             │
                  ┌──────────┴──────────┐
                  │                     │
               /proc                StatsService
                  │                     │
          CPU / RAM / Threads      QueryStats
                                        │
                               Per-user traffic
                  │                     │
                  └──────────┬──────────┘
                             │
                             ▼
                        SQLite DB
```

هنگام بالا رفتن CPU:

```text
CPU >= Threshold
       │
       ├── Create Incident
       │
       ├── Save Peak CPU
       │
       ├── Save Top Users
       │
       ├── GetUsersStats
       │      └── Online IPs
       │
       └── ss
              └── Established TCP connections
```

`ss` و Deep Scan دائماً اجرا نمی‌شوند و فقط هنگام عبور CPU از Threshold فعال می‌شوند.

---

# مناسب برای

این ابزار برای سرورهایی مناسب است که:

- روی آن‌ها **Marzban Node** اجرا می‌شود.
- هسته Xray روی همان Node اجرا می‌شود.
- API هسته Xray در دسترس Node است.
- سیستم‌عامل Debian / Ubuntu و `systemd` دارد.

پیش‌فرض ابزار برای ساختار رایج Marzban Node:

```text
Xray API Host: 127.0.0.1
Xray API Port: 62051
```

است.

اگر Node شما Port متفاوتی دارد، کافی است Config را تغییر دهید.

---

# فایل Installer

فایل اصلی:

```text
install-xray-user-monitor.sh
```

Installer موارد زیر را ایجاد می‌کند:

```text
/opt/xray-user-monitor/
├── monitor.py
├── report.py
└── command.proto

/etc/xray-user-monitor.conf

/etc/systemd/system/xray-user-monitor.service

/var/lib/xray-user-monitor/
├── history.db
└── events.log

/usr/local/bin/xraymon
```

---

# نصب

ابتدا فایل را Executable کنید:

```bash
chmod +x install-xray-user-monitor.sh
```

سپس با دسترسی Root اجرا کنید:

```bash
sudo ./install-xray-user-monitor.sh
```

Installer به‌صورت خودکار Dependencies موردنیاز را بررسی و در صورت نیاز نصب می‌کند.

Dependencies اصلی:

```text
python3
curl
iproute2
ca-certificates
grpcurl
```

برای `grpcurl` نسخه Native نصب می‌شود و Docker برای Monitoring لازم نیست.

---

# بررسی وضعیت سرویس

```bash
systemctl status xray-user-monitor --no-pager
```

نمایش Log زنده:

```bash
journalctl -u xray-user-monitor -f
```

Restart سرویس:

```bash
systemctl restart xray-user-monitor
```

Stop:

```bash
systemctl stop xray-user-monitor
```

Start:

```bash
systemctl start xray-user-monitor
```

---

# دستورات xraymon

## وضعیت فعلی

```bash
xraymon status
```

نمونه خروجی:

```text
Time        : 2026-08-11 11:05:15
Xray PID    : 1212
Xray CPU    : 34.8%  (100% = one fully used CPU core)
Xray RAM    : 274.3 MiB
Threads     : 46
User traffic: 218.31 Mbps  UP=18.25  DOWN=200.06
Top user    : ali  84.52 Mbps
Active users: 31
Stats API   : OK (QueryStats)
Event       : -
```

در ادامه Top Userهای همان Sample نیز نمایش داده می‌شوند.

---

## نمایش زنده

```bash
watch -n 5 xraymon status
```

این دستور Query جدیدی به Xray ارسال نمی‌کند؛ فقط آخرین اطلاعات ذخیره‌شده در SQLite را نمایش می‌دهد.

بنابراین برای Monitoring روی Terminal نیز بسیار سبک است.

---

# بررسی Incidentهای گذشته

مهم‌ترین قابلیت ابزار همین بخش است.

مثلاً برای مشاهده Incidentهای 7 روز گذشته:

```bash
xraymon events 168
```

عدد `168` تعداد ساعت است:

```text
168 hours = 7 days
```

نمونه:

```text
ID  START                END                  PEAK CPU  PEAK USER     USER Mbps  TCP   IPs  STATUS
--  -------------------  -------------------  --------  ------------  ---------  ----  ---  ------
7   2026-08-12 03:17:15  2026-08-12 03:24:00  386.4%   user_ali      412.81     12    1    ended
6   2026-08-11 22:43:30  2026-08-11 22:45:00  227.7%   baduser         5.31    842    1    ended
5   2026-08-11 18:02:15  2026-08-11 18:03:15  141.9%   reza           93.44      8    2    ended
```

---

# بررسی جزئیات یک Incident

برای مثال Incident شماره 6:

```bash
xraymon show 6
```

نمونه:

```text
Event       : #6 (ended)
Start       : 2026-08-11 22:43:30
End         : 2026-08-11 22:45:00
Peak time   : 2026-08-11 22:44:15
Peak CPU    : 227.7%
Total Mbps  : 126.32
Peak user   : baduser
User Mbps   : 5.31
User TCP    : 842
User IPs    : 1
```

سپس Sampleهای اطراف Peak CPU و کاربران فعال در همان لحظه نمایش داده می‌شوند.

این دستور یکی از مهم‌ترین ابزارها برای Root Cause Analysis است.

---

# سناریوی واقعی بعد از Reboot

فرض کنید ساعت 03:20 Xray شدیداً CPU مصرف کرده و مجبور شده‌اید Node را Reboot کنید.

بعد از بالا آمدن سرور:

```bash
xraymon events 24
```

Incident موردنظر را پیدا کنید.

مثلاً:

```text
ID 12
```

سپس:

```bash
xraymon show 12
```

اطلاعات Incident قبل از Reboot از SQLite خوانده می‌شود.

بنابراین Restart شدن Xray یا حتی Reboot کامل Node باعث از بین رفتن History قبلی نمی‌شود.

---

# Top Users در گذشته

نمایش کاربران پرترافیک 24 ساعت گذشته:

```bash
xraymon top 24
```

نمونه:

```text
USER          PEAK Mbps   AVG* Mbps   MAX TCP   MAX IPs   TOP SAMPLES
------------  ----------  ----------  --------  --------  -----------
ali              420.72      188.31        15         2          120
baduser            8.31        4.11      1284         1           42
reza              181.21       90.17        21         3           75
```

وجود Traffic پایین به معنی سالم بودن User نیست.

مثلاً:

```text
baduser
Peak Traffic = 8 Mbps
MAX TCP      = 1284
```

می‌تواند بسیار مشکوک‌تر از کاربری باشد که با 400 Mbps فقط چند Connection پایدار دارد.

---

# بررسی یک Username مشخص

مثلاً بررسی User به نام:

```text
baduser
```

در 48 ساعت گذشته:

```bash
xraymon user baduser 48
```

نمایش داده می‌شود:

- Peak Traffic
- Max TCP Connections
- Max Online IPs
- تعداد Sampleهای ذخیره‌شده
- History اخیر User

---

# بررسی حجم Database

```bash
xraymon size
```

نمونه:

```text
/var/lib/xray-user-monitor/history.db: 4.20 MiB
/var/lib/xray-user-monitor/history.db-wal: 0.31 MiB
/var/lib/xray-user-monitor/history.db-shm: 0.03 MiB
Total: 4.54 MiB
```

---

# Config

فایل Config:

```text
/etc/xray-user-monitor.conf
```

مقادیر پیش‌فرض:

```ini
# Marzban Node Xray API
XRAY_API_HOST=127.0.0.1
XRAY_API_PORT=62051

# Poll interval
SAMPLE_INTERVAL=15

# Xray process CPU
CPU_EVENT_THRESHOLD=100
CPU_CLEAR_THRESHOLD=70
EVENT_CLEAR_SAMPLES=3

# Number of busiest users retained per sample
TOP_USERS=10

# Automatic history retention
RETENTION_DAYS=30

# Extra analysis only when CPU is high
DEEP_SCAN_ON_HIGH_CPU=1

# gRPC timeout
RPC_TIMEOUT=4
```

بعد از تغییر Config:

```bash
systemctl restart xray-user-monitor
```

---

# SAMPLE_INTERVAL

پیش‌فرض:

```ini
SAMPLE_INTERVAL=15
```

یعنی هر 15 ثانیه یک Sample.

برای بیشتر سرورها این مقدار تعادل خوبی بین Resolution و Overhead است.

مقادیر پیشنهادی:

```text
10 sec    High-resolution monitoring
15 sec    Recommended
30 sec    Very low overhead
60 sec    Long-term coarse monitoring
```

برای تشخیص Spikeهای کوتاه، `15` ثانیه پیشنهاد می‌شود.

---

# CPU_EVENT_THRESHOLD

پیش‌فرض:

```ini
CPU_EVENT_THRESHOLD=100
```

CPU در این ابزار CPU خود Process Xray است.

بنابراین:

```text
100% ≈ یک CPU Core کاملاً درگیر
200% ≈ دو Core
300% ≈ سه Core
400% ≈ چهار Core
```

اگر سرور 4 Core دارد و Xray هنگام مشکل به حدود `300%` یا `400%` می‌رسد، Threshold برابر `100` مناسب است و Incident را خیلی زود ثبت می‌کند.

اگر Xray در حالت عادی نزدیک 100% فعالیت دارد، می‌توانید Threshold را مثلاً افزایش دهید:

```ini
CPU_EVENT_THRESHOLD=150
```

یا:

```ini
CPU_EVENT_THRESHOLD=200
```

---

# CPU_CLEAR_THRESHOLD

پیش‌فرض:

```ini
CPU_CLEAR_THRESHOLD=70
```

Incident بلافاصله بعد از افت CPU بسته نمی‌شود.

برای جلوگیری از باز و بسته شدن سریع Event، CPU باید چند Sample متوالی زیر Clear Threshold باشد.

تعداد Sampleها:

```ini
EVENT_CLEAR_SAMPLES=3
```

با Interval پیش‌فرض 15 ثانیه:

```text
3 × 15 sec = 45 seconds
```

یعنی CPU تقریباً 45 ثانیه باید پایین بماند تا Incident بسته شود.

این روش Hysteresis از ایجاد Eventهای بسیار زیاد و تکه‌تکه جلوگیری می‌کند.

---

# TOP_USERS

پیش‌فرض:

```ini
TOP_USERS=10
```

برای هر Sample همه کاربران داخل Database ذخیره نمی‌شوند.

فقط کاربران پرترافیک ذخیره می‌شوند.

هنگام High CPU، کاربران دارای Connection زیاد نیز به مجموعه ذخیره‌شده اضافه می‌شوند.

این کار باعث می‌شود Database حتی روی Nodeهای شلوغ کوچک بماند.

در صورت نیاز:

```ini
TOP_USERS=20
```

ولی برای بیشتر Nodeها مقدار `10` کافی است.

---

# RETENTION_DAYS

پیش‌فرض:

```ini
RETENTION_DAYS=30
```

Sampleهای قدیمی‌تر از 30 روز به‌صورت خودکار حذف می‌شوند.

برای نگهداری 60 روز:

```ini
RETENTION_DAYS=60
```

برای 90 روز:

```ini
RETENTION_DAYS=90
```

هرچه Retention بیشتر باشد Database بزرگ‌تر خواهد شد.

---

# Deep Scan

پیش‌فرض:

```ini
DEEP_SCAN_ON_HIGH_CPU=1
```

Deep Scan فقط زمانی اجرا می‌شود که:

```text
Xray CPU >= CPU_EVENT_THRESHOLD
```

در حالت معمول:

```text
ss
GetUsersStats
```

به‌صورت مداوم اجرا نمی‌شوند.

در زمان Incident، اگر نسخه Xray از `GetUsersStats` پشتیبانی کند:

1. IPهای آنلاین Users دریافت می‌شوند.
2. `ss` فقط همان لحظه اجرا می‌شود.
3. Established TCP Connectionهای متعلق به Process Xray بررسی می‌شوند.
4. در صورتی که یک IP فقط به یک User قابل انتساب باشد، تعداد Connection برای آن User ثبت می‌شود.

این طراحی برای پایین نگه داشتن Overhead انتخاب شده است.

---

# تفسیر نتایج

## حالت اول: Traffic بسیار زیاد

مثال:

```text
USER       Mbps     TCP
ali        450       12
```

و همزمان:

```text
Xray CPU = 350%
```

این User یکی از مظنون‌های اصلی است.

---

## حالت دوم: Traffic کم ولی Connection بسیار زیاد

مثال:

```text
USER       Mbps     TCP
baduser      6      1200
```

و همزمان:

```text
Xray CPU = 280%
```

این حالت حتی مشکوک‌تر است.

ممکن است User باعث:

- Connection churn
- تعداد زیاد اتصال کوتاه
- Burstهای Connection
- درخواست‌های متعدد
- رفتار غیرمعمول Client
- استفاده سنگین از Transport
- تعداد زیاد Session

شده باشد.

---

## حالت سوم: Traffic زیاد ولی CPU طبیعی

مثال:

```text
USER       Mbps     TCP
download   600        6
```

ولی:

```text
Xray CPU = 45%
```

این User صرفاً Traffic زیادی دارد و لزوماً عامل مشکل CPU نیست.

---

# چرا Traffic به‌تنهایی کافی نیست؟

یک User می‌تواند با یک Connection پایدار:

```text
500 Mbps
```

مصرف کند ولی فشار CPU زیادی ایجاد نکند.

در مقابل User دیگری ممکن است:

```text
5 Mbps
```

داشته باشد ولی هزاران Connection کوتاه ایجاد کند.

به همین دلیل Monitor چند پارامتر را کنار هم ذخیره می‌کند:

```text
CPU
Traffic
TCP Connections
Online IPs
Timestamp
```

و تصمیم باید از ترکیب آن‌ها گرفته شود.

---

# نحوه محاسبه Traffic

Xray Stats مقدار cumulative Counter را ارائه می‌دهد.

Monitor Counter را Reset نمی‌کند.

به‌جای آن:

```text
Traffic Rate =
Current Counter - Previous Counter
----------------------------------
            Elapsed Time
```

محاسبه می‌شود.

این روش باعث می‌شود Monitoring در Stats اصلی Xray دخالت نکند.

---

# رفتار هنگام Restart شدن Xray

اگر PID هسته Xray تغییر کند، Monitor متوجه می‌شود.

مثلاً:

```text
Xray PID changed: 1212 -> 2441
```

در این شرایط Traffic Baseline Reset می‌شود تا اختلاف Counter قبلی و Process جدید باعث ایجاد Traffic اشتباه نشود.

History قبلی همچنان در SQLite باقی می‌ماند.

---

# رفتار هنگام Restart شدن Monitor

اگر سرویس Monitor در حالی Restart شود که یک Incident باز بوده، Event قبلی با Status مناسب بسته می‌شود.

Status ممکن است شامل مواردی مانند:

```text
ended
interrupted
service-stopped
```

باشد.

بنابراین Event نیمه‌کاره بدون وضعیت مشخص باقی نمی‌ماند.

---

# Database

Database اصلی:

```text
/var/lib/xray-user-monitor/history.db
```

SQLite با تنظیمات سبک و مناسب Monitoring استفاده می‌شود:

```text
WAL
synchronous=NORMAL
temp_store=MEMORY
busy_timeout
incremental_vacuum
```

اطلاعات اصلی در سه بخش ذخیره می‌شود:

```text
samples
user_samples
events
```

### samples

اطلاعات کلی Xray:

```text
Timestamp
PID
CPU
RAM
Threads
Total Mbps
Upload Mbps
Download Mbps
Top User
Active Users
API Status
Event ID
```

### user_samples

اطلاعات کاربران منتخب:

```text
Timestamp
Username
Xray Email
Upload Mbps
Download Mbps
Total Mbps
Online IPs
TCP Connections
```

### events

Incidentهای CPU:

```text
Start Time
End Time
Peak Time
Peak CPU
Peak Traffic
Peak User
Peak User Traffic
Peak TCP Connections
Peak Online IPs
Status
```

---

# Event Log

علاوه بر SQLite، Eventهای مهم در یک فایل کوچک نیز ثبت می‌شوند:

```text
/var/lib/xray-user-monitor/events.log
```

مشاهده:

```bash
cat /var/lib/xray-user-monitor/events.log
```

یا:

```bash
tail -f /var/lib/xray-user-monitor/events.log
```

نمونه:

```text
2026-08-11 22:43:30 EVENT_START id=6 cpu=227.7% top_user=baduser top_mbps=5.31
2026-08-11 22:45:00 EVENT_END id=6 cpu=51.2%
```

---

# Log سرویس

مشاهده آخرین Logها:

```bash
journalctl -u xray-user-monitor -n 100 --no-pager
```

نمایش Live:

```bash
journalctl -u xray-user-monitor -f
```

Logهای Boot فعلی:

```bash
journalctl -u xray-user-monitor -b
```

Boot قبلی:

```bash
journalctl -u xray-user-monitor -b -1
```

---

# بررسی اینکه Monitor بعد از Reboot فعال است

```bash
systemctl is-enabled xray-user-monitor
```

باید:

```text
enabled
```

نمایش دهد.

سپس:

```bash
systemctl is-active xray-user-monitor
```

باید:

```text
active
```

نمایش دهد.

---

# مصرف منابع

این Monitor عمداً برای اجرا روی Production Node طراحی شده است.

برای کاهش Priority سرویس از تنظیمات systemd زیر استفاده می‌شود:

```ini
Nice=15
IOSchedulingClass=idle
CPUWeight=10
IOWeight=10
OOMScoreAdjust=500
```

بنابراین در زمان فشار، سیستم منابع را ترجیحاً در اختیار Workload اصلی قرار می‌دهد.

همچنین:

- Docker دائماً اجرا نمی‌شود.
- `ss` فقط هنگام High CPU اجرا می‌شود.
- Queryها Timeout دارند.
- History محدود است.
- Top-N User ذخیره می‌شود.
- Cleanup خودکار انجام می‌شود.

---

# Security

سرویس با برخی محدودیت‌های systemd اجرا می‌شود:

```ini
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
LockPersonality=true
```

فقط مسیر زیر Write Access دارد:

```text
/var/lib/xray-user-monitor
```

و فایل‌های برنامه از:

```text
/opt/xray-user-monitor
```

به‌صورت Read-Only در اختیار سرویس هستند.

---

# Troubleshooting

## Stats API Error

بررسی کنید Xray API روی Port موردنظر Listen می‌کند:

```bash
ss -lntp | grep xray
```

در Marzban Node معمولاً چیزی شبیه زیر مشاهده می‌شود:

```text
LISTEN ... *:62051 ... users:(("xray",pid=...,fd=...))
```

Config را بررسی کنید:

```bash
cat /etc/xray-user-monitor.conf
```

---

## تست TLS API

```bash
openssl s_client \
  -connect 127.0.0.1:62051 \
  -alpn h2 \
  -brief \
  </dev/null
```

اگر Connection برقرار شود، Xray API روی TLS پاسخ می‌دهد.

---

## تست grpcurl

```bash
grpcurl --version
```

سپس:

```bash
grpcurl \
  -insecure \
  -import-path /opt/xray-user-monitor \
  -proto command.proto \
  -d '{"pattern":"user>>>","reset":false}' \
  127.0.0.1:62051 \
  xray.app.stats.command.StatsService/QueryStats
```

اگر Stats فعال باشد، باید Counterهای Userها نمایش داده شوند.

---

## Database ایجاد نشده

ابتدا وضعیت سرویس:

```bash
systemctl status xray-user-monitor --no-pager
```

سپس:

```bash
journalctl -u xray-user-monitor -n 100 --no-pager
```

بررسی مسیر:

```bash
ls -lah /var/lib/xray-user-monitor/
```

---

## xraymon پیدا نمی‌شود

بررسی:

```bash
ls -l /usr/local/bin/xraymon
```

باید Symlink به:

```text
/opt/xray-user-monitor/report.py
```

باشد.

---

## Xray Process پیدا نمی‌شود

بررسی:

```bash
pgrep -a xray
```

یا:

```bash
ps aux | grep '[x]ray'
```

Monitor به‌صورت خودکار منتظر ظاهر شدن Process Xray می‌ماند.

---

# Backup

برای Backup ساده History:

```bash
cp /var/lib/xray-user-monitor/history.db /root/xray-monitor-history.db
```

برای Backup سازگارتر زمانی که سرویس فعال است:

```bash
python3 - <<'PY'
import sqlite3

src = sqlite3.connect("/var/lib/xray-user-monitor/history.db")
dst = sqlite3.connect("/root/xray-monitor-history.db")

with dst:
    src.backup(dst)

dst.close()
src.close()

print("Backup completed.")
PY
```

---

# Reset History

> این عملیات تمام History مانیتور را حذف می‌کند.

ابتدا سرویس را Stop کنید:

```bash
systemctl stop xray-user-monitor
```

سپس:

```bash
rm -f /var/lib/xray-user-monitor/history.db
rm -f /var/lib/xray-user-monitor/history.db-wal
rm -f /var/lib/xray-user-monitor/history.db-shm
rm -f /var/lib/xray-user-monitor/events.log
```

دوباره سرویس را Start کنید:

```bash
systemctl start xray-user-monitor
```

Database جدید به‌صورت خودکار ایجاد می‌شود.

---

# حذف کامل

```bash
systemctl disable --now xray-user-monitor
```

سپس:

```bash
rm -f /etc/systemd/system/xray-user-monitor.service
systemctl daemon-reload
```

حذف برنامه:

```bash
rm -rf /opt/xray-user-monitor
```

حذف Config:

```bash
rm -f /etc/xray-user-monitor.conf
```

در صورت عدم نیاز به History:

```bash
rm -rf /var/lib/xray-user-monitor
```

حذف CLI:

```bash
rm -f /usr/local/bin/xraymon
```

`grpcurl` را فقط در صورتی حذف کنید که برنامه دیگری از آن استفاده نمی‌کند.

---

# محدودیت‌های مهم

## CPU دقیق per-user وجود ندارد

همه کاربران از یک Process مشترک:

```text
xray
```

استفاده می‌کنند.

بنابراین سیستم‌عامل اطلاعاتی مشابه زیر ندارد:

```text
ali      120% CPU
reza      40% CPU
baduser  220% CPU
```

CPU فقط برای Process Xray قابل اندازه‌گیری است.

این Monitor برای Attribution از Correlation استفاده می‌کند:

```text
Xray CPU spike
      +
User traffic spike
      +
Connection count
      +
Online IP count
      +
Exact timestamp
```

---

## TCP Connection تخمینی است

Connection attribution بر اساس IPهای آنلاین Xray و Socketهای Process انجام می‌شود.

اگر یک Public IP همزمان متعلق به چند User باشد، برای جلوگیری از Attribution اشتباه، Connection به آن User نسبت داده نمی‌شود.

این رفتار عمداً محافظه‌کارانه است.

---

## UDP

`ss` در Deep Scan فعلی روی Established TCP Connectionها تمرکز دارد.

بنابراین رفتارهای UDP ممکن است به‌اندازه TCP قابل مشاهده نباشند.

Traffic همچنان از Xray Stats ثبت می‌شود.

---

## GetUsersStats

برخی نسخه‌های Xray ممکن است API جدید `GetUsersStats` را نداشته باشند یا Online Map موردنیاز فعال نباشد.

در این حالت Monitoring اصلی قطع نمی‌شود.

ابزار همچنان از:

```text
QueryStats
```

برای Traffic استفاده می‌کند و فقط بخش Online IP / TCP enrichment ممکن است در دسترس نباشد.

---

# پیشنهاد برای Production

برای بیشتر Marzban Nodeها:

```ini
SAMPLE_INTERVAL=15

CPU_EVENT_THRESHOLD=100
CPU_CLEAR_THRESHOLD=70
EVENT_CLEAR_SAMPLES=3

TOP_USERS=10
RETENTION_DAYS=30

DEEP_SCAN_ON_HIGH_CPU=1
RPC_TIMEOUT=4
```

ترکیب مناسبی بین:

```text
Accuracy
History
Disk Usage
CPU Usage
API Load
```

ایجاد می‌کند.

---

# Workflow پیشنهادی هنگام حادثه

اگر Xray CPU بالا رفت:

```bash
xraymon status
```

اگر سرور مجبور به Reboot شد، بعد از بالا آمدن:

```bash
xraymon events 24
```

Incident را پیدا کنید:

```bash
xraymon show <EVENT-ID>
```

سپس Top Userها را بررسی کنید:

```bash
xraymon top 24
```

و برای User مشکوک:

```bash
xraymon user <USERNAME> 24
```

در نهایت این موارد را کنار هم مقایسه کنید:

```text
Peak CPU
Peak User Mbps
MAX TCP
MAX IPs
Incident Duration
Repeated Incidents
```

---

# Quick Command Reference

```bash
# Current status
xraymon status

# Live local display
watch -n 5 xraymon status

# Incidents during last 7 days
xraymon events 168

# Incident details
xraymon show 6

# Top users during last 24 hours
xraymon top 24

# Specific user history
xraymon user baduser 48

# Database size
xraymon size

# Service status
systemctl status xray-user-monitor --no-pager

# Service logs
journalctl -u xray-user-monitor -f

# Restart after config changes
systemctl restart xray-user-monitor
```

---

# Repository Structure پیشنهادی

برای GitHub می‌توانید Repository را به این شکل نگه دارید:

```text
xray-user-monitor/
├── README.md
└── install-xray-user-monitor.sh
```

---

# هدف پروژه

هدف این ابزار Block یا Limit کردن خودکار کاربران نیست.

هدف اصلی:

> **ثبت شواهد کافی با کمترین سربار ممکن، برای مشخص کردن کاربر یا رفتار مشکوک در زمان افزایش غیرعادی مصرف Xray.**

بهتر است Ban، Disable یا Limit کردن User فقط بعد از بررسی Incident و اطمینان از رفتار غیرعادی انجام شود.
