#!/bin/bash
# =============================================================================
# WireGuard Open NAT Installer - Universal Gaming (All Ports)
# Ubuntu 22.04 VPS
# =============================================================================
# This script:
#   1. Installs pivpn with WireGuard
#   2. Creates a player1 client (IP: 10.221.144.2)
#   3. Forwards ports 1024-51819 and 51821-65535 TCP+UDP (skips WG port 51820)
#   4. Persists all rules across reboots
#
# USAGE:
#   curl -fsSL <raw_url> | sudo bash
# =============================================================================

set -e

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── Root check ────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Please run as root: sudo bash or sudo ./wg-gaming-install.sh"

# ── Detect network interface and public IP ────────────────────────────────────
PUB_IFACE=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $5; exit}')
[[ -z "$PUB_IFACE" ]] && error "Could not detect public network interface."
PUB_IP=$(ip -4 addr show "$PUB_IFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
[[ -z "$PUB_IP" ]] && error "Could not detect public IP on ${PUB_IFACE}."

# ── Config values ─────────────────────────────────────────────────────────────
WG_CONF="/etc/wireguard/wg0.conf"
WG_NET="10.221.144.0/24"
WG_SERVER_IP="10.221.144.1"
PLAYER1_IP="10.221.144.2"
WG_PORT="51820"
CLIENT_NAME="player1"

echo ""
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  WireGuard Universal Gaming Open NAT Installer"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  Public interface : ${GREEN}${PUB_IFACE}${NC}"
echo -e "  Public IP        : ${GREEN}${PUB_IP}${NC}"
echo -e "  WireGuard subnet : ${GREEN}${WG_NET}${NC}"
echo -e "  Server WG IP     : ${GREEN}${WG_SERVER_IP}${NC}"
echo -e "  Player1 WG IP    : ${GREEN}${PLAYER1_IP}${NC}"
echo -e "  WireGuard port   : ${GREEN}${WG_PORT}${NC}"
echo -e "  Forwarded ports  : ${GREEN}1024-51819 and 51821-65535 TCP+UDP${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
read -rp "Proceed? [y/N]: " CONFIRM
[[ ! "$CONFIRM" =~ ^[Yy]$ ]] && { info "Aborted."; exit 0; }

# ── Step 1: System update ─────────────────────────────────────────────────────
info "Updating package lists..."
apt-get update -qq
success "Package lists updated."

# ── Step 2: Install dependencies ──────────────────────────────────────────────
info "Installing WireGuard and iptables-persistent..."
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    wireguard wireguard-tools iptables-persistent qrencode > /dev/null 2>&1
success "Dependencies installed."

# ── Step 3: Enable IP forwarding ─────────────────────────────────────────────
info "Enabling IP forwarding..."
grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf || \
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
grep -q "^net.ipv6.conf.all.forwarding=1" /etc/sysctl.conf || \
    echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
sysctl -p > /dev/null
success "IP forwarding enabled."

# ── Step 4: Install pivpn non-interactively ───────────────────────────────────
info "Installing pivpn (this may take a minute)..."
export PIVPN_UNATTENDED=1

PIVPN_ANSWERS=$(mktemp)
cat > "$PIVPN_ANSWERS" <<EOF
IPv4dev=${PUB_IFACE}
IPv4addr=${PUB_IP}
IPv4gw=$(ip route | grep default | awk '{print $3}' | head -1)
pivpnProto=wireguard
pivpnPORT=${WG_PORT}
pivpnDNS1=1.1.1.1
pivpnDNS2=8.8.8.8
pivpnSEARCHDOMAIN=
pivpnHOST=${PUB_IP}
pivpnPERSISTENTKEEPALIVE=25
UNATTUPG=1
EOF

curl -fsSL https://install.pivpn.io -o /tmp/pivpn-install.sh
bash /tmp/pivpn-install.sh --unattended "$PIVPN_ANSWERS" > /tmp/pivpn-install.log 2>&1 || {
    warn "pivpn unattended install may have had issues — checking if WireGuard config exists..."
}
sleep 3

# ── Step 5: Verify or manually create WireGuard config ───────────────────────
if [[ ! -f "$WG_CONF" ]]; then
    warn "Falling back to manual WireGuard setup..."
    mkdir -p /etc/wireguard
    chmod 700 /etc/wireguard
    cd /etc/wireguard
    umask 077
    wg genkey | tee server_private.key | wg pubkey > server_public.key
    SERVER_PRIVKEY=$(cat server_private.key)

    cat > "$WG_CONF" <<EOF
[Interface]
PrivateKey = ${SERVER_PRIVKEY}
Address = ${WG_SERVER_IP}/24
MTU = 1420
ListenPort = ${WG_PORT}
EOF
    success "Manual WireGuard config created."
fi

# ── Step 6: Generate player1 keys and client config ───────────────────────────
info "Generating player1 keys..."
cd /etc/wireguard
umask 077
wg genkey | tee player1_private.key | wg pubkey > player1_public.key
wg genpsk > player1_psk.key

PLAYER1_PRIVKEY=$(cat player1_private.key)
PLAYER1_PUBKEY=$(cat player1_public.key)
PLAYER1_PSK=$(cat player1_psk.key)
SERVER_PRIVKEY=$(grep PrivateKey "$WG_CONF" | awk '{print $3}')
SERVER_PUBKEY=$(echo "$SERVER_PRIVKEY" | wg pubkey)

mkdir -p /etc/wireguard/configs
cat > "/etc/wireguard/configs/${CLIENT_NAME}.conf" <<EOF
[Interface]
PrivateKey = ${PLAYER1_PRIVKEY}
Address = ${PLAYER1_IP}/24
DNS = 1.1.1.1

[Peer]
PublicKey = ${SERVER_PUBKEY}
PresharedKey = ${PLAYER1_PSK}
Endpoint = ${PUB_IP}:${WG_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
success "player1 client config saved to /etc/wireguard/configs/${CLIENT_NAME}.conf"

# ── Step 7: Write complete wg0.conf with NAT + port forward rules ─────────────
info "Writing wg0.conf with universal port forwarding (1024-51819, 51821-65535)..."

SERVER_PRIVKEY=$(grep PrivateKey "$WG_CONF" | awk '{print $3}')

cat > "$WG_CONF" <<EOF
[Interface]
PrivateKey = ${SERVER_PRIVKEY}
Address = ${WG_SERVER_IP}/24
MTU = 1420
ListenPort = ${WG_PORT}

# ── NAT ───────────────────────────────────────────────────────────────────────
PostUp = iptables -t nat -A POSTROUTING -s ${WG_NET} -o ${PUB_IFACE} -j MASQUERADE
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT
PostUp = iptables -A FORWARD -o wg0 -j ACCEPT

# ── TCP port forwards (skipping WireGuard port 51820) ────────────────────────
PostUp = iptables -t nat -A PREROUTING -i ${PUB_IFACE} -p tcp --dport 1024:51819 -j DNAT --to-dest ${PLAYER1_IP}
PostUp = iptables -t nat -A PREROUTING -i ${PUB_IFACE} -p tcp --dport 51821:65535 -j DNAT --to-dest ${PLAYER1_IP}

# ── UDP port forwards (skipping WireGuard port 51820) ────────────────────────
PostUp = iptables -t nat -A PREROUTING -i ${PUB_IFACE} -p udp --dport 1024:51819 -j DNAT --to-dest ${PLAYER1_IP}
PostUp = iptables -t nat -A PREROUTING -i ${PUB_IFACE} -p udp --dport 51821:65535 -j DNAT --to-dest ${PLAYER1_IP}

# ── NAT teardown ──────────────────────────────────────────────────────────────
PostDown = iptables -t nat -D POSTROUTING -s ${WG_NET} -o ${PUB_IFACE} -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT
PostDown = iptables -D FORWARD -o wg0 -j ACCEPT

# ── TCP teardown ──────────────────────────────────────────────────────────────
PostDown = iptables -t nat -D PREROUTING -i ${PUB_IFACE} -p tcp --dport 1024:51819 -j DNAT --to-dest ${PLAYER1_IP}
PostDown = iptables -t nat -D PREROUTING -i ${PUB_IFACE} -p tcp --dport 51821:65535 -j DNAT --to-dest ${PLAYER1_IP}

# ── UDP teardown ──────────────────────────────────────────────────────────────
PostDown = iptables -t nat -D PREROUTING -i ${PUB_IFACE} -p udp --dport 1024:51819 -j DNAT --to-dest ${PLAYER1_IP}
PostDown = iptables -t nat -D PREROUTING -i ${PUB_IFACE} -p udp --dport 51821:65535 -j DNAT --to-dest ${PLAYER1_IP}

### begin ${CLIENT_NAME} ###
[Peer]
PublicKey = ${PLAYER1_PUBKEY}
PresharedKey = ${PLAYER1_PSK}
AllowedIPs = ${PLAYER1_IP}/32
### end ${CLIENT_NAME} ###
EOF
success "wg0.conf written."

# ── Step 8: Configure UFW ─────────────────────────────────────────────────────
if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
    info "Configuring UFW rules..."
    ufw allow ${WG_PORT}/udp              comment 'WireGuard'   > /dev/null
    ufw allow 1024:51819/tcp              comment 'Gaming TCP'  > /dev/null
    ufw allow 1024:51819/udp              comment 'Gaming UDP'  > /dev/null
    ufw allow 51821:65535/tcp             comment 'Gaming TCP'  > /dev/null
    ufw allow 51821:65535/udp             comment 'Gaming UDP'  > /dev/null
    ufw reload > /dev/null
    success "UFW rules configured."
else
    warn "UFW not active — skipping firewall rules."
fi

# ── Step 9: Enable and start WireGuard ───────────────────────────────────────
info "Enabling and starting WireGuard..."
systemctl enable wg-quick@wg0 > /dev/null 2>&1
systemctl restart wg-quick@wg0
sleep 2
if systemctl is-active --quiet wg-quick@wg0; then
    success "WireGuard is running."
else
    error "WireGuard failed to start. Check: journalctl -u wg-quick@wg0"
fi

# ── Step 10: Save iptables rules ──────────────────────────────────────────────
info "Saving iptables rules for persistence..."
netfilter-persistent save > /dev/null 2>&1
success "iptables rules saved."

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Installation complete!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "WireGuard status:"
wg show
echo ""
echo -e "${YELLOW}Player1 client config:${NC}"
echo -e "  File : ${CYAN}/etc/wireguard/configs/player1.conf${NC}"
echo -e "  View : ${CYAN}cat /etc/wireguard/configs/player1.conf${NC}"
echo -e "  QR   : ${CYAN}qrencode -t ansiutf8 < /etc/wireguard/configs/player1.conf${NC}"
echo ""
echo -e "${YELLOW}Useful commands:${NC}"
echo -e "  Monitor tunnel  : ${CYAN}watch -n2 sudo wg show${NC}"
echo -e "  View NAT rules  : ${CYAN}sudo iptables -t nat -L PREROUTING -n --line-numbers${NC}"
echo -e "  View all rules  : ${CYAN}sudo iptables -t nat -L -n -v${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "  1. Copy /etc/wireguard/configs/player1.conf to the client PC"
echo "  2. Import into WireGuard app and connect"
echo "  3. Launch any game and confirm Open NAT"
echo ""
