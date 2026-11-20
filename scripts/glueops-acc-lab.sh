#!/usr/bin/env bash
# Builds the release gate lab, a Proxmox VE 9 cluster of two nodes, then writes testacc.env. Two backends:
#   local (default)  two nested KVM VMs in one Docker container on this machine (needs /dev/kvm with nesting)
#   hetzner          two Hetzner dedicated servers, driven through the Robot API (LAB_BACKEND=hetzner)
# See .glueops/release-gate-lab.md. Run it directly (workstation or devcontainer), not through scripts/glueops-dev.sh:
# it drives Docker or the Robot API, and SSH. Command output goes to $LAB_LOG; the screen shows only progress (and, on
# failure, the end of the log). It never prints the Robot credentials, the token secret or the lab IPs, except in
# stage "ips".
#
#   scripts/glueops-acc-lab.sh <stage>...      stages run in the order given; "all" runs every stage of the backend
#
# Both backends:
#   pve       Proxmox VE 9 from the no-subscription repo, reboot into its kernel
#   network   vmbr1: NAT bridge with DHCP (dnsmasq), the same on both nodes
#   cluster   pve1 creates the cluster, pve2 joins
#   storage   local datastore content types the tests need
#   token     API user and token; writes testacc.env (never prints the secret)
#   check     pre-flight: both nodes online, storage and bridge right, the token works
#   leftovers after the tests: lists test VMs and files left on the lab; exits 3 if there are any
#   ips       prints the node IPs (pve1 first)
#   ssh NODE [COMMAND...]  shell, or one command, on pve1 or pve2 as root
#   test [TESTACC ARGS...]  ./testacc through scripts/glueops-dev.sh (default: TestAccResourceCloudInitBootstrap)
# local only ("all" = up pve network cluster storage token check):
#   up        preflight, then create the lab container and VMs, or start a stopped lab (keeps its disks)
#   status    container, VMs, SSH and cluster state; exits 4 if the lab isn't running
#   down      powers both nodes off cleanly and stops the container; disks are kept for the next "up"
#   destroy   removes the lab container and its volume (all disks); never part of "all"
# hetzner only ("all" = rescue install pve network cluster storage firewall token check):
#   rescue    Robot API: register the lab SSH key, boot both servers into rescue, hard reset. WIPES THE SERVERS
#             once install runs.
#   install   installimage Debian 13 on RAID 1, reboot into it
#   firewall  pve-firewall: only the management IPs reach the nodes; VMs on vmbr1 get DHCP/DNS
#
# Settings (environment):
#   LAB_BACKEND    local (default) or hetzner
#   TESTACC_ENV    where to write testacc.env (default: ./testacc.env in the repo root)
#   LAB_LOG        command output log (default: ~/.cache/glueops-acc-lab/build.log, or local.log for local)
#   local:   LAB_VCPUS (default 8) and LAB_MEM_MB (default 10240) per node, set when the container is created
#   hetzner: ROBOT_ENV      file with HETZNER_ROBOT_USER / HETZNER_ROBOT_PASSWORD (default ~/.config/hetzner-robot.env)
#            LAB_SERVERS    Robot server numbers, pve1 first, e.g. "1234567 7654321" (required; usually in ROBOT_ENV)
#            LAB_ALLOW_IPS  extra IPs allowed to reach the nodes (this machine's public IP is always added)
#            LAB_MY_IP      this machine's public IP for the firewall (default: looked up at https://ifconfig.me)
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel)
LAB_BACKEND=${LAB_BACKEND:-local}
case "$LAB_BACKEND" in local | hetzner) ;; *) echo "glueops-acc-lab: LAB_BACKEND must be local or hetzner" >&2; exit 1 ;; esac
# How to run this script again, for the hints it prints.
CMD=$0
[ "$LAB_BACKEND" = local ] || CMD="LAB_BACKEND=hetzner $0"
ROBOT_ENV=${ROBOT_ENV:-$HOME/.config/hetzner-robot.env}
TESTACC_ENV=${TESTACC_ENV:-$ROOT/testacc.env}
if [ "$LAB_BACKEND" = local ]; then
	KEY=${LAB_KEY:-$HOME/.ssh/glueops-acc-lab-local}
	LAB_LOG=${LAB_LOG:-$HOME/.cache/glueops-acc-lab/local.log}
else
	KEY=${LAB_KEY:-$HOME/.ssh/glueops-acc-lab}
	LAB_LOG=${LAB_LOG:-$HOME/.cache/glueops-acc-lab/build.log}
fi
API=https://robot-ws.your-server.de
NAMES=(pve1 pve2)
CLUSTER=glueops-acc
BRIDGE=vmbr1
SUBNET=10.10.10

# Local backend. The nodes live on br0 inside the container, so their IPs are reachable only through it.
LAB_CONTAINER=glueops-acc-lab
LAB_VOLUME=glueops-acc-lab
LOCAL_IPS=(10.77.0.11 10.77.0.12)
LAB_VCPUS=${LAB_VCPUS:-8}
LAB_MEM_MB=${LAB_MEM_MB:-10240}
# A dated build, so the disks' backing file never changes under them; a new image means destroy and rebuild.
DEBIAN_IMAGE=debian-13-generic-amd64-20261111-2659.qcow2
DEBIAN_IMAGE_URL=https://cloud.debian.org/images/cloud/trixie/20261111-2659/$DEBIAN_IMAGE
DEBIAN_IMAGE_SHA512=ec8c175e39d59e711798c3a2f22ba11b9aee9bca1887c7e505a800aeffd5d7616099bd0e9fad869efba96100fe09d2c8b49d6d7001d501f0056c556bdc25b605
LAB_DOCKERFILE='FROM debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2
RUN apt-get update && apt-get install -y --no-install-recommends qemu-system-x86 qemu-utils seabios ipxe-qemu \
      cloud-image-utils iproute2 iptables curl ca-certificates netcat-openbsd socat procps && rm -rf /var/lib/apt/lists/*'
# The container's main process: bridge, NAT, the two VMs. On docker stop (SIGTERM) it powers the VMs off through QMP
# and waits, because the disks use cache=unsafe and a killed qemu can leave them corrupt.
# shellcheck disable=SC2016 # expands in the container
LAB_ENTRYPOINT='set -euo pipefail
cd /lab
say() { echo "$(date +%T) $*"; }
if [ ! -f "$DEBIAN_IMAGE" ]; then
	say "downloading $DEBIAN_IMAGE"
	curl -fsSL -o image.part "$DEBIAN_IMAGE_URL"
	echo "$DEBIAN_IMAGE_SHA512  image.part" | sha512sum -c --quiet || { say "image checksum mismatch"; exit 1; }
	mv image.part "$DEBIAN_IMAGE"
fi
# Each container start gets a fresh network namespace, so the bridge, taps and rules never exist yet.
ip link add br0 type bridge
ip addr add 10.77.0.1/24 dev br0
ip link set br0 up
iptables -t nat -A POSTROUTING -s 10.77.0.0/24 ! -o br0 -j MASQUERADE
# No cloud metadata service for the nodes, if the host has one.
iptables -I FORWARD -s 10.77.0.0/24 -d 169.254.169.254 -j DROP
pids=()
for n in 1 2; do
	name=pve$n tap=tap$n mac=52:54:00:77:00:1$n
	ip tuntap add dev $tap mode tap
	ip link set $tap master br0 up
	if [ ! -f $name.qcow2 ]; then
		qemu-img create -q -f qcow2 -b "$DEBIAN_IMAGE" -F qcow2 $name.qcow2 80G
		printf "#cloud-config\ndisable_root: false\nssh_pwauth: false\nusers:\n  - name: root\n    ssh_authorized_keys: [\"%s\"]\n" \
			"$LAB_PUBKEY" >$name-user-data
		printf "instance-id: %s\nlocal-hostname: %s\n" $name $name >$name-meta-data
		printf "version: 2\nethernets:\n  lan:\n    match: {macaddress: \"%s\"}\n    set-name: eth0\n    addresses: [10.77.0.1%s/24]\n    routes: [{to: default, via: 10.77.0.1}]\n    nameservers: {addresses: [1.1.1.1, 8.8.8.8]}\n" \
			$mac $n >$name-net
		cloud-localds -N $name-net $name-seed.iso $name-user-data $name-meta-data
	fi
	rm -f $name.qmp
	qemu-system-x86_64 -name $name -enable-kvm -cpu host -smp "$LAB_VCPUS" -m "$LAB_MEM_MB" -machine q35 \
		-drive file=$name.qcow2,if=virtio,cache=unsafe,discard=unmap,detect-zeroes=unmap \
		-drive file=$name-seed.iso,if=virtio,media=cdrom \
		-netdev tap,id=n0,ifname=$tap,script=no,downscript=no -device virtio-net-pci,netdev=n0,mac=$mac \
		-device virtio-rng-pci -serial file:$name-serial.log -display none -monitor none \
		-qmp unix:/lab/$name.qmp,server=on,wait=off &
	pids+=($!)
	say "$name started ($LAB_VCPUS vCPU, $LAB_MEM_MB MB)"
done
powerdown() {
	say "stopping: powering the VMs off"
	for q in pve1.qmp pve2.qmp; do
		printf "%s\n" "{\"execute\":\"qmp_capabilities\"}" "{\"execute\":\"system_powerdown\"}" |
			socat -t2 - UNIX-CONNECT:$q >/dev/null 2>&1 || true
	done
	wait
	exit 0
}
trap powerdown TERM INT
wait
say "both VMs exited"'

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
	if [ "$LAB_BACKEND" = local ]; then
		IPS=("${LOCAL_IPS[@]}")
		[ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N '' -C glueops-acc-lab-local -f "$KEY"
		mkdir -p "$(dirname "$LAB_LOG")"
		# The node IPs exist only inside the lab container's network; SSH tunnels through it.
		ssh_opts+=(-o "ProxyCommand=docker exec -i $LAB_CONTAINER nc %h %p")
		return
	fi
	[ -r "$ROBOT_ENV" ] || die "no Robot credentials at $ROBOT_ENV (see .glueops/release-gate-lab.md)"
	set -a
	# shellcheck disable=SC1090
	. "$ROBOT_ENV"
	set +a
	[ -n "${LAB_SERVERS:-}" ] || die "set LAB_SERVERS (the two Robot server numbers, pve1 first) in $ROBOT_ENV"
	read -r -a SERVERS <<<"$LAB_SERVERS"
	[ ${#SERVERS[@]} = 2 ] || die "LAB_SERVERS must name exactly 2 servers"
	# Otherwise both "nodes" are one machine, and the build hangs at its first reboot.
	[ "${SERVERS[0]}" != "${SERVERS[1]}" ] || die "LAB_SERVERS names server ${SERVERS[0]} twice; it must be 2 different servers"
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
	if [ "$LAB_BACKEND" = local ]; then
		wait_ssh "$i" 600 "$test" ||
			die "${NAMES[$i]} didn't come back within 10 minutes; see its console: docker exec $LAB_CONTAINER tail -50 /lab/${NAMES[$i]}-serial.log"
		log "${NAMES[$i]}: back after $(($(date +%s) - start))s"
		return
	fi
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
		# installimage needs an ESP exactly when rescue booted UEFI (it checks /sys/firmware/efi too); BIOS uses the MBR.
		boot=$(on "$i" 'test -d /sys/firmware/efi && echo UEFI || echo BIOS') || die "${NAMES[$i]}: can't tell how it boots"
		esp=
		[ "$boot" = BIOS ] || esp='PART /boot/efi esp 256M'
		# Servers come with NVMe or SATA disks.
		read -r -a drives <<<"$(on "$i" 'lsblk -dnpo NAME,TYPE,RM' | awk '$2=="disk" && $3==0 {print $1}' | sort | tr '\n' ' ')"
		[ ${#drives[@]} = 2 ] || die "${NAMES[$i]} has ${#drives[@]} disks (${drives[*]:-none}); the RAID 1 layout needs exactly 2"
		on "$i" "cat > /tmp/setup.conf" <<EOF
DRIVE1 ${drives[0]}
DRIVE2 ${drives[1]}
SWRAID 1
SWRAIDLEVEL 1
HOSTNAME ${NAMES[$i]}
${esp}
PART /boot ext3 1024M
PART / ext4 all
IMAGE /root/.oldroot/nfs/install/../images/Debian-trixie-latest-amd64-base.tar.zst
EOF
		log "${NAMES[$i]}: installimage on ${drives[*]#/dev/}, $boot boot (about 2 minutes)"
		# installimage needs TERM even unattended; on failure the real reason is in /root/debug.txt, not in its output
		# ("Cancelled.").
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
	if [ "$LAB_BACKEND" = local ]; then
		# The cloud image runs eth0 on systemd-networkd, so ifupdown2 (from proxmox-ve) has no /run/network, and ifreload
		# misreports that as "Another instance of this program is already running". networking.service creates it at boot.
		quiet both 'mkdir -p /run/network && systemctl enable networking'
	fi
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

local_image() { # builds the lab image if missing; prints its tag
	local tag
	tag=glueops-acc-lab:$(printf '%s' "$LAB_DOCKERFILE" | sha256sum | cut -c1-12)
	if ! docker image inspect "$tag" >/dev/null 2>&1; then
		log "building the lab image (about 1 minute, once)" >&2
		printf '%s\n' "$LAB_DOCKERFILE" | quiet docker build -q -t "$tag" -
	fi
	echo "$tag"
}

local_state() { # running | stopped | absent
	local s
	s=$(docker inspect -f '{{.State.Running}}' "$LAB_CONTAINER" 2>/dev/null) || { echo absent; return; }
	[ "$s" = true ] && echo running || echo stopped
}

local_has_disks() { # the volume holds node disks from an earlier build
	docker volume inspect "$LAB_VOLUME" >/dev/null 2>&1 &&
		docker run --rm -v "$LAB_VOLUME:/lab" "$(local_image)" test -f /lab/pve1.qcow2
}

local_check_ram() {
	local need have
	need=$((2 * LAB_MEM_MB + 2048))
	have=$(awk '/^MemAvailable:/ {print int($2 / 1024)}' /proc/meminfo)
	[ "$have" -ge "$need" ] ||
		die "need ${need} MB of free RAM for two ${LAB_MEM_MB} MB nodes, have ${have} MB: stop other containers or set LAB_MEM_MB lower"
}

local_preflight() {
	local img=$1 have nested
	docker info >/dev/null 2>&1 || die "Docker isn't reachable: start Docker, or run this where docker works"
	docker run --rm --cap-drop ALL --device /dev/kvm "$img" bash -c 'exec 3<>/dev/kvm' 2>/dev/null ||
		die "/dev/kvm can't be opened from a container: this machine has no KVM; use the Hetzner lab (LAB_BACKEND=hetzner, see .glueops/release-gate-lab.md)"
	nested=$(cat /sys/module/kvm_amd/parameters/nested /sys/module/kvm_intel/parameters/nested 2>/dev/null || true)
	grep -qE '^(1|Y)$' <<<"$nested" ||
		die "nested virtualization is off (kvm_amd/kvm_intel nested isn't 1): the lab's test VMs couldn't use KVM; use the Hetzner lab"
	local_check_ram
	have=$(docker run --rm -v "$LAB_VOLUME:/lab" "$img" df -Pm /lab | awk 'NR == 2 {print $4}')
	[ "$have" -ge 40000 ] || die "need 40 GB free where Docker keeps volumes, have $((have / 1024)) GB: free disk space"
}

st_up() {
	local img state
	img=$(local_image)
	state=$(local_state)
	case $state in
	running) log "lab container is already running" ;;
	stopped)
		log "lab exists: starting its VMs (about 1-2 minutes)"
		local_check_ram
		quiet docker start "$LAB_CONTAINER"
		;;
	absent)
		if local_has_disks; then
			log "lab disks exist without a container: starting the VMs from them (about 1-2 minutes)"
		else
			log "building a new lab (about 15 minutes for up, pve, network, cluster, storage, token, check)"
		fi
		local_preflight "$img"
		quiet docker run -d --name "$LAB_CONTAINER" --init --restart no --stop-timeout 300 \
			--cap-drop ALL --cap-add NET_ADMIN --security-opt no-new-privileges \
			--device /dev/kvm --device /dev/net/tun --sysctl net.ipv4.ip_forward=1 -v "$LAB_VOLUME:/lab" \
			-e "DEBIAN_IMAGE=$DEBIAN_IMAGE" -e "DEBIAN_IMAGE_URL=$DEBIAN_IMAGE_URL" \
			-e "DEBIAN_IMAGE_SHA512=$DEBIAN_IMAGE_SHA512" -e "LAB_PUBKEY=$(cat "$KEY.pub")" \
			-e "LAB_VCPUS=$LAB_VCPUS" -e "LAB_MEM_MB=$LAB_MEM_MB" \
			"$img" bash -c "$LAB_ENTRYPOINT"
		;;
	esac
	for i in 0 1; do
		local t=0
		until on "$i" 'cloud-init status --wait >/dev/null 2>&1; true' >/dev/null 2>&1; do
			[ "$(local_state)" = running ] || die "the lab container stopped; its output says why: docker logs $LAB_CONTAINER"
			t=$((t + 15))
			[ $t -le 600 ] ||
				die "${NAMES[$i]}: no SSH after 10 minutes; see docker logs $LAB_CONTAINER and its console: docker exec $LAB_CONTAINER tail -50 /lab/${NAMES[$i]}-serial.log"
			sleep 15
		done
		on "$i" 'grep -qwE "svm|vmx" /proc/cpuinfo && test -c /dev/kvm' ||
			die "${NAMES[$i]} has no KVM inside it, so PVE couldn't run the test VMs: is nested virtualization on?"
		# The BIOS cloud image's grub-pc asks for its install disk when the PVE kernel is installed.
		on "$i" 'echo "grub-pc grub-pc/install_devices multiselect /dev/vda" | debconf-set-selections'
		log "${NAMES[$i]}: up"
	done
	if on 0 'pvecm status >/dev/null 2>&1'; then
		wait_ssh 0 300 'pvecm status | grep -q "Quorate:.*Yes"' || die "the cluster didn't become quorate within 5 minutes; if check fails, run destroy, then all"
		log "cluster is up: next, $CMD check"
	elif [ "$LAST_STAGE" = up ]; then
		log "nodes are up: next, $CMD pve network cluster storage token check (or all)"
	fi
}

st_status() {
	local state q
	state=$(local_state)
	if [ "$state" != running ]; then
		if [ "$state" = stopped ] || local_has_disks; then
			echo "lab stopped (disks kept): run $CMD up"
		else
			echo "no local lab: run $CMD all (about 15 minutes)"
		fi
		exit 4
	fi
	for i in 0 1; do
		# shellcheck disable=SC2016 # expands in the container
		q=$(docker exec "$LAB_CONTAINER" bash -c 'printf "%s\n" "{\"execute\":\"qmp_capabilities\"}" "{\"execute\":\"query-status\"}" |
			socat -t2 - UNIX-CONNECT:/lab/'"${NAMES[$i]}"'.qmp 2>/dev/null | grep -o "\"status\": *\"[a-z-]*\"" | tail -1' || true)
		q=${q##*\"status\": \"}
		q=${q%\"}
		echo "${NAMES[$i]}: VM ${q:-not running}$([ "$q" = paused ] && echo ' (disk full? see docker system df)'), SSH $(on "$i" true >/dev/null 2>&1 && echo ok || echo down)"
	done
	if on 0 'pvecm status 2>/dev/null | grep -q "Quorate:.*Yes"'; then echo "cluster: quorate"; else echo "cluster: not quorate or not built"; fi
}

st_down() {
	[ "$(local_state)" = running ] || { log "lab isn't running"; return; }
	log "powering both nodes off (up to 5 minutes)"
	# The entrypoint powers the VMs off through QMP on SIGTERM; PVE may take up to 3 minutes per guest.
	quiet docker stop -t 300 "$LAB_CONTAINER"
	log "lab stopped; disks kept: $CMD up starts it again"
}

st_destroy() {
	quiet docker rm -f "$LAB_CONTAINER"
	if docker volume inspect "$LAB_VOLUME" >/dev/null 2>&1; then quiet docker volume rm "$LAB_VOLUME"; fi
	if [ -f "$TESTACC_ENV" ] && grep -qx '# lab: local' "$TESTACC_ENV"; then rm -f "$TESTACC_ENV"; fi
	log "local lab removed (container, disks and its testacc.env); the lab key $KEY is kept"
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
# lab: $LAB_BACKEND
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
	local ep tok out built
	built=$(sed -n 's/^# lab: //p' "$TESTACC_ENV")
	[ "${built:-hetzner}" = "$LAB_BACKEND" ] ||
		die "$TESTACC_ENV is for the ${built:-hetzner} lab, not $LAB_BACKEND: rerun the token stage with LAB_BACKEND=$LAB_BACKEND"
	ep=$(sed -n 's/^PROXMOX_VE_ENDPOINT="\(.*\)"$/\1/p' "$TESTACC_ENV")
	tok=$(sed -n 's/^PROXMOX_VE_API_TOKEN="\(.*\)"$/\1/p' "$TESTACC_ENV")
	pve() { # a path under api2/json; retried, since a node's API can be briefly unreachable right after the cluster forms
		local n out
		for n in 1 2 3; do
			out=$(printf 'header = "Authorization: PVEAPIToken=%s"\n' "$tok" | lab_curl -fsSk --connect-timeout 10 -K - "${ep}api2/json/$1" 2>&1) &&
				{ echo "$out"; return; }
			[ $n = 3 ] || sleep 5
		done
		echo "$out"
		return 1
	}
	# One answer for every failure: which fix to try, cheapest first.
	if ! out=$(pve nodes); then
		if [ "$LAB_BACKEND" = local ]; then
			die "PVE API on pve1 refused the request ($(echo "$out" | mask | head -1)): run \"$CMD token check\"; if that still fails, rebuild it with \"$CMD destroy\" and then \"$CMD all\" (about 15 minutes)."
		fi
		if on 0 true 2>/dev/null; then
			die "PVE API on pve1 refused the request ($(echo "$out" | mask | head -1)). The nodes are up: run \"$CMD firewall token check\"; if that still fails, rebuild with \"$CMD all\"."
		fi
		die "pve1 doesn't answer SSH or the API: the lab is down or gone, or the firewall doesn't allow this machine's IP. If this isn't the machine that built the lab, run \"$CMD firewall\" from that one with LAB_ALLOW_IPS set; otherwise rebuild with \"$CMD all\" (about 20 minutes)."
	fi
	expect() { # fix python-expression-on-d (the parsed JSON's data); prints the message, or the fix on failure
		python3 -c "import sys,json
d=json.load(sys.stdin)['data']
ok, msg = $2
print(msg) if ok else sys.exit('check failed: ' + msg)" || die "$1"
	}
	local reboot="a node is offline: see \"A node doesn't come back after a reboot\" in .glueops/release-gate-lab.md, or rebuild with \"$CMD all\""
	echo "$out" | expect "$reboot" '(sorted(n["node"] for n in d if n["status"]=="online")==["pve1","pve2"], "nodes: "+", ".join(sorted(n["node"]+"="+n["status"] for n in d)))'
	pve storage/local | expect "rerun \"$CMD storage check\"" '({"import","images","iso"} <= set(d["content"].split(",")), "local content: "+d["content"])'
	for n in pve1 pve2; do
		pve "nodes/$n/network?type=bridge" | expect "rerun \"$CMD network check\"" "(any(x['iface']=='$BRIDGE' and x.get('active') for x in d), '$n $BRIDGE: ' + (', '.join(str(x.get('cidr')) + (' active' if x.get('active') else ' INACTIVE') for x in d if x['iface']=='$BRIDGE') or 'missing'))"
	done
	log "lab ready ($(on 0 pveversion | mask)): run $CMD test, then: $CMD leftovers"
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

# curl from where the lab's API is reachable: here for Hetzner, inside the lab container for local.
lab_curl() {
	if [ "$LAB_BACKEND" = local ]; then docker exec -i "$LAB_CONTAINER" curl "$@"; else curl "$@"; fi
}

st_ips() { printf '%s %s\n' "${NAMES[0]}" "${IPS[0]}" "${NAMES[1]}" "${IPS[1]}"; }

[ $# -gt 0 ] || { sed -n '2,42p' "$0" >&2; exit 1; }
if [ "$1" != ssh ] && [ "$1" != test ]; then
	if [ "$*" = all ]; then
		if [ "$LAB_BACKEND" = local ]; then
			set -- up pve network cluster storage token check
		else
			set -- rescue install pve network cluster storage firewall token check
		fi
	fi
	for stage in "$@"; do # validate everything first: a typo must not leave the servers half-done
		case "$stage" in
		pve | network | cluster | storage | token | check | leftovers | ips) ;;
		up | status | down | destroy)
			[ "$LAB_BACKEND" = local ] || die "$stage is for the local lab: run it without LAB_BACKEND=hetzner"
			;;
		rescue | install | firewall)
			[ "$LAB_BACKEND" = hetzner ] || die "$stage is for the Hetzner lab only: run it with LAB_BACKEND=hetzner"
			;;
		all) die "all must be the only argument" ;;
		*) die "unknown stage: $stage" ;;
		esac
	done
fi
load
if [ "$1" = ssh ]; then
	case "${2:-}" in pve1) n=0 ;; pve2) n=1 ;; *) die "usage: $CMD ssh pve1|pve2 [command...]" ;; esac
	shift 2
	exec ssh "${ssh_opts[@]}" -i "$KEY" "root@${IPS[$n]}" "$@" 2> >(mask >&2)
fi
if [ "$LAB_BACKEND" = local ] && [ "$*" != status ]; then
	# One run at a time (test included): an agent and a person (or two agents) using the same lab would break it.
	exec 9>"$(dirname "$LAB_LOG")/local.lock"
	flock -n 9 || die "another glueops-acc-lab.sh run is using the local lab; wait for it to finish"
fi
if [ "$1" = test ]; then
	shift
	[ -r "$TESTACC_ENV" ] || die "no $TESTACC_ENV: build the lab first ($CMD all)"
	built=$(sed -n 's/^# lab: //p' "$TESTACC_ENV")
	[ "${built:-hetzner}" = "$LAB_BACKEND" ] ||
		die "$TESTACC_ENV is for the ${built:-hetzner} lab, not $LAB_BACKEND: rerun the token stage with LAB_BACKEND=$LAB_BACKEND"
	cd "$ROOT"
	if [ "$LAB_BACKEND" = local ]; then
		[ "$(local_state)" = running ] || die "the local lab isn't running: run $CMD up"
		# The tests join the lab container's network, the only place the node IPs exist.
		export GLUEOPS_DEV_NETWORK="container:$LAB_CONTAINER"
	fi
	# Only flags ("-- -v", "--tier ..."): keep the default test.
	case "${1:-}" in "" | --) set -- TestAccResourceCloudInitBootstrap "$@" ;; esac
	exec scripts/glueops-dev.sh ./testacc "$@"
fi
LAST_STAGE=${*: -1}
for stage in "$@"; do
	if [ "$LAB_BACKEND" = local ]; then
		case "$stage" in
		up | status | down | destroy) ;;
		*) [ "$(local_state)" = running ] || die "the local lab isn't running: run $CMD up (or $CMD all to build one)" ;;
		esac
	fi
	log "== $stage"
	"st_$stage"
done
