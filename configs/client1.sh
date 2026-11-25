#!/bin/sh
ip link set eth1 up
ip link set eth2 up

# Konfigurasi VLAN 20 pada eth1 (ke srl1)
ip link add link eth1 name eth1.20 type vlan id 20
ip addr add 192.168.20.11/26 dev eth1.20
ip link set eth1.20 up

# Link cadangan ke srl2 (dinonaktifkan sementara sebelum ESI-LAG aktif)
ip link add link eth2 name eth2.20 type vlan id 20
ip addr add 192.168.20.12/26 dev eth2.20
ip link set eth2.20 down

# Rute menuju VLAN 30 via Anycast Gateway
ip route replace 192.168.30.0/26 via 192.168.20.1 dev eth1.20
