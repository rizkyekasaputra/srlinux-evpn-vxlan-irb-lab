#!/bin/sh
ip link del eth1.30 2>/dev/null || true
ip link del eth2.30 2>/dev/null || true
ip link del bond0 2>/dev/null || true

ip link set eth1 down
ip link set eth2 down
ip link add bond0 type bond mode 802.3ad miimon 100 lacp_rate fast xmit_hash_policy layer3+4
ip link set eth1 master bond0
ip link set eth2 master bond0
ip link set bond0 up

ip link add link bond0 name bond0.30 type vlan id 30
ip addr add 192.168.30.21/26 dev bond0.30
ip link set bond0.30 up

ip route replace 192.168.20.0/26 via 192.168.30.1 dev bond0.30
