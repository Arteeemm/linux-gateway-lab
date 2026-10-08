#!/usr/bin/env bash
# Настраивает Ubuntu Server как шлюз для изолированной сети:
# статический IP на LAN, DHCP (dnsmasq), IP forwarding, NAT и фаервол через ufw.
# Запуск: sudo ./setup.sh   (интерфейсы можно переопределить: sudo LAN_IF=enp0s9 ./setup.sh)
#
# NAT и фаервол настраивает один инструмент — ufw. Пакеты ufw и iptables-persistent
# в Ubuntu конфликтуют: установка одного удаляет другой, и правила перестают
# восстанавливаться после перезагрузки.
set -euo pipefail

LAN_IF="${LAN_IF:-enp0s8}"   # смотрит в Internal Network (клиенты)
WAN_IF="${WAN_IF:-enp0s3}"   # смотрит в NAT VirtualBox (интернет)
LAN_NET="192.168.50.0/24"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

[[ $EUID -eq 0 ]] || { echo "Запусти через sudo"; exit 1; }
for i in "$LAN_IF" "$WAN_IF"; do
  ip link show "$i" >/dev/null 2>&1 || { echo "Нет интерфейса $i (проверь: ip a)"; exit 1; }
done

echo "==> 1/6 Статический IP на $LAN_IF"
sed "s/enp0s8/$LAN_IF/" "$REPO_DIR/configs/netplan/60-lab.yaml" > /etc/netplan/60-lab.yaml
chmod 600 /etc/netplan/60-lab.yaml
netplan apply

echo "==> 2/6 Конфиг dnsmasq (до установки, чтобы он не конфликтовал с systemd-resolved за порт 53)"
mkdir -p /etc/dnsmasq.d
sed "s/enp0s8/$LAN_IF/" "$REPO_DIR/configs/dnsmasq/lab.conf" > /etc/dnsmasq.d/lab.conf

echo "==> 3/6 Пакеты"
apt-get update -q
DEBIAN_FRONTEND=noninteractive apt-get install -y -q dnsmasq ufw tcpdump conntrack
systemctl enable dnsmasq
systemctl restart dnsmasq

echo "==> 4/6 IP forwarding"
install -m 644 "$REPO_DIR/configs/sysctl/99-forward.conf" /etc/sysctl.d/99-forward.conf
sysctl -p /etc/sysctl.d/99-forward.conf
# ufw при включении применяет свой файл настроек ядра и сбрасывает forwarding
sed -i 's|^#\?net/ipv4/ip_forward=.*|net/ipv4/ip_forward=1|' /etc/ufw/sysctl.conf

echo "==> 5/6 NAT в /etc/ufw/before.rules"
if ! grep -q 'linux-gateway-lab NAT' /etc/ufw/before.rules; then
  NAT_BLOCK=$(cat <<NAT
# linux-gateway-lab NAT (BEGIN)
*nat
:POSTROUTING ACCEPT [0:0]
-F POSTROUTING
-A POSTROUTING -s $LAN_NET -o $WAN_IF -j MASQUERADE
COMMIT
# linux-gateway-lab NAT (END)

NAT
)
  printf '%s\n%s\n' "$NAT_BLOCK" "$(cat /etc/ufw/before.rules)" > /etc/ufw/before.rules
fi

echo "==> 6/6 Правила ufw"
ufw default deny incoming
ufw default allow outgoing
ufw default deny routed
ufw allow 22/tcp                                            # до enable, иначе отрежешь себе SSH
ufw allow in on "$LAN_IF" to any port 67 proto udp         # DHCP-запросы клиентов
ufw route allow in on "$LAN_IF" out on "$WAN_IF"           # пересылка LAN -> интернет
ufw --force enable
ufw reload

echo
echo "==> Проверка"
ip -4 addr show "$LAN_IF" | grep inet
echo "dnsmasq: $(systemctl is-active dnsmasq)"
echo "ip_forward: $(cat /proc/sys/net/ipv4/ip_forward)"
iptables -t nat -S POSTROUTING | grep MASQUERADE
ufw status verbose
