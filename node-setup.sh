#!/bin/bash
# =============================================================================
# node-setup.sh  -  run on each WORKER node:   sudo bash node-setup.sh
#
# What it does (and tells you about every step while it runs):
#   1. asks for node name / IP / gateway / DNS and validates them
#   2. picks the ethernet interface and checks the cable (link) is up
#   3. writes the static IP config (cloud-init off + netplan) with a backup,
#      validates it, applies it, and restores the backup if something breaks
#   4. tests the network (gateway, head node, internet, DNS)
#   5. sets the hostname and writes /etc/hosts (backup kept)
#   6. installs and starts openssh-server
#   7. installs the Slurm worker packages: slurmd slurm-client (+ munge)
#
# Run this BEFORE head-setup.sh.
# =============================================================================

# Re-run ourselves with sudo if we are not root.
if [ "$EUID" -ne 0 ]; then
  exec sudo bash "$0" "$@"
fi

WARNINGS=0

# ---------- Helpers: coloured, clear messages ----------
if [ -t 1 ]; then
  RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; BLUE=$'\e[36m'; BOLD=$'\e[1m'; RESET=$'\e[0m'
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; BOLD=""; RESET=""
fi
step()   { echo; echo "${BOLD}${BLUE}=== $* ===${RESET}"; }
info()   { echo "${BLUE}[INFO]${RESET} $*"; }
ok()     { echo "${GREEN}[ OK ]${RESET} $*"; }
warn()   { WARNINGS=$((WARNINGS + 1)); echo "${YELLOW}[WARN]${RESET} $*"; }
err()    { echo "${RED}[FAIL]${RESET} $*" >&2; }
die()    { err "$*"; echo "Nothing more was changed. Fix the problem above and run the script again." >&2; exit 1; }
indent() { sed 's/^/        | /'; }

# try "<what we are doing>" <command...>
# Runs the command quietly. Prints [ OK ] on success, or [FAIL] plus the last
# lines of the command's output on failure. Returns the command's success.
try() {
  local desc=$1 out; shift
  info "$desc ..."
  if out=$("$@" 2>&1); then
    ok "$desc"
    return 0
  fi
  err "$desc"
  printf '%s\n' "$out" | tail -n 6 | indent >&2
  return 1
}

# is_ipv4 <string>: true only for a real IPv4 address (each part 0-255)
is_ipv4() {
  local ip=$1 part
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  local IFS=.
  for part in $ip; do (( 10#$part <= 255 )) || return 1; done
  return 0
}

trap 'echo; warn "Interrupted by user. Network settings may be half-changed - check with: ip a"; exit 130' INT

# ---------- 1. Inputs ----------
step "1. Questions"
read -r -p "Head IP                   (e.g. 10.40.52.183): " HEAD_IP
is_ipv4 "$HEAD_IP" || die "Head IP '$HEAD_IP' is not a valid IPv4 address."

read -r -p "IP of node0 (first node)  (e.g. 10.40.52.175): " BASE_IP
is_ipv4 "$BASE_IP" || die "node0 IP '$BASE_IP' is not a valid IPv4 address."
[ "$BASE_IP" != "$HEAD_IP" ] || die "node0 and the head cannot have the same IP ($HEAD_IP)."

read -r -p "This node's name          (e.g. node8): " NODE_NAME
[[ "$NODE_NAME" =~ ^[a-z][a-z0-9-]{0,62}$ ]] \
  || die "Invalid node name '$NODE_NAME'. Use lowercase letters, digits and '-', starting with a letter (e.g. node8)."

# calc_node_ip <index>: IP = node0's IP + index, but the head's IP is skipped.
# Example: head .183, node0 .175 -> node7 = .182, node8 = .184, node9 = .185
calc_node_ip() {
  local idx=$1 base_last head_last last
  base_last=$((10#${BASE_IP##*.}))
  head_last=$((10#${HEAD_IP##*.}))
  last=$((base_last + idx))
  if [ "${BASE_IP%.*}" = "${HEAD_IP%.*}" ] && [ "$head_last" -gt "$base_last" ] && [ "$last" -ge "$head_last" ]; then
    last=$((last + 1))   # this number belongs to the head, so move one up
  fi
  [ "$last" -le 254 ] || return 1
  echo "${BASE_IP%.*}.$last"
}

# Take the number at the end of the name (node8 -> 8) and calculate the IP.
NODE_IP_DEFAULT=""
if [[ "$NODE_NAME" =~ ^(.*[^0-9])([0-9]+)$ ]]; then
  NODE_INDEX=$((10#${BASH_REMATCH[2]}))
  if NODE_IP_DEFAULT=$(calc_node_ip "$NODE_INDEX"); then
    info "Calculated IP for $NODE_NAME: $NODE_IP_DEFAULT  (node0 = $BASE_IP, head $HEAD_IP is skipped)"
  else
    warn "Calculated IP for $NODE_NAME would be above .254 - type the IP yourself."
  fi
else
  warn "'$NODE_NAME' does not end with a number, so the IP cannot be calculated - type it yourself."
fi
read -r -p "Node IP [${NODE_IP_DEFAULT:-none}] (Enter = accept): " NODE_IP
NODE_IP=${NODE_IP:-$NODE_IP_DEFAULT}
[ -n "$NODE_IP" ] || die "No node IP given."
is_ipv4 "$NODE_IP" || die "'$NODE_IP' is not a valid IPv4 address (each part must be 0-255)."
[ "$NODE_IP" != "$HEAD_IP" ] || die "Node IP is the same as the head IP ($HEAD_IP)."

# Gateway and DNS are guessed from the IP (same pattern as the guide:
# x.x.x.254 and x.x.2.1). Press Enter to accept, or type your own.
GATEWAY_DEFAULT="$(echo "$NODE_IP" | cut -d. -f1-3).254"
DNS_DEFAULT="$(echo "$NODE_IP" | cut -d. -f1-2).2.1"
read -r -p "Gateway   [$GATEWAY_DEFAULT]: " GATEWAY
GATEWAY=${GATEWAY:-$GATEWAY_DEFAULT}
read -r -p "DNS       [$DNS_DEFAULT]: " DNS
DNS=${DNS:-$DNS_DEFAULT}
is_ipv4 "$GATEWAY" || die "Gateway '$GATEWAY' is not a valid IPv4 address."
is_ipv4 "$DNS"     || die "DNS '$DNS' is not a valid IPv4 address."

if [ "$(echo "$NODE_IP" | cut -d. -f1-3)" != "$(echo "$HEAD_IP" | cut -d. -f1-3)" ]; then
  warn "Node IP and head IP are in different /24 networks. Is that really what you want?"
fi

# ---------- 2. Network interface ----------
step "2. Network interface"
ip -br link show
mapfile -t IFACES < <(ip -o link show | awk -F': ' '{print $2}' | cut -d@ -f1 | grep -E '^(en|eth)')
[ "${#IFACES[@]}" -gt 0 ] || die "No ethernet interface (en*/eth*) found. Is the network card detected? Check: ip a"
DETECTED_IF=${IFACES[0]}
read -r -p "Network interface [$DETECTED_IF]: " NET_IF
NET_IF=${NET_IF:-$DETECTED_IF}
ip link show "$NET_IF" >/dev/null 2>&1 || die "Interface '$NET_IF' does not exist. Pick one from the list above."

try "Bring $NET_IF up" ip link set "$NET_IF" up || die "Could not bring $NET_IF up."
sleep 3
if [ "$(cat "/sys/class/net/$NET_IF/carrier" 2>/dev/null)" = "0" ]; then
  warn "No link on $NET_IF. Check the ethernet cable and that the network switch is powered on."
else
  ok "Cable/link detected on $NET_IF"
fi

# Is another machine already using this IP?
if ip -4 addr show | grep -qF "inet $NODE_IP/"; then
  info "$NODE_IP is already assigned to this machine (re-run) - fine."
elif ping -c1 -W1 "$NODE_IP" >/dev/null 2>&1; then
  warn "$NODE_IP already answers ping - ANOTHER machine seems to use it! Two machines with one IP breaks the network."
  read -r -p "Continue anyway? [y/N]: " OK
  [[ "$OK" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }
fi

echo
echo "---------------- Summary ----------------"
echo "Node name : $NODE_NAME"
echo "Node IP   : $NODE_IP/24"
echo "Gateway   : $GATEWAY"
echo "DNS       : $DNS"
echo "Interface : $NET_IF"
echo "Head IP   : $HEAD_IP"
echo "-----------------------------------------"
read -r -p "Continue? [y/N]: " OK
[[ "$OK" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }

# ---------- 3. Static IP configuration ----------
step "3. Static IP configuration"

# Stop cloud-init from overwriting our network config on reboot.
mkdir -p /etc/cloud/cloud.cfg.d
if echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg; then
  ok "cloud-init network management disabled"
else
  die "Could not write /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg"
fi

# Use the existing netplan file if there is one.
mapfile -t NP_FILES < <(ls /etc/netplan/*.yaml 2>/dev/null)
NETPLAN_FILE=${NP_FILES[0]:-/etc/netplan/50-cloud-init.yaml}
if [ "${#NP_FILES[@]}" -gt 1 ]; then
  warn "More than one netplan file found (${NP_FILES[*]}). Only $NETPLAN_FILE is replaced;"
  warn "other files can conflict - if the IP is wrong after applying, look at them."
fi

BACKUP=""
if [ -f "$NETPLAN_FILE" ]; then
  BACKUP="$NETPLAN_FILE.bak.$(date +%Y%m%d-%H%M%S)"
  cp "$NETPLAN_FILE" "$BACKUP" && ok "Backup saved: $BACKUP"
fi

# Put the old config back (or remove ours if there was none).
restore_netplan() {
  if [ -n "$BACKUP" ]; then
    cp "$BACKUP" "$NETPLAN_FILE" && warn "Old netplan config restored from $BACKUP"
  else
    rm -f "$NETPLAN_FILE"
  fi
}

cat > "$NETPLAN_FILE" << EOF
network:
  version: 2
  ethernets:
    $NET_IF:
      dhcp4: no
      addresses:
        - $NODE_IP/24
      routes:
        - to: default
          via: $GATEWAY
      nameservers:
        addresses: [$DNS]
EOF
chmod 600 "$NETPLAN_FILE"
ok "Wrote $NETPLAN_FILE"

# Check the file for mistakes BEFORE applying it.
if ! try "Validate netplan file" netplan generate; then
  restore_netplan
  die "The netplan file is invalid (see the error above)."
fi

if ! try "Apply network configuration (netplan apply)" netplan apply; then
  warn "netplan apply failed. The guide says openvswitch-switch can fix this (needs internet)."
  if try "Install openvswitch-switch" bash -c 'apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y openvswitch-switch' \
     && try "Retry netplan apply" netplan apply; then
    :
  else
    restore_netplan
    netplan apply >/dev/null 2>&1
    die "Could not apply the network configuration. If there is no internet, openvswitch-switch could not be installed."
  fi
fi

# Wait until the IP really shows up on the interface.
for _ in $(seq 1 10); do
  ip -4 addr show "$NET_IF" | grep -qF "inet $NODE_IP/" && break
  sleep 1
done
if ip -4 addr show "$NET_IF" | grep -qF "inet $NODE_IP/"; then
  ok "$NET_IF now has $NODE_IP"
else
  ip a show "$NET_IF"
  die "$NODE_IP did not appear on $NET_IF after netplan apply."
fi

# ---------- 4. Network checks (warnings only, not fatal) ----------
step "4. Checking the network"
if ping -c2 -W2 "$GATEWAY" >/dev/null 2>&1; then
  ok "Gateway $GATEWAY reachable"
else
  warn "Cannot reach gateway $GATEWAY. Check cable, switch and the gateway address."
fi
if ping -c2 -W2 "$HEAD_IP" >/dev/null 2>&1; then
  ok "Head node $HEAD_IP reachable"
else
  warn "Head $HEAD_IP not reachable (head may be off or not configured yet - OK for now)."
fi
HAS_INTERNET=0
if ping -c1 -W2 8.8.8.8 >/dev/null 2>&1; then
  ok "Internet reachable"
  HAS_INTERNET=1
else
  warn "No internet. apt install will fail in step 6 unless openssh-server is already installed."
fi
if getent hosts archive.ubuntu.com >/dev/null 2>&1; then
  ok "DNS works"
else
  warn "DNS lookup failed. Check the DNS address ($DNS)."
fi

# ---------- 5. Hostname and /etc/hosts ----------
step "5. Hostname and /etc/hosts"
if [ "$(hostname)" != "$NODE_NAME" ]; then
  try "Set hostname to $NODE_NAME (was $(hostname))" hostnamectl set-hostname "$NODE_NAME" \
    || warn "Could not set hostname. Slurm needs the hostname to match the node name."
else
  ok "Hostname is already $NODE_NAME"
fi

[ -e /etc/hosts.bak ] || cp /etc/hosts /etc/hosts.bak
cat > /etc/hosts << EOF
127.0.0.1 localhost
127.0.1.1 $NODE_NAME

$HEAD_IP head
EOF
if getent hosts head >/dev/null 2>&1; then
  ok "/etc/hosts written (old one saved as /etc/hosts.bak); 'head' resolves"
else
  warn "/etc/hosts written but 'head' does not resolve - check /etc/hosts"
fi

# ---------- 6. OpenSSH ----------
step "6. OpenSSH server"
if dpkg -s openssh-server >/dev/null 2>&1; then
  ok "openssh-server already installed"
else
  [ "$HAS_INTERNET" -eq 1 ] || die "openssh-server is not installed and there is no internet. Fix the network first."
  try "apt update" apt-get update || warn "apt update failed - trying the install anyway"
  try "Install openssh-server" env DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server \
    || die "Could not install openssh-server."
fi
try "Enable and start ssh service" systemctl enable --now ssh || die "ssh service did not start. See: systemctl status ssh"
if ss -ltn 2>/dev/null | grep -q ':22 '; then
  ok "SSH is listening on port 22"
else
  warn "SSH service is running but nothing listens on port 22. Check /etc/ssh/sshd_config"
fi

# ---------- 7. Slurm worker packages ----------
step "7. Slurm worker packages (slurmd, slurm-client)"
if dpkg -s slurmd >/dev/null 2>&1 && dpkg -s slurm-client >/dev/null 2>&1; then
  ok "slurmd and slurm-client already installed"
elif [ "$HAS_INTERNET" -eq 1 ]; then
  try "apt update" apt-get update || warn "apt update failed - trying the install anyway"
  if try "Install slurmd slurm-client" env DEBIAN_FRONTEND=noninteractive apt-get install -y slurmd slurm-client; then
    info "This also installed munge with a RANDOM key. head-setup.sh replaces it with head's key later."
  else
    warn "slurmd/slurm-client not installed. Later run: sudo apt install -y slurmd slurm-client"
  fi
else
  warn "No internet, so slurmd/slurm-client were skipped. Later run: sudo apt install -y slurmd slurm-client"
fi

# ---------- Done ----------
step "Done"
ip -br a show "$NET_IF"
if [ "$WARNINGS" -eq 0 ]; then
  ok "Node $NODE_NAME finished with no warnings."
else
  warn "Node $NODE_NAME finished with $WARNINGS warning(s) - read the [WARN] lines above."
fi
echo "Next: reboot, run 'ip a' to confirm the IP stays static, then run head-setup.sh on the head node."
