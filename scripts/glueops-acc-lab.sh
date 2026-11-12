#!/usr/bin/env bash
# Builds the release gate lab: two Hetzner dedicated servers as a Proxmox VE 9 cluster, then writes testacc.env.
# See .glueops/release-gate-lab.md. Run it directly (workstation or devcontainer), not through scripts/glueops-dev.sh:
# it drives the Robot API and SSH. Command output goes to $LAB_LOG; the screen shows only progress (and, on failure,
# the end of the log). It never prints the Robot credentials, the token secret or the lab IPs, except in stage "ips".
#
#   scripts/glueops-acc-lab.sh <stage>...      stages run in the order given; "all" runs every stage
#
#   rescue    Robot API: register the lab SSH key, boot both servers into rescue, hard reset. WIPES THE SERVERS
#             once install runs.
#   install   installimage Debian 13 on RAID 1, reboot into it
#   pve       Proxmox VE 9 from the no-subscription repo, reboot into its kernel
#   network   vmbr1: NAT bridge with DHCP (dnsmasq), the same on both nodes
#   cluster   pve1 creates the cluster, pve2 joins
#   storage   local datastore content types the tests need
#   firewall  pve-firewall: only the management IPs reach the nodes; VMs on vmbr1 get DHCP/DNS
#   token     API user and token; writes testacc.env (never prints the secret)
#   check     pre-flight: both nodes online, storage and bridge right, the token works
#   leftovers after the tests: lists test VMs and files left on the lab; exits 3 if there are any
#   ips       prints the node IPs (pve1 first)
#   ssh NODE [COMMAND...]  shell, or one command, on pve1 or pve2 as root
#
# Settings (environment):
#   ROBOT_ENV      file with HETZNER_ROBOT_USER / HETZNER_ROBOT_PASSWORD (default ~/.config/hetzner-robot.env)
#   LAB_SERVERS    Robot server numbers, pve1 first, e.g. "1234567 7654321" (required; usually set in ROBOT_ENV)
#   LAB_ALLOW_IPS  extra IPs allowed to reach the nodes (this machine's public IP is always added)
#   LAB_MY_IP      this machine's public IP for the firewall (default: looked up at https://ifconfig.me)
#   TESTACC_ENV    where to write testacc.env (default: ./testacc.env in the repo root)
#   LAB_LOG        command output log (default: ~/.cache/glueops-acc-lab/build.log)
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel)
ROBOT_ENV=${ROBOT_ENV:-$HOME/.config/hetzner-robot.env}
TESTACC_ENV=${TESTACC_ENV:-$ROOT/testacc.env}
KEY=${LAB_KEY:-$HOME/.ssh/glueops-acc-lab}
LAB_LOG=${LAB_LOG:-$HOME/.cache/glueops-acc-lab/build.log}
API=https://robot-ws.your-server.de
NAMES=(pve1 pve2)
CLUSTER=glueops-acc
BRIDGE=vmbr1
SUBNET=10.10.10

# Output may end up in PR comments, so IPv4 addresses are masked everywhere except in stage "ips".
mask() { sed -E 's/\b([0-9]{1,3}\.){3}[0-9]{1,3}\b/<ip>/g'; }
log() { echo "[$(date +%T)] $*" | mask; }
die() { echo "glueops-acc-lab: $*" | mask >&2; exit 1; }
# Runs a command (stdin passes through) with its output in $LAB_LOG; on failure shows the end of the log and stops.
quiet() {
	echo "--- $(date +%T) $*" >>"$LAB_LOG"
	"$@" >>"$LAB_LOG" 2>&1 || { tail -n 30 "$LAB_LOG" | mask >&2; die "failed (full output: $LAB_LOG)"; }
}

robot() { # method path [curl args...]; prints the JSON body. The credentials go in on stdin, not the command line.
	local m=$1 p=$2
	shift 2
	printf 'user = "%s:%s"\n' "$HETZNER_ROBOT_USER" "$HETZNER_ROBOT_PASSWORD" |
		curl -fsS -K - -X "$m" "$API$p" "$@"
}

load() {
	[ -r "$ROBOT_ENV" ] || die "no Robot credentials at $ROBOT_ENV (see .glueops/release-gate-lab.md)"
	set -a
	# shellcheck disable=SC1090
	. "$ROBOT_ENV"
	set +a
	[ -n "${LAB_SERVERS:-}" ] || die "set LAB_SERVERS (the two Robot server numbers, pve1 first) in $ROBOT_ENV"
	read -r -a SERVERS <<<"$LAB_SERVERS"
	[ ${#SERVERS[@]} = 2 ] || die "LAB_SERVERS must name exactly 2 servers"
	IPS=()
	local s j
	for s in "${SERVERS[@]}"; do
		if ! j=$(robot GET "/server/$s" 2>&1); then
			case $j in
			*"error: 404"*) die "Robot has no server $s: it's cancelled or LAB_SERVERS is wrong. A human orders new servers and sets LAB_SERVERS (see .glueops/release-gate-lab.md)" ;;
			*) die "Robot request for server $s failed ($(mask <<<"$j" | head -1)): check the credentials in $ROBOT_ENV and the network" ;;
			esac
		fi
		IPS+=("$(python3 -c 'import sys,json; print(json.load(sys.stdin)["server"]["server_ip"])' <<<"$j")")
	done
	[ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N '' -C glueops-acc-lab -f "$KEY"
	mkdir -p "$(dirname "$LAB_LOG")"
}

ssh_opts=(-o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
	-o ConnectTimeout=10 -o ServerAliveInterval=15)
on() { # node-index command...
	local i=$1
	shift
	ssh "${ssh_opts[@]}" -i "$KEY" "root@${IPS[$i]}" "$@" 2> >(mask >&2)
}
both() { on 0 "$@" && on 1 "$@"; }

wait_ssh() { # index max-seconds [expect-command]; returns 1 on timeout
	local i=$1 max=$2 test=${3:-true} t=0
	until on "$i" "$test" >/dev/null 2>&1; do
		t=$((t + 15))
		[ $t -le "$max" ] || return 1
		sleep 15
	done
}

# Reboots a node and waits for it. These servers sometimes don't come back from a soft reboot, so after 8 minutes
# this sends a hardware reset through Robot, up to twice, before giving up.
reboot_node() { # index expect-command
	local i=$1 test=$2 start resets=0
	start=$(date +%s)
	on "$i" 'systemctl reboot' >/dev/null 2>&1 || true
	sleep 30
	until wait_ssh "$i" 480 "$test"; do
		[ $resets -lt 2 ] || die "${NAMES[$i]} didn't come back after 2 hardware resets. Boot it into rescue (stage rescue) and check the console in Robot."
		resets=$((resets + 1))
		log "${NAMES[$i]}: not back after 8 minutes, hardware reset $resets/2 via Robot"
		robot POST "/reset/${SERVERS[$i]}" -d type=hw >/dev/null
		sleep 30
	done
	log "${NAMES[$i]}: back after $(($(date +%s) - start))s"
}

st_rescue() {
	local fp
	fp=$(ssh-keygen -E md5 -lf "$KEY.pub" | awk '{print $2}' | sed 's/^MD5://')
	if ! robot GET /key | grep -q "$fp"; then
		robot POST /key -d name=glueops-acc-lab --data-urlencode "data=$(cat "$KEY.pub")" >/dev/null
	fi
	for i in 0 1; do
		robot DELETE "/boot/${SERVERS[$i]}/rescue" >/dev/null 2>&1 || true
		robot POST "/boot/${SERVERS[$i]}/rescue" -d os=linux -d "authorized_key=$fp" >/dev/null
		robot POST "/reset/${SERVERS[$i]}" -d type=hw >/dev/null
		log "${NAMES[$i]}: rescue armed, hardware reset sent"
	done
	for i in 0 1; do
		wait_ssh "$i" 600 'test -d /root/.oldroot/nfs/install' ||
			die "${NAMES[$i]} didn't boot into rescue within 10 minutes; check Robot (is rescue armed?) and retry"
		log "${NAMES[$i]}: in rescue"
	done
}

st_install() {
	for i in 0 1; do
		on "$i" 'test -d /root/.oldroot/nfs/install' || die "${NAMES[$i]} isn't in rescue; run the rescue stage first"
		on "$i" "cat > /tmp/setup.conf" <<EOF
DRIVE1 /dev/nvme0n1
DRIVE2 /dev/nvme1n1
SWRAID 1
SWRAIDLEVEL 1
HOSTNAME ${NAMES[$i]}
PART /boot/efi esp 256M
PART /boot ext3 1024M
PART / ext4 all
IMAGE /root/.oldroot/nfs/install/../images/Debian-trixie-latest-amd64-base.tar.zst
EOF
		log "${NAMES[$i]}: installimage (about 2 minutes)"
		# The servers boot UEFI, so the layout needs an ESP. installimage needs TERM even unattended; on failure the
		# real reason is in /root/debug.txt, not in its output ("Cancelled.").
		on "$i" 'TERM=xterm /root/.oldroot/nfs/install/installimage -a -c /tmp/setup.conf >/tmp/installimage.log 2>&1' ||
			{ on "$i" 'grep -E "ERROR|error" /root/debug.txt | tail -5'; die "${NAMES[$i]}: installimage failed"; }
	done
	for i in 0 1; do reboot_node "$i" 'test ! -d /root/.oldroot && grep -q trixie /etc/os-release'; done
}

st_pve() {
	for i in 0 1; do
		log "${NAMES[$i]}: Proxmox VE repo, kernel (about 1 minute)"
		quiet on "$i" "bash -s ${IPS[$i]} ${NAMES[$i]}" <<'EOF'
set -euo pipefail
ip=$1 name=$2
export DEBIAN_FRONTEND=noninteractive
# A re-run after an interrupted run: finish any half-configured packages, and wait for a still-running apt.
dpkg --configure -a
apt() { apt-get -o DPkg::Lock::Timeout=300 "$@"; }
# PVE needs the hostname to resolve to the public IP, not 127.0.1.1.
sed -i "/[[:space:]]$name\([[:space:]]\|$\)/d" /etc/hosts
echo "$ip $name.acc.internal $name" >> /etc/hosts
hostnamectl set-hostname "$name"
curl -fsSL https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg \
  -o /usr/share/keyrings/proxmox-archive-keyring.gpg
cat > /etc/apt/sources.list.d/pve-install-repo.sources <<'SRC'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
SRC
apt update -q
apt full-upgrade -yq
apt install -yq proxmox-default-kernel
EOF
	done
	for i in 0 1; do reboot_node "$i" 'uname -r | grep -q pve'; done
	for i in 0 1; do
		log "${NAMES[$i]}: proxmox-ve packages (about 1-2 minutes)"
		quiet on "$i" 'bash -s' <<'EOF'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
dpkg --configure -a
apt() { apt-get -o DPkg::Lock::Timeout=300 "$@"; }
echo "postfix postfix/main_mailer_type select Local only" | debconf-set-selections
apt install -yq proxmox-ve postfix open-iscsi chrony
# The enterprise repos need a subscription; the no-subscription repo above is enough here.
rm -f /etc/apt/sources.list.d/pve-enterprise.sources /etc/apt/sources.list.d/ceph.sources
apt remove -yq linux-image-amd64 'linux-image-6.12*' os-prober || true
update-grub
# Key-only SSH: installimage leaves password logins on.
sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl reload ssh
pveversion
EOF
	done
}

st_network() {
	for i in 0 1; do
		quiet on "$i" "bash -s $BRIDGE $SUBNET" <<'EOF'
set -euo pipefail
br=$1 net=$2
up=$(ip -o -4 route show default | awk '{print $5; exit}')
# Installing proxmox-ve leaves a pending interfaces.new (its rewrite of Hetzner's file, without our bridge). PVE shows
# the pending file in its API and applies it at boot, which would drop the bridge, so discard it.
rm -f /etc/network/interfaces.new
if ! grep -q "^auto $br" /etc/network/interfaces; then
  cat >> /etc/network/interfaces <<IFACE

auto $br
iface $br inet static
    address $net.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    post-up   echo 1 > /proc/sys/net/ipv4/ip_forward
    post-up   iptables -t nat -A POSTROUTING -s $net.0/24 -o $up -j MASQUERADE
    post-down iptables -t nat -D POSTROUTING -s $net.0/24 -o $up -j MASQUERADE
IFACE
fi
ifreload -a
DEBIAN_FRONTEND=noninteractive apt-get install -yq dnsmasq
cat > /etc/dnsmasq.d/$br.conf <<CONF
interface=$br
bind-interfaces
dhcp-range=$net.100,$net.200,12h
dhcp-option=option:router,$net.1
dhcp-option=option:dns-server,1.1.1.1,8.8.8.8
CONF
systemctl enable --now dnsmasq
systemctl restart dnsmasq
EOF
		log "${NAMES[$i]}: $BRIDGE up with DHCP"
	done
}

st_cluster() {
	if on 0 'pvecm status >/dev/null 2>&1'; then
		log "pve1: cluster already exists"
	else
		quiet on 0 "pvecm create $CLUSTER"
	fi
	if on 1 'pvecm status >/dev/null 2>&1'; then
		log "pve2: already in the cluster"
	else
		# pvecm add asks for pve1's root password; instead use SSH, which needs pve1 to trust pve2's key first.
		on 1 'test -f /root/.ssh/id_rsa || ssh-keygen -q -t rsa -b 4096 -N "" -f /root/.ssh/id_rsa'
		# Right after pvecm create, pmxcfs restarts and /etc/pve (where root's authorized_keys lives) is read-only
		# until the cluster is quorate.
		wait_ssh 0 120 'pvecm status | grep -q "Quorate:.*Yes" && touch /etc/pve/.writable && rm /etc/pve/.writable' ||
			die "pve1's cluster filesystem didn't become writable"
		# shellcheck disable=SC2016 # expands on pve1, not here
		on 1 'cat /root/.ssh/id_rsa.pub' | on 0 'k=$(cat); grep -qxF "$k" /etc/pve/priv/authorized_keys || echo "$k" >> /etc/pve/priv/authorized_keys'
		quiet on 1 "ssh-keyscan -H ${IPS[0]} >> /root/.ssh/known_hosts 2>/dev/null; pvecm add ${IPS[0]} --use_ssh"
	fi
	on 0 'pvecm status | grep -qE "Quorate:.*Yes" && pvecm status | grep -qE "Nodes:[[:space:]]+2"' ||
		die "the cluster isn't quorate with 2 nodes (on pve1: pvecm status)"
	log "cluster $CLUSTER: 2 nodes, quorate"
}

st_storage() {
	quiet on 0 'pvesm set local --content iso,vztmpl,backup,import,images,snippets'
	log "local: content import,images,iso,snippets (plus backup,vztmpl)"
}

st_firewall() {
	local me allow ip n=0
	# -4: the nodes are reached over IPv4; an IPv6 address here would lock this machine out.
	me=${LAB_MY_IP:-$(curl -4fsS https://ifconfig.me)} || die "can't look up this machine's public IPv4; set LAB_MY_IP"
	allow="$me ${IPS[0]} ${IPS[1]} ${LAB_ALLOW_IPS:-}"
	{
		echo '[OPTIONS]'
		echo 'enable: 1'
		echo 'policy_in: DROP'
		echo 'policy_out: ACCEPT'
		echo
		# PVE otherwise treats the node's whole Hetzner subnet (shared with other customers) as trusted local_network.
		echo '[ALIASES]'
		echo "local_network ${IPS[0]}/32"
		echo
		echo '[IPSET management]'
		for ip in $allow; do echo "$ip"; done
		echo
		echo '[RULES]'
		echo 'IN ACCEPT -source +management -log nolog'
		echo "IN ACCEPT -i $BRIDGE -log nolog"
		echo 'IN ACCEPT -p icmp -log nolog'
	} | on 0 'cat > /etc/pve/firewall/cluster.fw.new && mv /etc/pve/firewall/cluster.fw.new /etc/pve/firewall/cluster.fw'
	quiet both 'pve-firewall restart'
	sleep 5
	for i in 0 1; do on "$i" true || die "lost SSH to ${NAMES[$i]} after the firewall change; fix it from rescue"; done
	on 0 "pve-firewall localnet | grep -qE 'using user defined local_network: ${IPS[0]}(/32)?\$'" ||
		die "pve-firewall didn't take the local_network alias"
	for ip in $allow; do n=$((n + 1)); done
	log "firewall on: $n IPs allowed (this machine, both nodes, LAB_ALLOW_IPS)"
}

st_token() {
	local secret
	quiet on 0 'pveum user list --output-format json | grep -q "terraform-acc@pve" || pveum user add terraform-acc@pve --comment "GlueOps fork release gate"'
	quiet on 0 'pveum acl modify / --users terraform-acc@pve --roles Administrator'
	quiet on 0 'pveum user token remove terraform-acc@pve gate >/dev/null 2>&1 || true'
	secret=$(on 0 'pveum user token add terraform-acc@pve gate --privsep 0 --output-format json' |
		python3 -c 'import sys,json; print(json.load(sys.stdin)["value"])')
	[ -n "$secret" ] || die "no token secret returned"
	(
		umask 077
		rm -f "$TESTACC_ENV" # a pre-existing file would keep its (maybe readable) mode
		cat >"$TESTACC_ENV" <<EOF
TF_ACC=1
PROXMOX_VE_ENDPOINT="https://${IPS[0]}:8006/"
PROXMOX_VE_API_TOKEN="terraform-acc@pve!gate=$secret"
PROXMOX_VE_INSECURE="true"
PROXMOX_VE_ACC_NODE_NAME="${NAMES[0]}"
PROXMOX_VE_ACC_NODE_2_NAME="${NAMES[1]}"
PROXMOX_VE_ACC_CLOUDINIT_BRIDGE="$BRIDGE"
PROXMOX_VE_ACC_CLOUDINIT_VLAN_ID="0"
EOF
	)
	log "wrote $TESTACC_ENV (mode 600; the token secret is not printed)"
}

st_check() {
	[ -r "$TESTACC_ENV" ] || die "no $TESTACC_ENV: run the token stage (or all, to rebuild the lab)"
	local ep tok out
	ep=$(sed -n 's/^PROXMOX_VE_ENDPOINT="\(.*\)"$/\1/p' "$TESTACC_ENV")
	tok=$(sed -n 's/^PROXMOX_VE_API_TOKEN="\(.*\)"$/\1/p' "$TESTACC_ENV")
	pve() { printf 'header = "Authorization: PVEAPIToken=%s"\n' "$tok" | curl -fsSk --connect-timeout 10 -K - "${ep}api2/json/$1" 2>&1; }
	# One answer for every failure: which fix to try, cheapest first.
	if ! out=$(pve nodes); then
		if on 0 true 2>/dev/null; then
			die "PVE API on pve1 refused the request ($(echo "$out" | mask | head -1)). The nodes are up: run \"$0 firewall token check\"; if that still fails, rebuild with \"$0 all\"."
		fi
		die "pve1 doesn't answer SSH or the API: the lab is down or gone, or the firewall doesn't allow this machine's IP. If this isn't the machine that built the lab, run \"$0 firewall\" from that one with LAB_ALLOW_IPS set; otherwise rebuild with \"$0 all\" (about 20 minutes)."
	fi
	expect() { # fix python-expression-on-d (the parsed JSON's data); prints the message, or the fix on failure
		python3 -c "import sys,json
d=json.load(sys.stdin)['data']
ok, msg = $2
print(msg) if ok else sys.exit('check failed: ' + msg)" || die "$1"
	}
	local reboot="a node is offline: see \"A node doesn't come back after a reboot\" in .glueops/release-gate-lab.md, or rebuild with \"$0 all\""
	echo "$out" | expect "$reboot" '(sorted(n["node"] for n in d if n["status"]=="online")==["pve1","pve2"], "nodes: "+", ".join(sorted(n["node"]+"="+n["status"] for n in d)))'
	pve storage/local | expect "rerun \"$0 storage check\"" '({"import","images","iso"} <= set(d["content"].split(",")), "local content: "+d["content"])'
	for n in pve1 pve2; do
		pve "nodes/$n/network?type=bridge" | expect "rerun \"$0 network check\"" "(any(x['iface']=='$BRIDGE' and x.get('active') for x in d), '$n $BRIDGE: ' + (', '.join(str(x.get('cidr')) + (' active' if x.get('active') else ' INACTIVE') for x in d if x['iface']=='$BRIDGE') or 'missing'))"
	done
	log "lab ready: run scripts/glueops-dev.sh ./testacc TestAccResourceCloudInitBootstrap, then: $0 leftovers"
}

st_leftovers() {
	local vms files f json
	json=$(on 0 "pvesh get /cluster/resources --type vm --output-format json") || die "can't list the cluster's VMs"
	vms=$(python3 -c 'import sys,json; print("\n".join(v["node"]+": "+str(v.get("name")) for v in json.load(sys.stdin)))' <<<"$json")
	files=
	for i in 0 1; do
		f=$(on "$i" "pvesm list local") || die "can't list local on ${NAMES[$i]}"
		files+=$(awk -v n="${NAMES[$i]}" 'NR>1 && $1 ~ /cloudinit-|TestAcc/ {print n ": " $1}' <<<"$f")
	done
	if [ -z "$vms$files" ]; then
		log "no leftovers: 0 VMs, 0 test files on local"
		return 0
	fi
	echo "leftovers (delete them before the next run; see the runbook):"
	printf '%s\n' "$vms" "$files" | sed '/^$/d; s/^/  /'
	exit 3
}

st_ips() { printf '%s %s\n' "${NAMES[0]}" "${IPS[0]}" "${NAMES[1]}" "${IPS[1]}"; }

[ $# -gt 0 ] || { sed -n '2,31p' "$0" >&2; exit 1; }
load
if [ "$1" = ssh ]; then
	case "${2:-}" in pve1) n=0 ;; pve2) n=1 ;; *) die "usage: $0 ssh pve1|pve2 [command...]" ;; esac
	shift 2
	exec ssh "${ssh_opts[@]}" -i "$KEY" "root@${IPS[$n]}" "$@" 2> >(mask >&2)
fi
if [ "$*" = all ]; then
	set -- rescue install pve network cluster storage firewall token check
fi
for stage in "$@"; do # validate everything first: a typo must not leave the servers half-done
	case "$stage" in
	rescue | install | pve | network | cluster | storage | firewall | token | check | leftovers | ips) ;;
	all) die "all must be the only argument" ;;
	*) die "unknown stage: $stage" ;;
	esac
done
for stage in "$@"; do
	log "== $stage"
	"st_$stage"
done
