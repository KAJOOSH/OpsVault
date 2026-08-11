# MikroTik OpenVPN Server — RouterOS 7.23

تنظیم آماده OpenVPN Server برای RouterOS `7.23` با UDP/1194، `AES-256-GCM`، `SHA256`، TLS 1.2 و الزام Certificate سمت Client.

## قبل از اجرا

در فایل [`routeros-7.23-openvpn-server-10y-cert.rsc`](./routeros-7.23-openvpn-server-10y-cert.rsc) این مقادیر را متناسب با شبکه خود تغییر دهید:

- `vpn.example.com`
- `REPLACE_WITH_STRONG_OVPN_PASSWORD`
- `REPLACE_WITH_CERTIFICATE_EXPORT_PASSWORD`
- `out-interface-list=WAN` در صورت متفاوت بودن ساختار WAN
- شبکه `10.77.77.0/24` و Pool در صورت تداخل با شبکه‌های موجود

گواهی CA، Server و Client با اعتبار `3650` روز ساخته می‌شوند.

## اجرا

فایل را به RouterOS منتقل و از Terminal اجرا کنید:

```routeros
/import file-name=routeros-7.23-openvpn-server-10y-cert.rsc
```

پس از اجرا، فایل‌های PEM مربوط به CA و Client در بخش Files روتر قرار می‌گیرند و برای ساخت پروفایل Client قابل استفاده هستند.
