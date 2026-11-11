#!/bin/bash
# =============================================================================
# slurm-setup.sh  -  run on the HEAD node as your NORMAL user (not root / sudo):
#
#   bash slurm-setup.sh
#
# Run AFTER:  head-setup.sh, NFS, munge (key copied to all nodes), Slurm
#             packages installed, and /etc/slurm/slurm.conf created on head.
#
# ONE missing node: answer the 'Set up only ONE node?' question with its index.
#
# What it does:
#   1. checks head (slurmctld installed, munge working) and reads slurm.conf
#   2. pre-flight check of every node (SSH, slurmd, slurm user, munge key, clock)
#   3. creates the Slurm directories (taken from slurm.conf) on head
#   4. for each node: copies slurm.conf (checksum verified), creates the
#      directories, starts slurmd and confirms it is running
#   5. starts slurmctld on head and confirms it is running
#   6. waits for the nodes to register and explains any node that is not idle
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

is_int() { [[ "$1" =~ ^[0-9]+$ ]]; }

# Always wipe the password, even on Ctrl-C or an error.
trap 'unset PASS' EXIT
trap 'echo; warn "Interrupted by user. Some nodes may be half-configured - just run the script again."; exit 130' INT

if [ "$EUID" -eq 0 ]; then
  die "Run this as your normal user (not root / not with sudo)."
fi

CONF=/etc/slurm/slurm.conf
[ -f "$CONF" ] || die "$CONF not found. Create it on head first (from the slurm configurator output)."
[ -s "$CONF" ] || die "$CONF is empty."
[ -r "$CONF" ] || die "$CONF is not readable by $USER."

# ---------- Inputs ----------
step "Questions"
read -r -p "Cluster user [elec_cluster]: " CUSER
CUSER=${CUSER:-elec_cluster}
read -r -p "Node name prefix [node]: " PREFIX
PREFIX=${PREFIX:-node}
[[ "$PREFIX" =~ ^[a-z][a-z0-9-]*$ ]] || die "Prefix '$PREFIX' is invalid (lowercase letters, digits, '-')."
read -r -p "First node index of the WHOLE cluster [0]: " START
START=${START:-0}
read -r -p "Last node index of the WHOLE cluster (e.g. 14): " END
read -r -s -p "Password (same on all machines): " PASS
echo

is_int "$START" || die "First node index '$START' is not a number."
is_int "$END"   || die "Last node index '$END' is not a number (you must enter one)."
[ "$END" -ge "$START" ] || die "Last index ($END) is smaller than first index ($START)."
[ -n "$PASS" ] || die "Password cannot be empty."

read -r -p "Set up only ONE node? Enter its index (Enter = all nodes $START..$END): " ONLY
if [ -n "$ONLY" ]; then
  is_int "$ONLY" || die "Node index '$ONLY' is not a number."
  { [ "$ONLY" -ge "$START" ] && [ "$ONLY" -le "$END" ]; } || die "Node index $ONLY is outside the cluster range $START..$END."
  SETUP_START=$ONLY; SETUP_END=$ONLY
  info "Single-node mode: only ${PREFIX}${ONLY} is set up; the other nodes are not touched."
else
  SETUP_START=$START; SETUP_END=$END
fi

# Key-based SSH only (never hangs asking for a password) and quiet host-key notices.
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o BatchMode=yes -o LogLevel=ERROR"

# hsudo <cmd...>: sudo on this machine, password fed from $PASS
hsudo() { printf '%s\n' "$PASS" | sudo -S -p '' "$@"; }
# rsudo <host> "<command string>": sudo on a remote machine (safely quoted).
rsudo() {
  local host=$1 q
  q=$(printf '%q' "$2")
  printf '%s\n' "$PASS" | ssh $SSH_OPTS "$CUSER@$host" "sudo -S -p '' bash -c $q"
}

try "Check sudo password on head" hsudo true \
  || die "sudo failed on head: wrong password, or '$USER' is not allowed to use sudo."

declare -A FAILED     # node -> reason
is_failed() { [ -n "${FAILED[$1]:-}" ]; }

# ---------- 1. Head checks + read slurm.conf ----------
step "1. Checking the head node and $CONF"

# conf_val <Key>: last un-commented value of Key=... in slurm.conf (empty if unset)
conf_val() {
  grep -iE "^[[:space:]]*$1[[:space:]]*=" "$CONF" | tail -n1 | cut -d= -f2- \
    | sed 's/#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//'
}

[ -x /usr/sbin/slurmctld ] || die "slurmctld is not installed on head. Run: sudo apt install -y slurm-wlm"
ok "slurmctld is installed"
systemctl is-active --quiet munge || die "munge is not running on head. Run: sudo systemctl enable --now munge"
munge -n | unmunge >/dev/null 2>&1 || die "munge test failed on head (munge -n | unmunge). Check /etc/munge/munge.key permissions."
ok "munge works on head"

# Directories come from slurm.conf, with the guide's paths as defaults.
SLURM_USER=$(conf_val SlurmUser);        SLURM_USER=${SLURM_USER:-slurm}
STATE_DIR=$(conf_val StateSaveLocation); STATE_DIR=${STATE_DIR:-/var/lib/slurm/slurmctld}
SPOOL_DIR=$(conf_val SlurmdSpoolDir);    SPOOL_DIR=${SPOOL_DIR:-/var/lib/slurm/slurmd}
CTLD_LOG=$(conf_val SlurmctldLogFile);   CTLD_LOG=${CTLD_LOG:-/var/log/slurm/slurmctld.log}
D_LOG=$(conf_val SlurmdLogFile);         D_LOG=${D_LOG:-/var/log/slurm/slurmd.log}
mapfile -t DIRS < <(printf '%s\n' "$STATE_DIR" "$SPOOL_DIR" "$(dirname "$CTLD_LOG")" "$(dirname "$D_LOG")" | sort -u)
for d in "${DIRS[@]}"; do
  case "$d" in
    /|/var|/var/lib|/var/log|/etc|/usr|/tmp|/home|"") die "Refusing to chown the system directory '$d' (check paths in $CONF)." ;;
    /*) ;;
    *)  die "Path '$d' from $CONF is not absolute." ;;
  esac
done
info "Slurm user: $SLURM_USER"
info "Directories: ${DIRS[*]}"
printf -v DIRS_Q '%q ' "${DIRS[@]}"
DIRS_CMD="mkdir -p $DIRS_Q && chown -R $SLURM_USER:$SLURM_USER $DIRS_Q"

# Is this machine really the controller named in slurm.conf?
CTLD_HOST=$(conf_val SlurmctldHost | sed 's/(.*//')
[ -n "$CTLD_HOST" ] || CTLD_HOST=$(conf_val ControlMachine)
if [ -z "$CTLD_HOST" ]; then
  warn "No SlurmctldHost found in $CONF."
elif [ "$CTLD_HOST" != "$(hostname -s)" ]; then
  warn "slurm.conf says the controller is '$CTLD_HOST' but this machine is '$(hostname -s)'. slurmctld will refuse to start."
else
  ok "SlurmctldHost matches this machine ($CTLD_HOST)"
fi

# Does slurm.conf know about every node we are going to set up?
mapfile -t CONF_NODES < <(
  grep -iE '^[[:space:]]*NodeName=' "$CONF" \
    | sed -E 's/^[[:space:]]*NodeName=([^[:space:]]+).*/\1/' \
    | while read -r spec; do scontrol show hostnames "$spec" 2>/dev/null; done
)
if [ "${#CONF_NODES[@]}" -eq 0 ]; then
  warn "Could not read any NodeName= entries from $CONF."
else
  for i in $(seq "$SETUP_START" "$SETUP_END"); do
    N="${PREFIX}${i}"
    printf '%s\n' "${CONF_NODES[@]}" | grep -qx "$N" \
      && ok "$N is defined in slurm.conf" \
      || warn "$N is NOT listed under NodeName= in slurm.conf - it will not join the cluster."
  done
fi

# ---------- 2. Node pre-flight ----------
step "2. Pre-flight check of every node"
# check_node <name>: prints what is wrong (with the fix) and returns non-zero.
check_node() {
  local N=$1 skew
  ssh $SSH_OPTS "$CUSER@$N" true 2>/dev/null \
    || {
         if ping -c1 -W2 "$N" >/dev/null 2>&1; then
           err "$N: answers ping but SSH by key fails. Run head-setup.sh first (it copies the SSH key)."
         else
           err "$N: no reply at all. Powered off, rebooted, cable/switch problem, or the IP changed? Check it, then run this script again."
         fi
         return 1
       }
  ssh $SSH_OPTS "$CUSER@$N" "test -x /usr/sbin/slurmd" \
    || { err "$N: slurmd not installed. On $N run: sudo apt install -y slurmd slurm-client"; return 1; }
  ssh $SSH_OPTS "$CUSER@$N" "id $SLURM_USER >/dev/null 2>&1" \
    || { err "$N: user '$SLURM_USER' missing (slurm packages not installed properly?)"; return 1; }
  ssh $SSH_OPTS "$CUSER@$N" "systemctl is-active --quiet munge" \
    || { err "$N: munge not running. On $N run: sudo systemctl enable --now munge"; return 1; }
  if ! munge -n | ssh $SSH_OPTS "$CUSER@$N" unmunge >/dev/null 2>&1; then
    # Find out WHY: different key, or something else (clock, munge needs a restart)?
    local hk nk
    hk=$(hsudo sha256sum /etc/munge/munge.key 2>/dev/null | cut -d' ' -f1)
    nk=$(rsudo "$N" "sha256sum /etc/munge/munge.key" 2>/dev/null | cut -d' ' -f1)
    if [ -n "$hk" ] && [ "$hk" != "$nk" ]; then
      err "$N: munge rejected head's credential because $N has a DIFFERENT munge.key."
      echo "        Fix: run head-setup.sh (step 6 copies head's key to every node), then run this script again." >&2
    else
      err "$N: munge rejected head's credential although the key is the same."
      echo "        Fix: check the clocks (date on head and $N, chrony), then 'sudo systemctl restart munge' on both." >&2
    fi
    return 1
  fi
  skew=$(( $(ssh $SSH_OPTS "$CUSER@$N" date +%s 2>/dev/null) - $(date +%s) ))
  if [ "${skew#-}" -gt 5 ]; then
    warn "$N: clock differs from head by ${skew}s - check chrony."
  fi
  ok "$N: ready"
}

READY=()
for i in $(seq "$SETUP_START" "$SETUP_END"); do
  N="${PREFIX}${i}"
  if check_node "$N"; then READY+=("$N"); else FAILED[$N]="pre-flight failed"; fi
done
[ "${#READY[@]}" -gt 0 ] || die "No node passed the pre-flight check. Fix the problems above first."
if [ "${#FAILED[@]}" -gt 0 ]; then
  warn "These nodes will be skipped: ${!FAILED[*]}"
  read -r -p "Continue with the ${#READY[@]} healthy node(s) only? [y/N]: " OK
  [[ "$OK" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }
fi

# ---------- 3. Head directories ----------
step "3. Head: create Slurm directories"
try "Create directories on head" hsudo bash -c "$DIRS_CMD" \
  || die "Could not create directories on head (is the '$SLURM_USER' user there? is slurm-wlm installed?)."

# ---------- 4. Workers ----------
step "4. Worker nodes: config, directories, slurmd"
LOCAL_SUM=$(md5sum "$CONF" | cut -d' ' -f1)
STARTED=()
for N in "${READY[@]}"; do
  echo; info "--- $N ---"

  # The node may have dropped off the network since the pre-flight check.
  if ! ssh $SSH_OPTS "$CUSER@$N" true >/dev/null 2>&1; then
    err "$N: lost connection (SSH timed out). Skipped - check power/cable/IP, then run this script again."
    FAILED[$N]="lost connection"; continue
  fi

  if ! { scp $SSH_OPTS "$CONF" "$CUSER@$N:/tmp/slurm.conf.new" >/dev/null 2>&1 \
         && try "Install slurm.conf on $N" rsudo "$N" \
            "mkdir -p /etc/slurm && install -m 644 -o root -g root /tmp/slurm.conf.new /etc/slurm/slurm.conf && rm -f /tmp/slurm.conf.new"; }; then
    err "$N: could not copy slurm.conf"
    FAILED[$N]="slurm.conf copy failed"; continue
  fi

  REMOTE_SUM=$(ssh $SSH_OPTS "$CUSER@$N" "md5sum /etc/slurm/slurm.conf" 2>/dev/null | cut -d' ' -f1)
  if [ "$REMOTE_SUM" = "$LOCAL_SUM" ]; then
    ok "$N: slurm.conf identical to head (checksum match)"
  else
    err "$N: slurm.conf differs from head after copy"
    FAILED[$N]="slurm.conf mismatch"; continue
  fi

  try "Create directories on $N" rsudo "$N" "$DIRS_CMD" \
    || { FAILED[$N]="directories failed"; continue; }

  try "Start slurmd on $N" rsudo "$N" "systemctl enable slurmd && systemctl restart slurmd" \
    || { FAILED[$N]="slurmd start failed"; continue; }
  sleep 2
  if ssh $SSH_OPTS "$CUSER@$N" "systemctl is-active --quiet slurmd"; then
    ok "$N: slurmd is running"
    STARTED+=("$N")
  else
    err "$N: slurmd stopped right after starting. Last log lines:"
    rsudo "$N" "journalctl -u slurmd -n 8 --no-pager" 2>&1 | indent >&2
    FAILED[$N]="slurmd not running"
  fi
done

# ---------- 5. Controller ----------
step "5. Head: start slurmctld"
try "Enable and start slurmctld" hsudo bash -c "systemctl enable slurmctld && systemctl restart slurmctld" \
  || die "Could not start slurmctld (see error above)."
sleep 3
if systemctl is-active --quiet slurmctld; then
  ok "slurmctld is running"
else
  err "slurmctld stopped right after starting. Last log lines:"
  hsudo journalctl -u slurmctld -n 12 --no-pager 2>&1 | indent >&2
  echo "Common causes: error in slurm.conf, munge problem, wrong SlurmctldHost, missing directories." >&2
  exit 1
fi

# ---------- 6. Check the cluster ----------
step "6. Waiting for nodes to register (up to 40 s)"
if [ "${#STARTED[@]}" -gt 0 ]; then
  for _ in $(seq 1 20); do
    pending=0
    for N in "${STARTED[@]}"; do
      st=$(sinfo -h -N -n "$N" -o '%T' 2>/dev/null | head -n1)
      [ "$st" = "idle" ] || pending=1
    done
    [ "$pending" -eq 0 ] && break
    sleep 2
  done
fi

echo; echo "=============== sinfo ==============="
sinfo
echo; echo "=============== scontrol show nodes ==============="
scontrol show nodes | grep -E "NodeName|State|CPUTot"

echo; step "Result per node"
for N in "${STARTED[@]}"; do
  st=$(sinfo -h -N -n "$N" -o '%T' 2>/dev/null | head -n1)
  # Old 'NO NETWORK ADDRESS FOUND' drain flag (set before the name resolved): clear it.
  if [[ "$st" == drain* ]] && scontrol show node "$N" 2>/dev/null | grep -q 'NO NETWORK ADDRESS'; then
    info "$N: clearing the old 'NO NETWORK ADDRESS' drain flag (resume) ..."
    hsudo scontrol update nodename="$N" state=resume >/dev/null 2>&1
    sleep 3
    st=$(sinfo -h -N -n "$N" -o '%T' 2>/dev/null | head -n1)
  fi
  case "$st" in
    idle)
      ok "$N: idle" ;;
    "")
      err "$N: not known to the controller. Is $N listed in slurm.conf NodeName=?"
      FAILED[$N]="not in slurm.conf" ;;
    unknown*|down*|*"*")
      err "$N: state '$st' - slurmd cannot talk to slurmctld."
      echo "        Check: name resolution ('ping head' on $N), firewall (ufw status), and on $N: sudo journalctl -u slurmd -n 20" >&2
      FAILED[$N]="state $st" ;;
    drain*|inval*)
      err "$N: state '$st'. Reason: $(scontrol show node "$N" | grep -i 'Reason=' | sed 's/^[[:space:]]*//')"
      echo "        'inval' = CPUs/RealMemory in slurm.conf are bigger than the real hardware: run 'slurmd -C' on $N and fix slurm.conf." >&2
      echo "        After fixing: sudo scontrol update nodename=$N state=resume" >&2
      FAILED[$N]="state $st" ;;
    *)
      warn "$N: state '$st' (expected 'idle')"
      FAILED[$N]="state $st" ;;
  esac
done

# ---------- Summary ----------
step "Summary"
if [ "${#FAILED[@]}" -eq 0 ]; then
  ok "All nodes done. Every node shows as idle. Test with: srun -w ${PREFIX}${SETUP_START}$([ "$SETUP_START" -ne "$SETUP_END" ] && echo ",...") hostname"
  exit 0
fi
err "Problems with:"
for N in "${!FAILED[@]}"; do echo "    - $N: ${FAILED[$N]}"; done | sort
echo "Fix the problems above and run this script again (it is safe to re-run)."
exit 1
