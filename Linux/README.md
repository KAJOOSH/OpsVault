# SMTP Port 25 Block

Permanently blocks outbound TCP/25 on a server.

The firewall rules cover:

- Host/Xray outbound traffic
- Forwarded traffic
- Docker `DOCKER-USER`
- IPv4
- IPv6
- Persistent rules after reboot

Ports `465` and `587` are not blocked.

## Install

```bash
curl -fsSL "https://raw.githubusercontent.com/KAJOOSH/OpsVault/refs/heads/main/Linux/block-smtp25.sh" -o /tmp/block-smtp25.sh && chmod +x /tmp/block-smtp25.sh && sudo /tmp/block-smtp25.sh
```

## Xray Rule

It is recommended to also block TCP/25 at the Xray routing layer, especially when traffic may leave through WARP, SOCKS, or another tunnel.

Add this rule **before general DIRECT/WARP/PROXY routing rules**:

```json
{
  "type": "field",
  "network": "tcp",
  "port": "25",
  "outboundTag": "BLOCK"
}
```

Make sure a `BLOCK` outbound exists:

```json
{
  "protocol": "blackhole",
  "tag": "BLOCK"
}
```

Example:

```json
{
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "DIRECT"
    },
    {
      "protocol": "blackhole",
      "tag": "BLOCK"
    }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "network": "tcp",
        "port": "25",
        "outboundTag": "BLOCK"
      }
    ]
  }
}
```

## Verify

```bash
sudo iptables -L OUTPUT -n -v --line-numbers
sudo iptables -L FORWARD -n -v --line-numbers
sudo iptables -L DOCKER-USER -n -v --line-numbers

sudo ip6tables -L OUTPUT -n -v --line-numbers
sudo ip6tables -L FORWARD -n -v --line-numbers
```

The packet counter on the TCP/25 rule increases when a process or forwarded connection attempts direct SMTP traffic.
