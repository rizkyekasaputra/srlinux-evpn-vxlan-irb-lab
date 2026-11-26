# 02 - Symmetric IRB with ESI-LAG (Nokia SR Linux + Clabernetes)

Lab ini mengimplementasikan arsitektur **L3 VXLAN EVPN Symmetric Integrated Routing and Bridging (IRB)** dengan multihoming **ESI-LAG** pada dua *switch* Nokia SR Linux (`srl1` dan `srl2`) yang terhubung ke dua *client* Linux (`client1` dan `client2`) di Clabernetes.

## Topologi & Pemetaan Jaringan

### Perangkat & Interface
* **Switches:** `srl1` (`10.100.0.1/32` loopback/system) dan `srl2` (`10.100.0.2/32` loopback/system)
* **Switch LAG & ESI:**
  * `lag1` (anggota `ethernet-1/1` & `ethernet-1/2`, LACP aktif, `ES-CLIENT1` ESI `00:11:11:11:11:11:11:11:11:01` mode `all-active`), subinterface `lag1.20` (VLAN `20` -> `mac-vrf-x`)
  * `lag2` (anggota `ethernet-1/1` & `ethernet-1/2`, LACP aktif, `ES-CLIENT2` ESI `00:22:22:22:22:22:22:22:22:02` mode `all-active`), subinterface `lag2.30` (VLAN `30` -> `mac-vrf-y`)
* **Clients:** `client1` dan `client2` (`bond0` mode `balance-xor`, `xmit_hash_policy layer3+4`, *slave* `eth1` & `eth2`)

### Network Instances, VNI, & Gateway
| Network Instance | Tipe | VNI / EVI | Subinterface / VXLAN | IP / Subnet |
| :--- | :--- | :--- | :--- | :--- |
| `mac-vrf-x` | `mac-vrf` | VNI `20` | `lag1.20`, `vxlan1.20`, `irb0.1` | VLAN 20 (`192.168.20.0/26`) |
| `mac-vrf-y` | `mac-vrf` | VNI `30` | `lag2.30`, `vxlan1.30`, `irb0.2` | VLAN 30 (`192.168.30.0/26`) |
| `ip-vrf-red` | `ip-vrf` | VNI / EVI `1001` | `irb0.1`, `irb0.2`, `vxlan1.1001` | Anycast GW `192.168.20.1/26` & `192.168.30.1/26` |
| `default` | `default` | — | `ethernet-1/49.0`..`51.0`, `system0.0` | Underlay & BGP EVPN (`AS 65001`) |

### Alamat IP Client & Static Route
* **`client1` (`bond0.20`, VLAN 20):**
  * IP: `192.168.20.11/26`
  * Route ke subnet remote: `192.168.30.0/26 via 192.168.20.1 dev bond0.20`
* **`client2` (`bond0.30`, VLAN 30):**
  * IP: `192.168.30.21/26`
  * Route ke subnet remote: `192.168.20.0/26 via 192.168.30.1 dev bond0.30`

## Perubahan Konfigurasi Utama

### 1. LACP, Subinterface LAG, & Ethernet Segments (`ES-CLIENT1` / `ES-CLIENT2`) di `srl1` & `srl2`
Di SR Linux, `vlan-tagging` diletakkan pada interface `lag1` dan `lag2` (bukan pada port anggota `ethernet-1/1` / `ethernet-1/2` agar tidak bentrok dengan `aggregate-id`). Selain itu, `lag-type lacp` wajib diaktifkan pada blok `lag` agar LACP berjalan dinamis, dan `ethernet-segments` (`all-active`) wajib dipasang agar rute EVPN Type-1/Type-4 serta *split horizon* aktif.

Jalankan pada `srl1` dan `srl2`:

```text
enter candidate

delete / interface ethernet-1/1 vlan-tagging
delete / interface ethernet-1/2 vlan-tagging

set / interface ethernet-1/1 ethernet aggregate-id lag1
set / interface lag1 admin-state enable
set / interface lag1 vlan-tagging true
set / interface lag1 lag lag-type lacp
set / interface lag1 lag lacp lacp-mode ACTIVE
set / interface lag1 lag lacp interval FAST
set / interface lag1 lag lacp admin-key 1
set / interface lag1 lag lacp system-id-mac 00:00:00:00:00:01
set / interface lag1 subinterface 20 type bridged
set / interface lag1 subinterface 20 admin-state enable
set / interface lag1 subinterface 20 vlan encap single-tagged vlan-id 20
set / network-instance mac-vrf-x interface lag1.20

set / interface ethernet-1/2 ethernet aggregate-id lag2
set / interface lag2 admin-state enable
set / interface lag2 vlan-tagging true
set / interface lag2 lag lag-type lacp
set / interface lag2 lag lacp lacp-mode ACTIVE
set / interface lag2 lag lacp interval FAST
set / interface lag2 lag lacp admin-key 2
set / interface lag2 lag lacp system-id-mac 00:00:00:00:00:02
set / interface lag2 subinterface 30 type bridged
set / interface lag2 subinterface 30 admin-state enable
set / interface lag2 subinterface 30 vlan encap single-tagged vlan-id 30
set / network-instance mac-vrf-y interface lag2.30

set / system network-instance protocols evpn ethernet-segments bgp-instance 1 ethernet-segment ES-CLIENT1 admin-state enable
set / system network-instance protocols evpn ethernet-segments bgp-instance 1 ethernet-segment ES-CLIENT1 esi 00:11:11:11:11:11:11:11:11:01
set / system network-instance protocols evpn ethernet-segments bgp-instance 1 ethernet-segment ES-CLIENT1 interface lag1
set / system network-instance protocols evpn ethernet-segments bgp-instance 1 ethernet-segment ES-CLIENT1 multi-homing-mode all-active

set / system network-instance protocols evpn ethernet-segments bgp-instance 1 ethernet-segment ES-CLIENT2 admin-state enable
set / system network-instance protocols evpn ethernet-segments bgp-instance 1 ethernet-segment ES-CLIENT2 esi 00:22:22:22:22:22:22:22:22:02
set / system network-instance protocols evpn ethernet-segments bgp-instance 1 ethernet-segment ES-CLIENT2 interface lag2
set / system network-instance protocols evpn ethernet-segments bgp-instance 1 ethernet-segment ES-CLIENT2 multi-homing-mode all-active

set / system network-instance protocols bgp-vpn bgp-instance 1

commit stay save
```

### 2. Bonding & VLAN Subinterface di `client1` & `client2`
Bersihkan dulu `master` dan `bond0` lama sebelum membuat ulang dengan mode `balance-xor` (`layer3+4`) agar tidak terjadi `RTNETLINK answers: Directory not empty` dan kedua *slave* (`eth1` & `eth2`) dapat meneruskan trafik secara aktif pada lingkungan `veth` Clabernetes:

```bash
kubectl exec deploy/client1 -- sh -c "
ip link set eth1 nomaster 2>/dev/null || true
ip link set eth2 nomaster 2>/dev/null || true
ip link del bond0 2>/dev/null || true
ip link add bond0 type bond mode balance-xor xmit_hash_policy layer3+4
ip link set eth1 down && ip link set eth1 master bond0 && ip link set eth1 up
ip link set eth2 down && ip link set eth2 master bond0 && ip link set eth2 up
ip link set bond0 up
ip link add link bond0 name bond0.20 type vlan id 20
ip link set bond0.20 up
ip addr add 192.168.20.11/26 dev bond0.20
ip route replace 192.168.30.0/26 via 192.168.20.1 dev bond0.20
"

kubectl exec deploy/client2 -- sh -c "
ip link set eth1 nomaster 2>/dev/null || true
ip link set eth2 nomaster 2>/dev/null || true
ip link del bond0 2>/dev/null || true
ip link add bond0 type bond mode balance-xor xmit_hash_policy layer3+4
ip link set eth1 down && ip link set eth1 master bond0 && ip link set eth1 up
ip link set eth2 down && ip link set eth2 master bond0 && ip link set eth2 up
ip link set bond0 up
ip link add link bond0 name bond0.30 type vlan id 30
ip link set bond0.30 up
ip addr add 192.168.30.21/26 dev bond0.30
ip route replace 192.168.20.0/26 via 192.168.30.1 dev bond0.30
"
```

## Validasi & Troubleshooting

### 1. Cek LAG, ESI, MAC Table, BGP, & Route Table di SR Linux
```bash
kubectl exec deploy/srl1 -- sr_cli "show lag"
kubectl exec deploy/srl2 -- sr_cli "show lag"
kubectl exec deploy/srl1 -- sr_cli "show network-instance mac-vrf-x bridge-table mac-table all"
kubectl exec deploy/srl2 -- sr_cli "show network-instance mac-vrf-y bridge-table mac-table all"
kubectl exec deploy/srl1 -- sr_cli "show network-instance default protocols bgp summary"
kubectl exec deploy/srl1 -- sr_cli "show network-instance ip-vrf-red route-table ipv4-unicast summary"
```

### 2. Validasi Ping Lintas Subnet, ARP Gateway, & Failover Slave
```bash
kubectl exec deploy/client1 -- ping -c 4 -W 2 192.168.30.21
kubectl exec deploy/client2 -- ping -c 4 -W 2 192.168.20.11
kubectl exec deploy/client1 -- ip neigh show dev bond0.20
kubectl exec deploy/client2 -- ip neigh show dev bond0.30

# Uji failover saat salah satu slave di-down-kan lalu nyalakan kembali
kubectl exec deploy/client1 -- ip link set eth1 down
kubectl exec deploy/client1 -- ping -c 4 -W 2 192.168.30.21
kubectl exec deploy/client1 -- ip link set eth1 up
```

### Catatan Troubleshooting
* **ESI & LACP dinamis:** Tanpa `lag-type lacp` dan `ethernet-segments` (`all-active`), LACP di SR Linux belum berjalan dinamis dan *split horizon* EVPN belum aktif sehingga rawan paket ganda (`DUP!`) atau perilaku multihoming yang tidak konsisten.
* **Hapus `bond0` sebelum ganti mode:** Selalu lepas `eth1`/`eth2` (`nomaster`) dan `ip link del bond0` sebelum membuat ulang `bond0` dengan mode berbeda.
* **Sintaks `sr_cli` non-interactive:** Perintah `ping <ip> network-instance <ni> -c <n>` hanya berlaku di mode interaktif; gunakan `ip netns exec srbase-<ni> ping ...` atau jalankan `ping` langsung dari pod `client`.
