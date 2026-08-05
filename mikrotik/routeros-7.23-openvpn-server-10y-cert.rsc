/certificate add name=OVPN-Root-CA-Authority-10Y common-name="MikroTik OpenVPN Root Certificate Authority 10Y" organization="Private Network Infrastructure" unit="OpenVPN Certificate Authority" key-size=4096 digest-algorithm=sha384 days-valid=3650 key-usage=key-cert-sign,crl-sign

/certificate sign OVPN-Root-CA-Authority-10Y

/certificate set [find where name="OVPN-Root-CA-Authority-10Y"] trusted=yes trust-store=ovpn

/certificate add name=OVPN-Server-TLS-Certificate-10Y common-name=vpn.example.com subject-alt-name=DNS:vpn.example.com organization="Private Network Infrastructure" unit="OpenVPN Remote Access Server" key-size=4096 digest-algorithm=sha384 days-valid=3650 key-usage=digital-signature,key-encipherment,tls-server

/certificate sign OVPN-Server-TLS-Certificate-10Y ca=OVPN-Root-CA-Authority-10Y

/certificate add name=OVPN-Administrator-Client-Certificate-10Y common-name=ovpn-administrator-client organization="Private Network Infrastructure" unit="OpenVPN Authorized Remote Client" key-size=4096 digest-algorithm=sha384 days-valid=3650 key-usage=digital-signature,tls-client

/certificate sign OVPN-Administrator-Client-Certificate-10Y ca=OVPN-Root-CA-Authority-10Y

/interface list add name=OVPN-Remote-Access-Interfaces comment="Dynamic interfaces created for authenticated OpenVPN clients"

/ip pool add name=OVPN-Remote-Client-Address-Pool ranges=10.77.77.10-10.77.77.250 comment="IPv4 address pool assigned to authenticated OpenVPN clients"

/ppp profile add name=OVPN-Remote-Access-User-Profile local-address=10.77.77.1 remote-address=OVPN-Remote-Client-Address-Pool dns-server=1.1.1.1,9.9.9.9 interface-list=OVPN-Remote-Access-Interfaces only-one=yes change-tcp-mss=yes comment="Secure profile for OpenVPN remote access users"

/ppp secret add name=ovpn-admin password="REPLACE_WITH_STRONG_OVPN_PASSWORD" service=ovpn profile=OVPN-Remote-Access-User-Profile comment="Authorized OpenVPN administrator account"

/interface ovpn-server server add name=OVPN-Remote-Access-Server disabled=no protocol=udp port=1194 mode=ip netmask=24 max-mtu=1400 keepalive-timeout=30 reneg-sec=3600 default-profile=OVPN-Remote-Access-User-Profile certificate=OVPN-Server-TLS-Certificate-10Y require-client-certificate=yes auth=sha256 cipher=aes256-gcm tls-version=only-1.2 user-auth-method=pap redirect-gateway=def1 vrf=main comment="Secure OpenVPN UDP remote access server"

/ip firewall filter add chain=input action=accept protocol=udp dst-port=1194 comment="OVPN - Allow UDP 1194 connections"

/ip firewall filter add chain=input action=accept in-interface-list=OVPN-Remote-Access-Interfaces src-address=10.77.77.0/24 comment="OVPN - Allow authenticated clients to access router"

/ip firewall filter add chain=forward action=accept in-interface-list=OVPN-Remote-Access-Interfaces src-address=10.77.77.0/24 comment="OVPN - Allow authenticated clients to access networks and internet"

/ip firewall filter add chain=forward action=accept out-interface-list=OVPN-Remote-Access-Interfaces dst-address=10.77.77.0/24 connection-state=established,related comment="OVPN - Allow established traffic back to authenticated clients"

/ip firewall filter add chain=forward action=accept in-interface-list=OVPN-Remote-Access-Interfaces src-address=10.77.77.0/24 dst-address=192.168.88.0/24 comment="OVPN - Allow authenticated clients to access internal LAN"

/ip firewall filter add chain=forward action=accept src-address=192.168.88.0/24 out-interface-list=OVPN-Remote-Access-Interfaces dst-address=10.77.77.0/24 comment="OVPN - Allow internal LAN to access authenticated clients"

/ip firewall filter move [find where comment="OVPN - Allow UDP 1194 connections"] 0

/ip firewall filter move [find where comment="OVPN - Allow authenticated clients to access router"] 0

/ip firewall filter move [find where comment="OVPN - Allow authenticated clients to access networks and internet"] 0

/ip firewall filter move [find where comment="OVPN - Allow established traffic back to authenticated clients"] 0

/ip firewall filter move [find where comment="OVPN - Allow authenticated clients to access internal LAN"] 0

/ip firewall filter move [find where comment="OVPN - Allow internal LAN to access authenticated clients"] 0

/ip firewall nat add chain=srcnat action=masquerade src-address=10.77.77.0/24 out-interface-list=WAN comment="OVPN - Masquerade authenticated client internet traffic"

/certificate export-certificate OVPN-Root-CA-Authority-10Y type=pem file-name=OVPN-Root-CA-Authority-10Y

/certificate export-certificate OVPN-Administrator-Client-Certificate-10Y type=pem export-passphrase="REPLACE_WITH_CERTIFICATE_EXPORT_PASSWORD" file-name=OVPN-Administrator-Client-Certificate-10Y

/certificate print detail where name~"OVPN"

/interface ovpn-server server print detail where name="OVPN-Remote-Access-Server"

/ppp profile print detail where name="OVPN-Remote-Access-User-Profile"

/ppp secret print detail where name="ovpn-admin"

/ip firewall filter print where comment~"OVPN"

/ip firewall nat print where comment~"OVPN"
