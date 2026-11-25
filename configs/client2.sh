#!/bin/sh
ip link set eth1 up
ip link set eth2 up

# Konfigurasi VLAN 30 pada eth1 (ke srl1:e1-2)
ip link add link eth1 name eth1.30 type vlan id 30
ip addr add 192.168.30.21/26 dev eth1.30
ip link set eth1.30 up

# Link cadangan ke srl2:e1-2 (dinonaktifkan sementara sebelum ESI-LAG aktif)
ip link add link eth2 name eth2.30 type vlan id 30
ip addr add 192.168.30.22/26 dev eth2.30
ip link set eth2.30 down

# Rute menuju VLAN 20 via Anycast Gateway
ip route replace 192.168.20.0/26 via 192.168.30.1 dev eth1.30
