#!/usr/bin/env bash
# Настраивает Ubuntu Server как шлюз для изолированной сети:
# статический IP на LAN, DHCP (dnsmasq), IP forwarding, NAT (MASQUERADE).
# Запуск: sudo ./setup.sh   (интерфейсы можно переопределить: sudo LAN_IF=enp0s9 ./setup.sh)
set -euo pipefail

LAN_IF="${LAN_IF:-enp0s8}"   # смотрит в Internal Network (клиенты)
WAN_IF="${WAN_IF:-enp0s3}"   # смотрит в NAT VirtualBox (интернет)
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

[[ $EUID -eq 0 ]] || { echo "Запусти через sudo"; exit 1; }
for i in "$LAN_IF" "$WAN_IF"; do
  ip link show "$i" >/dev/null 2>&1 || { echo "Нет интерфейса $i (проверь: ip a)"; exit 1; }
done

echo "==> 1/5 Статический IP на $LAN_IF"
sed "s/enp0s8/$LAN_IF/" "$REPO_DIR/configs/netplan/60-lab.yaml" > /etc/netplan/60-lab.yaml
chmod 600 /etc/netplan/60-lab.yaml
netplan apply

echo "==> 2/5 Конфиг dnsmasq (до установки, чтобы он не конфликтовал с systemd-resolved за порт 53)"
mkdir -p /etc/dnsmasq.d
sed "s/enp0s8/$LAN_IF/" "$REPO_DIR/configs/dnsmasq/lab.conf" > /etc/dnsmasq.d/lab.conf

echo "==> 3/5 Пакеты"
echo "iptables-persistent iptables-persistent/autosave_v4 boolean false" | debconf-set-selections
echo "iptables-persistent iptables-persistent/autosave_v6 boolean false" | debconf-set-selections
apt-get update -q
DEBIAN_FRONTEND=noninteractive apt-get install -y -q dnsmasq iptables-persistent tcpdump conntrack
systemctl enable dnsmasq
systemctl restart dnsmasq

echo "==> 4/5 IP forwarding"
install -m 644 "$REPO_DIR/configs/sysctl/99-forward.conf" /etc/sysctl.d/99-forward.conf
sysctl -p /etc/sysctl.d/99-forward.conf

echo "==> 5/5 NAT через $WAN_IF"
iptables -t nat -C POSTROUTING -o "$WAN_IF" -j MASQUERADE 2>/dev/null \
  || iptables -t nat -A POSTROUTING -o "$WAN_IF" -j MASQUERADE
netfilter-persistent save

echo
echo "==> Проверка"
ip -4 addr show "$LAN_IF" | grep inet
echo "dnsmasq: $(systemctl is-active dnsmasq)"
echo "ip_forward: $(cat /proc/sys/net/ipv4/ip_forward)"
iptables -t nat -S POSTROUTING | grep MASQUERADE
