# OmniRoute — Docker Compose

استقرار محلی OmniRoute همراه Redis با نگه‌داری دائمی داده‌ها. پورت برنامه فقط روی `127.0.0.1:20128` منتشر می‌شود.

## راه‌اندازی

### Windows / PowerShell

```powershell
cd docker/omniroute
.\generate-secrets.ps1
docker compose up -d
```

### Linux

```bash
cd docker/omniroute
cp .env.example .env
sed -i "s|STORAGE_ENCRYPTION_KEY=CHANGE_ME|STORAGE_ENCRYPTION_KEY=$(openssl rand -hex 32)|" .env
sed -i "s|OMNIROUTE_WS_BRIDGE_SECRET=CHANGE_ME|OMNIROUTE_WS_BRIDGE_SECRET=$(openssl rand -base64 32 | tr -d '\n')|" .env
docker compose up -d
```

## مدیریت

```bash
docker compose ps
docker compose logs -f --tail 100
docker compose restart
docker compose pull && docker compose up -d
```

داده‌های OmniRoute و Redis داخل Volumeهای `omniroute-data` و `omniroute-redis-data` نگه‌داری می‌شوند. فایل `.env` واقعی نباید Commit شود.
