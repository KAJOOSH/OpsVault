# Block outbound SMTP/25

این ابزار خروجی مستقیم TCP/25 را روی میزبان Linux مسدود می‌کند و Ruleهای `OUTPUT`، `FORWARD` و در صورت وجود `DOCKER-USER` را برای IPv4 و IPv6 پوشش می‌دهد. پورت‌های `465` و `587` مسدود نمی‌شوند.

## نصب

```bash
curl -fsSL "https://raw.githubusercontent.com/KAJOOSH/OpsVault/refs/heads/main/linux/firewall/smtp25/block-smtp25.sh" -o /tmp/block-smtp25.sh \
  && chmod +x /tmp/block-smtp25.sh \
  && sudo /tmp/block-smtp25.sh
```

اسکریپت `iptables-persistent` و `netfilter-persistent` را نصب می‌کند، Ruleها را اعمال می‌کند و آن‌ها را برای راه‌اندازی مجدد سیستم ذخیره می‌کند.

## لایه Xray

اگر ترافیک Xray ممکن است از WARP، SOCKS یا تونل دیگری خارج شود، Rule زیر را قبل از Ruleهای عمومی `DIRECT/WARP/PROXY` قرار دهید:

```json
{
  "type": "field",
  "network": "tcp",
  "port": "25",
  "outboundTag": "BLOCK"
}
```

و Outbound زیر وجود داشته باشد:

```json
{
  "protocol": "blackhole",
  "tag": "BLOCK"
}
```

## بررسی Ruleها

```bash
sudo iptables -L OUTPUT -n -v --line-numbers
sudo iptables -L FORWARD -n -v --line-numbers
sudo iptables -L DOCKER-USER -n -v --line-numbers 2>/dev/null || true
sudo ip6tables -L OUTPUT -n -v --line-numbers
sudo ip6tables -L FORWARD -n -v --line-numbers
```
