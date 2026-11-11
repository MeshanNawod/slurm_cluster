#!/bin/bash
# =============================================================================
# node-setup-in-head.sh  -  run on the HEAD node as your NORMAL user (not root / sudo):
#
#   bash node-setup-in-head.sh
#
# For a range of worker nodes (e.g. node0 ... node7) this script:
#   0. checks every node is reachable (SSH port open)
#   1. sets up passwordless SSH from head to each node (and verifies it)
#   1b. disables unattended-upgrades on head and every node (stops the dpkg lock error)
#   2. installs + starts time sync (chrony) on head and every node
#   3. writes /etc/hosts on head and every node (backup kept as /etc/hosts.bak)
#   4. tests that head can SSH to each node by NAME
#   5. installs the Slurm packages (head: slurm-wlm, nodes: slurmd slurm-client)
#   6. munge: copies HEAD's munge key to every node and tests it both ways
#      (fixes "munge rejected head's credential")
#   7. NFS: exports /mnt/shared on head and mounts it on every node
#
# Run node-setup.sh on every worker FIRST.
# ONE missing node: answer the 'Set up only ONE node?' question with its index.
# /etc/hosts on head and on that node still lists the WHOLE cluster; the IPs head
# already knows for the other nodes are kept, only the selected node's line is new.
# Built-in fixes: apt waits for the dpkg lock (up to 5 min), a node that drops off
# the network mid-run is skipped, NFS failures print real diagnostics.
# A node that fails step 0 or 1 is skipped in later steps; the script carries
# on with the other nodes and prints a summary table at the end.
# =============================================================================

# ---------- Helpers: coloured, clear messages ----------
if [ -t 1 ]; then
  RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; BLUE=$'\e[36m'; BOLD=$'\e[1m'; RESET=$'\e[0m'
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; BOLD=""; RESET=""
fi
step()   { echo; echo "${BOLD}${BLUE}=== $* ===${RESET}"; }
info()   { echo "${BLUE}[INFO]${RESET} $*"; }
ok()     { echo "${GREEN}[ OK ]${RESET} $*"; }
warn()   { echo "${YELLOW}[WARN]${RESET} $*"; }
err()    { echo "${RED}[FAIL]${RESET} $*" >&2; }
die()    { err "$*"; exit 1; }
indent() { sed 's/^/        | /'; }

# try "<what we are doing>" <command...>
# Runs the command quietly. Prints [ OK ] on success, or [FAIL] plus the last
# lines of the command's output on failure. Returns the command's success.
# The full output of the last try() is kept in $TRY_OUT so hints can look at it.
try() {
  local desc=$1 out rc; shift
  info "$desc ..."
  out=$("$@" 2>&1); rc=$?
  TRY_OUT=$out
  if [ $rc -eq 0 ]; then
    ok "$desc"
    return 0
  fi
  err "$desc"
  printf '%s\n' "$out" | tail -n 6 | indent >&2
  return 1
}

# apt_hint <machine>: explain the LAST failed try() in plain words
# (dpkg lock, interrupted install, or really no internet).
apt_hint() {
  local who=$1
  if grep -qiE 'Could not get lock|Unable to acquire the dpkg|dpkg frontend lock|held by process' <<< "$TRY_OUT"; then
    echo "        Hint: $who is busy with another apt/dpkg process (usually unattended-upgrades). This is NOT a network problem." >&2
    echo "        Wait a few minutes and re-run, or stop it: sudo systemctl disable --now unattended-upgrades apt-daily.timer apt-daily-upgrade.timer" >&2
  elif grep -qiE 'dpkg --configure -a|dpkg was interrupted' <<< "$TRY_OUT"; then
    echo "        Hint: an earlier install was interrupted. On $who run: sudo dpkg --configure -a" >&2
  elif grep -qiE 'Could not resolve|Temporary failure|Failed to fetch|Unable to locate package|Connection timed out|Network is unreachable' <<< "$TRY_OUT"; then
    echo "        Hint: $who seems to have no internet/DNS (check gateway and DNS from node-setup.sh)." >&2
  else
    echo "        Hint: see the error lines above (run the apt command by hand on $who for the full output)." >&2
  fi
}

is_int() { [[ "$1" =~ ^[0-9]+$ ]]; }

# is_ipv4 <string>: true only for a real IPv4 address (each part 0-255)
is_ipv4() {
  local ip=$1 part
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  local IFS=.
  for part in $ip; do (( 10#$part <= 255 )) || return 1; done
  return 0
}

TMP=$(mktemp -d)
# Always wipe the password and temp files, even on Ctrl-C or an error.
trap 'unset PASS SSHPASS; rm -rf "$TMP"' EXIT
trap 'echo; warn "Interrupted by user."; exit 130' INT

if [ "$EUID" -eq 0 ]; then
  die "Run this as your normal user (not root / not with sudo)."
fi

# ---------- Inputs ----------
step "Questions"
read -r -p "Cluster user [elec_cluster]: " CUSER
CUSER=${CUSER:-elec_cluster}
read -r -p "Head IP (e.g. 10.40.52.183): " HEAD_IP
is_ipv4 "$HEAD_IP" || die "Head IP '$HEAD_IP' is not a valid IPv4 address."
read -r -p "Node name prefix [node]: " PREFIX
PREFIX=${PREFIX:-node}
[[ "$PREFIX" =~ ^[a-z][a-z0-9-]*$ ]] || die "Prefix '$PREFIX' is invalid (lowercase letters, digits, '-')."
read -r -p "First node index of the WHOLE cluster [0]: " START
START=${START:-0}
read -r -p "Last node index of the WHOLE cluster (e.g. 14): " END
read -r -p "IP of ${PREFIX}0 (e.g. 10.40.52.175; the head's IP is skipped automatically): " BASE_IP
read -r -s -p "Password (same on all machines): " PASS
echo

is_int "$START" || die "First node index '$START' is not a number."
is_int "$END"   || die "Last node index '$END' is not a number (you must enter one)."
[ "$END" -ge "$START" ] || die "Last index ($END) is smaller than first index ($START)."
is_ipv4 "$BASE_IP" || die "Base IP '$BASE_IP' is not a valid IPv4 address."
[ -n "$PASS" ] || die "Password cannot be empty."

[ "$BASE_IP" != "$HEAD_IP" ] || die "${PREFIX}0 and the head cannot have the same IP ($HEAD_IP)."
IP_PREFIX=$(echo "$BASE_IP" | cut -d. -f1-3)
IP_BASE_LAST=$((10#$(echo "$BASE_IP" | cut -d. -f4)))
HEAD_LAST=$((10#$(echo "$HEAD_IP" | cut -d. -f4)))

node_name() { echo "${PREFIX}$1"; }
declare -A IP_OVERRIDE   # node index -> IP typed by hand (when it does not follow the pattern)
# node_ip <index>: IP = node0's IP + index, but the head's IP is skipped.
# Example: head .183, node0 .175 -> node7 = .182, node8 = .184, node9 = .185
node_ip() {
  if [ -n "${IP_OVERRIDE[$1]:-}" ]; then echo "${IP_OVERRIDE[$1]}"; return; fi
  local last=$((IP_BASE_LAST + $1))
  if [ "$IP_PREFIX" = "$(echo "$HEAD_IP" | cut -d. -f1-3)" ] && [ "$HEAD_LAST" -gt "$IP_BASE_LAST" ] && [ "$last" -ge "$HEAD_LAST" ]; then
    last=$((last + 1))   # this number belongs to the head, so move one up
  fi
  echo "${IP_PREFIX}.${last}"
}
LAST_OCTET=$(node_ip "$END" | cut -d. -f4)
[ "$LAST_OCTET" -le 254 ] \
  || die "Node $END would get IP $(node_ip "$END") which is outside the valid range (max .254)."

read -r -p "Set up only ONE node? Enter its index (Enter = all nodes $START..$END): " ONLY
if [ -n "$ONLY" ]; then
  is_int "$ONLY" || die "Node index '$ONLY' is not a number."
  { [ "$ONLY" -ge "$START" ] && [ "$ONLY" -le "$END" ]; } || die "Node index $ONLY is outside the cluster range $START..$END."
  SETUP_START=$ONLY; SETUP_END=$ONLY
  info "Single-node mode: only ${PREFIX}${ONLY} is set up; the other nodes are not touched."
  DEFAULT_IP=$(node_ip "$ONLY")
  read -r -p "IP of ${PREFIX}${ONLY} [$DEFAULT_IP]: " ONLY_IP
  ONLY_IP=${ONLY_IP:-$DEFAULT_IP}
  is_ipv4 "$ONLY_IP" || die "IP '$ONLY_IP' is not a valid IPv4 address."
  [ "$ONLY_IP" != "$HEAD_IP" ] || die "${PREFIX}${ONLY} cannot have the head's IP ($HEAD_IP)."
  IP_OVERRIDE[$ONLY]=$ONLY_IP
else
  SETUP_START=$START; SETUP_END=$END
fi

echo
echo "Head: head ($HEAD_IP)"
for i in $(seq "$SETUP_START" "$SETUP_END"); do echo "Node: $(node_name "$i") ($(node_ip "$i"))"; done
read -r -p "Continue? [y/N]: " OK
[[ "$OK" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }

# Key-based SSH only (never hangs asking for a password) and quiet host-key notices.
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o BatchMode=yes -o LogLevel=ERROR"

# hsudo <cmd...>: sudo on this machine, password fed from $PASS
hsudo() { printf '%s\n' "$PASS" | sudo -S -p '' "$@"; }
# rsudo <host> "<command string>": sudo on a remote machine. The command is
# quoted safely with printf %q so special characters cannot break it.
rsudo() {
  local host=$1 q
  q=$(printf '%q' "$2")
  printf '%s\n' "$PASS" | ssh $SSH_OPTS "$CUSER@$host" "sudo -S -p '' bash -c $q"
}

declare -A FAILED      # node -> reason. Blocking failure: node is skipped later.
ISSUES=()              # non-blocking problems, shown in the summary
is_failed() { [ -n "${FAILED[$1]:-}" ]; }

# node_alive <name> <ip>: a node can drop off the network in the middle of a run
# (power, cable, reboot, sleep). If SSH no longer answers, mark it FAILED right
# away so the later steps skip it instead of timing out again and again.
node_alive() {
  local N=$1 IP=$2
  ssh $SSH_OPTS "$CUSER@$IP" true >/dev/null 2>&1 && return 0
  err "$N ($IP): lost connection (SSH timed out). Powered off, rebooted, or network dropped? Skipping it for the rest of this run."
  FAILED[$N]="lost connection"
  return 1
}

# ---------- Pre-checks on head ----------
step "Pre-checks on head"
[ "$(hostname -s)" = "head" ] \
  || warn "This machine's hostname is '$(hostname -s)', not 'head'. The /etc/hosts written below assumes 'head'."
try "Check sudo password on head" hsudo true \
  || die "sudo failed on head: wrong password, or '$USER' is not allowed to use sudo."

# Build the /etc/hosts text for one machine.
gen_hosts() { # gen_hosts <own name>
  local self=$1 i n ip known
  echo "127.0.0.1 localhost"
  echo "127.0.1.1 $self"
  echo
  if [ "$self" != "head" ]; then echo "$HEAD_IP head"; fi
  for i in $(seq "$START" "$END"); do
    n=$(node_name "$i")
    [ "$n" = "$self" ] && continue
    ip=$(node_ip "$i")
    # Single-node mode: keep the IPs head already has for the OTHER nodes
    # (they may not follow the pattern); only the selected node uses the new IP.
    if [ -n "$ONLY" ] && [ "$i" != "$ONLY" ]; then
      known=$(awk -v n="$n" '$1 !~ /^#/ { for (k = 2; k <= NF; k++) if ($k == n) { print $1; exit } }' /etc/hosts)
      [ -n "$known" ] && ip=$known
    fi
    echo "$ip $n"
  done
}

# ---------- 0. Reachability ----------
step "0. Checking that every node is reachable"
for i in $(seq "$SETUP_START" "$SETUP_END"); do
  N=$(node_name "$i"); IP=$(node_ip "$i")
  if timeout 3 bash -c "exec 3<>/dev/tcp/$IP/22" 2>/dev/null; then
    ok "$N ($IP): SSH port is open"
  elif ping -c1 -W2 "$IP" >/dev/null 2>&1; then
    err "$N ($IP): answers ping but SSH port 22 is closed. Run node-setup.sh on it (installs openssh-server)."
    FAILED[$N]="SSH port closed"
  else
    err "$N ($IP): no reply. Is it powered on, cabled to the switch, and does it have this IP? (run node-setup.sh)"
    FAILED[$N]="not reachable"
  fi
done

# ---------- 1. Passwordless SSH ----------
step "1. Passwordless SSH"
try "Install sshpass on head" hsudo env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y sshpass \
  || { apt_hint head; die "Could not install sshpass."; }
if [ -f "$HOME/.ssh/id_ed25519" ]; then
  ok "SSH key already exists (~/.ssh/id_ed25519)"
else
  try "Create SSH key" ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519" -q || die "Could not create SSH key."
fi

export SSHPASS="$PASS"
for i in $(seq "$SETUP_START" "$SETUP_END"); do
  N=$(node_name "$i"); IP=$(node_ip "$i")
  is_failed "$N" && continue
  info "-> $N ($IP): copying SSH key ..."
  out=$(sshpass -e ssh-copy-id -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o LogLevel=ERROR \
          "$CUSER@$IP" 2>&1); rc=$?
  if [ $rc -ne 0 ]; then
    err "$N: ssh-copy-id failed"
    if grep -q "IDENTIFICATION HAS CHANGED" <<< "$out"; then
      echo "        Hint: the node was reinstalled. Run: ssh-keygen -R $IP   then run this script again." >&2
    elif [ $rc -eq 5 ]; then
      echo "        Hint: wrong password, or user '$CUSER' does not exist on $N." >&2
    fi
    printf '%s\n' "$out" | tail -n 4 | indent >&2
    FAILED[$N]="ssh key copy failed"
    continue
  fi
  # Do not trust ssh-copy-id: really test key login.
  if REMOTE_HOST=$(ssh $SSH_OPTS "$CUSER@$IP" hostname 2>/dev/null); then
    ok "$N: key login works"
    if [ "$REMOTE_HOST" != "$N" ]; then
      warn "$N: the machine calls itself '$REMOTE_HOST', not '$N'. Slurm needs matching names (sudo hostnamectl set-hostname $N)."
      ISSUES+=("$N: hostname is '$REMOTE_HOST', expected '$N'")
    fi
  else
    err "$N: key was copied but key login still fails"
    FAILED[$N]="key login failed"
  fi
done

# ---------- 1b. Disable unattended-upgrades on head and the nodes ----------
# Fresh machines run automatic upgrades that hold the dpkg lock, which makes the
# apt-get installs below fail ("Could not get lock /var/lib/dpkg/lock-frontend").
# We wait (up to 10 min) for a running upgrade to finish, then turn it all off.
# Use this script (instead of head-setup.sh) for nodes that were set up with an
# older node-setup.sh that did not disable automatic upgrades.
step "1b. Disable unattended-upgrades on head and every node"
DISABLE_UPGRADES_CMD='for t in $(seq 120); do pgrep -x unattended-upgr >/dev/null || break; sleep 5; done
systemctl disable --now unattended-upgrades apt-daily.timer apt-daily-upgrade.timer || true
systemctl mask unattended-upgrades apt-daily.service apt-daily-upgrade.service apt-daily.timer apt-daily-upgrade.timer || true
printf "APT::Periodic::Update-Package-Lists \"0\";\nAPT::Periodic::Unattended-Upgrade \"0\";\n" > /etc/apt/apt.conf.d/20auto-upgrades'
try "Disable unattended-upgrades on head" hsudo bash -c "$DISABLE_UPGRADES_CMD" \
  || ISSUES+=("head: could not disable unattended-upgrades")
for i in $(seq "$SETUP_START" "$SETUP_END"); do
  N=$(node_name "$i"); IP=$(node_ip "$i")
  is_failed "$N" && continue
  node_alive "$N" "$IP" || continue
  try "Disable unattended-upgrades on $N" rsudo "$IP" "$DISABLE_UPGRADES_CMD" \
    || ISSUES+=("$N: could not disable unattended-upgrades")
done

# ---------- 2. Time sync ----------
step "2. Time sync (chrony)"
if try "Install chrony on head" hsudo env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y chrony \
   && try "Enable chrony on head" hsudo systemctl enable --now chrony; then
  :
else
  warn "Time sync failed on head. Munge/Slurm break if clocks differ."
  ISSUES+=("head: chrony failed")
fi
for i in $(seq "$SETUP_START" "$SETUP_END"); do
  N=$(node_name "$i"); IP=$(node_ip "$i")
  is_failed "$N" && continue
  node_alive "$N" "$(node_ip "$i")" || continue
  if try "Install and start chrony on $N" \
       rsudo "$IP" "DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y chrony && systemctl enable --now chrony && { chronyc makestep >/dev/null 2>&1 || true; }"; then
    ssh $SSH_OPTS "$CUSER@$IP" "systemctl is-active --quiet chrony" \
      || { warn "$N: chrony installed but not active"; ISSUES+=("$N: chrony not active"); }
  else
    apt_hint "$N"
    ISSUES+=("$N: chrony install failed")
  fi
done

# ---------- 3. /etc/hosts ----------
step "3. /etc/hosts"
install_head_hosts() {
  hsudo bash -c '[ -e /etc/hosts.bak ] || cp /etc/hosts /etc/hosts.bak' \
    && hsudo install -m 644 -o root -g root "$TMP/hosts.head" /etc/hosts
}
gen_hosts head > "$TMP/hosts.head"
try "Write /etc/hosts on head" install_head_hosts || die "Could not write /etc/hosts on head."

for i in $(seq "$SETUP_START" "$SETUP_END"); do
  N=$(node_name "$i"); IP=$(node_ip "$i")
  is_failed "$N" && continue
  node_alive "$N" "$(node_ip "$i")" || continue
  gen_hosts "$N" > "$TMP/hosts.$N"
  info "-> $N: copying hosts file ..."
  if scp $SSH_OPTS "$TMP/hosts.$N" "$CUSER@$IP:/tmp/hosts.new" >/dev/null 2>&1 \
     && try "Install /etc/hosts on $N" rsudo "$IP" \
        "[ -e /etc/hosts.bak ] || cp /etc/hosts /etc/hosts.bak; install -m 644 -o root -g root /tmp/hosts.new /etc/hosts; rm -f /tmp/hosts.new"; then
    :
  else
    err "$N: could not install /etc/hosts"
    FAILED[$N]="hosts file failed"
  fi
done

# ---------- 4. Test by name ----------
step "4. Testing SSH by node NAME"
for i in $(seq "$SETUP_START" "$SETUP_END"); do
  N=$(node_name "$i")
  is_failed "$N" && continue
  node_alive "$N" "$(node_ip "$i")" || continue
  if ssh $SSH_OPTS "$CUSER@$N" "getent hosts head >/dev/null" 2>/dev/null; then
    ok "$N: reachable by name and it can resolve 'head'"
  else
    err "$N: SSH by name failed (or '$N' cannot resolve 'head')"
    FAILED[$N]="name test failed"
  fi
done

# ---------- 5. Slurm packages ----------
step "5. Slurm packages"
try "Update package list on head" hsudo apt-get -o DPkg::Lock::Timeout=300 update \
  || warn "apt update failed on head - trying the installs anyway"
try "Install slurm-wlm on head (slurmctld + configurator)" \
  hsudo env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y slurm-wlm \
  || { warn "slurm-wlm was not installed on head"; ISSUES+=("head: slurm-wlm install failed"); }
for i in $(seq "$SETUP_START" "$SETUP_END"); do
  N=$(node_name "$i"); IP=$(node_ip "$i")
  is_failed "$N" && continue
  node_alive "$N" "$(node_ip "$i")" || continue
  # Already installed by node-setup.sh? Then this is a quick no-op.
  try "Install slurmd + slurm-client on $N" rsudo "$IP" \
    "apt-get -o DPkg::Lock::Timeout=300 update -qq; DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y slurmd slurm-client" \
    || { apt_hint "$N"; ISSUES+=("$N: slurmd/slurm-client install failed"); }
done

# ---------- 6. Munge ----------
step "6. Munge (authentication) - ONE key shared by ALL machines"
info "Every machine makes its own random key when munge is installed. Slurm then says"
info "'munge rejected head's credential'. So head's key is copied to every node below."

try "Install munge on head" hsudo env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y munge \
  || { apt_hint head; die "Could not install munge on head."; }

# Keep head's key if it has one, otherwise create it; then (re)start munge.
ensure_head_key() {
  hsudo bash -c '[ -s /etc/munge/munge.key ] || /usr/sbin/mungekey --create || /usr/sbin/create-munge-key -f' \
    && hsudo bash -c 'chown munge:munge /etc/munge/munge.key && chmod 400 /etc/munge/munge.key' \
    && hsudo systemctl enable munge \
    && hsudo systemctl restart munge
}
try "Make sure head has a munge key and munge is running" ensure_head_key \
  || die "Could not prepare munge on head. See: sudo systemctl status munge"
try "Test munge on head (munge -n | unmunge)" bash -c 'munge -n | unmunge >/dev/null' \
  || die "munge does not work on head itself - fix this before continuing."

# Read head's key into a private temp folder (deleted again below).
fetch_key() { hsudo cat /etc/munge/munge.key > "$TMP/munge.key" && [ -s "$TMP/munge.key" ]; }
try "Read head's munge key" fetch_key || die "Could not read /etc/munge/munge.key on head."
HEAD_KEY_SUM=$(sha256sum "$TMP/munge.key" | cut -d' ' -f1)

for i in $(seq "$SETUP_START" "$SETUP_END"); do
  N=$(node_name "$i"); IP=$(node_ip "$i")
  is_failed "$N" && continue
  node_alive "$N" "$(node_ip "$i")" || continue
  echo; info "--- $N ---"

  if ! scp $SSH_OPTS "$TMP/munge.key" "$CUSER@$IP:/tmp/munge.key.new" >/dev/null 2>&1; then
    err "$N: could not copy the munge key"
    FAILED[$N]="munge key copy failed"; continue
  fi
  if ! try "Install munge + head's key on $N, restart munge" rsudo "$IP" \
       "DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y munge && install -m 400 -o munge -g munge /tmp/munge.key.new /etc/munge/munge.key && rm -f /tmp/munge.key.new && systemctl enable munge && systemctl restart munge"; then
    apt_hint "$N"; FAILED[$N]="munge setup failed"; continue
  fi

  # Prove the key is identical (same checksum), not just "copied".
  NODE_KEY_SUM=$(rsudo "$IP" "sha256sum /etc/munge/munge.key" 2>/dev/null | cut -d' ' -f1)
  if [ "$NODE_KEY_SUM" = "$HEAD_KEY_SUM" ]; then
    ok "$N: munge.key identical to head's"
  else
    err "$N: munge.key still differs from head's"
    FAILED[$N]="munge key mismatch"; continue
  fi

  # The real test: head -> node, and node -> head.
  if munge -n | ssh $SSH_OPTS "$CUSER@$IP" unmunge >/dev/null 2>&1 \
     && ssh $SSH_OPTS "$CUSER@$IP" munge -n 2>/dev/null | unmunge >/dev/null 2>&1; then
    ok "$N: munge works in both directions"
  else
    skew=$(( $(ssh $SSH_OPTS "$CUSER@$IP" date +%s 2>/dev/null) - $(date +%s) ))
    err "$N: key is the same but munge still rejects the credential"
    echo "        Clock difference to head: ${skew}s (must be under ~300 s). Check chrony on head and $N." >&2
    FAILED[$N]="munge credential rejected"
  fi
done
shred -u "$TMP/munge.key" 2>/dev/null || rm -f "$TMP/munge.key"

# ---------- 7. NFS shared storage ----------
step "7. Shared storage (NFS) - /mnt/shared"
SUBNET="$(echo "$HEAD_IP" | cut -d. -f1-3).0/24"
EXPORT_LINE="/mnt/shared $SUBNET(rw,sync,no_subtree_check)"

setup_nfs_head() {
  hsudo env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y nfs-kernel-server \
    && hsudo mkdir -p /mnt/shared \
    && hsudo chown "$USER:$USER" /mnt/shared \
    && hsudo bash -c "grep -qs '^/mnt/shared[[:space:]]' /etc/exports || echo '$EXPORT_LINE' >> /etc/exports" \
    && hsudo exportfs -ra \
    && hsudo systemctl enable --now nfs-kernel-server
}
NFS_HEAD_OK=1
if try "Set up NFS server on head (export /mnt/shared)" setup_nfs_head; then
  info "Export line: $(grep '^/mnt/shared' /etc/exports)"
  touch /mnt/shared/.nfs-test-head 2>/dev/null || warn "Cannot write to /mnt/shared on head"
else
  NFS_HEAD_OK=0
  ISSUES+=("head: NFS server setup failed")
fi

# Commands run on each node: install client, create mount point, add fstab line
# (nofail = the node still boots if head is off), mount it.
NFS_NODE_CMD='DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y nfs-common && mkdir -p /mnt/shared && { grep -qs "^head:/mnt/shared" /etc/fstab || echo "head:/mnt/shared /mnt/shared nfs defaults,_netdev,nofail 0 0" >> /etc/fstab; } && systemctl daemon-reload && { mountpoint -q /mnt/shared || timeout 60 mount /mnt/shared || { modprobe nfs 2>/dev/null; timeout 60 mount -t nfs -o vers=4 head:/mnt/shared /mnt/shared; }; }'

# Run on a node when the mount fails: shows WHY ("incorrect mount option" is often
# just a missing NFS kernel module after a kernel update that was never rebooted).
NFS_DIAG_CMD='echo "kernel: $(uname -r)"; [ -d /lib/modules/$(uname -r) ] || echo "NEEDS-REBOOT: no modules directory for the running kernel"; [ -f /var/run/reboot-required ] && echo "NEEDS-REBOOT: a kernel update is waiting for a reboot"; modprobe nfs 2>&1 && echo "nfs module: ok" || echo "NEEDS-REBOOT: the nfs kernel module cannot be loaded"; mount -v -t nfs head:/mnt/shared /mnt/shared 2>&1 | tail -n 4; dmesg | tail -n 4'

if [ "$NFS_HEAD_OK" -eq 1 ]; then
  for i in $(seq "$SETUP_START" "$SETUP_END"); do
    N=$(node_name "$i"); IP=$(node_ip "$i")
    is_failed "$N" && continue
    node_alive "$N" "$(node_ip "$i")" || continue
    if ! try "Mount head:/mnt/shared on $N" rsudo "$IP" "$NFS_NODE_CMD"; then
      echo "        Diagnostics from $N:" >&2
      NFS_DIAG=$(rsudo "$IP" "$NFS_DIAG_CMD" 2>&1)
      printf '%s\n' "$NFS_DIAG" | indent >&2
      if grep -q 'NEEDS-REBOOT' <<< "$NFS_DIAG"; then
        echo "        Fix: reboot $N (ssh $CUSER@$N sudo reboot), wait until it is back, then run this script again." >&2
        ISSUES+=("$N: NFS mount failed - reboot the node (pending kernel update) and re-run")
      else
        echo "        Hints: on head run 'sudo exportfs -v' and 'sudo ufw status'; on $N run 'showmount -e head'." >&2
        ISSUES+=("$N: NFS mount failed")
      fi
      continue
    fi
    if ssh $SSH_OPTS "$CUSER@$IP" "test -e /mnt/shared/.nfs-test-head && touch /mnt/shared/.nfs-test-$N && rm -f /mnt/shared/.nfs-test-$N"; then
      ok "$N: sees head's files and can write to /mnt/shared"
    else
      err "$N: /mnt/shared is mounted but not shared/writable (is the cluster user's UID the same on every machine?)"
      ISSUES+=("$N: NFS not writable")
    fi
  done
  rm -f /mnt/shared/.nfs-test-head
fi

# ---------- Summary ----------
step "Summary"
for i in $(seq "$SETUP_START" "$SETUP_END"); do
  N=$(node_name "$i")
  if is_failed "$N"; then
    echo "  ${RED}FAILED${RESET}  $N  - ${FAILED[$N]}"
  else
    echo "  ${GREEN}OK    ${RESET}  $N"
  fi
done
if [ "${#ISSUES[@]}" -gt 0 ]; then
  echo
  warn "Non-blocking problems:"
  for x in "${ISSUES[@]}"; do echo "    - $x"; done
fi
echo
if [ "${#FAILED[@]}" -eq 0 ] && [ "${#ISSUES[@]}" -eq 0 ]; then
  ok "All nodes OK. Test: ssh $CUSER@${PREFIX}${SETUP_START}"
  echo "Next: create /etc/slurm/slurm.conf on head (slurm configurator, Step 4.2 of the guide), then run slurm-setup.sh"
  exit 0
fi
echo "Fix the problems above (power, cable, IP, run node-setup.sh on the node) and run this script again."
echo "It is safe to re-run: finished steps are simply repeated."
[ "${#FAILED[@]}" -eq 0 ] || exit 1
