# MikroTik RouterOS 7.23 - OpenVPN Server
# UDP/1194, AES-256-GCM, SHA256, TLS 1.2, client certificate required
# Change the placeholders before running.

/certificate
add name=OpsVault-OVPN-Root-CA common-name=OpsVault-OVPN-Root-CA key-usage=key-cert-sign,crl-sign days-valid=3650
sign OpsVault-OVPN-Root-CA name=OpsVault-OVPN-Root-CA
add name=OpsVault-OVPN-Server common-name=vpn.example.com subject-alt-name=DNS:vpn.example.com key-usage=digital-signature,key-encipherment,tls-server days-valid=3650
sign OpsVault-OVPN-Server ca=OpsVault-OVPN-Root-CA name=OpsVault-OVPN-Server
add name=OpsVault-OVPN-Client common-name=OpsVault-OVPN-Client key-usage=tls-client days-valid=3650
sign OpsVault-OVPN-Client ca=OpsVault-OVPN-Root-CA name=OpsVault-OVPN-Client

/ip pool
add name=OpsVault-OVPN-Pool ranges=10.77.77.10-10.77.77.250

/ppp profile
add name=OpsVault-OVPN-Profile local-address=10.77.77.1 remote-address=OpsVault-OVPN-Pool use-encryption=required

/ppp secret
add name=OpsVault-OVPN-User password=REPLACE_WITH_STRONG_OVPN_PASSWORD profile=OpsVault-OVPN-Profile service=ovpn

/interface ovpn-server server
set enabled=yes port=1194 protocol=udp mode=ip netmask=24 certificate=OpsVault-OVPN-Server require-client-certificate=yes auth=sha256 cipher=aes256-gcm tls-version=only-1.2

/ip firewall filter
add chain=input action=accept protocol=udp dst-port=1194 comment="Allow OpenVPN UDP 1194"

/ip firewall nat
add chain=srcnat action=masquerade src-address=10.77.77.0/24 out-interface-list=WAN comment="OpenVPN clients to WAN"

/certificate
export-certificate OpsVault-OVPN-Root-CA type=pem
export-certificate OpsVault-OVPN-Client type=pem export-passphrase=REPLACE_WITH_CERTIFICATE_EXPORT_PASSWORD
