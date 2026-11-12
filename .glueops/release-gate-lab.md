# Release gate lab: two Proxmox VE nodes on Hetzner

This sets up the small Proxmox VE cluster that the release gate's acceptance tests run against, and shows how to fill
in `testacc.env` from it. It's a **dedicated test cluster**: the tests create and delete VMs, so don't point them at a
cluster that runs anything real.

The gate itself (what to run and what must pass) is in [FORK.md](../FORK.md#release-gate).

## What the tests need

`./testacc TestAccResourceCloudInitBootstrap` runs 3 subtests in parallel. Each one:
- downloads the Ubuntu 24.04 cloud image (about 600 MB) into the `local` datastore;
- creates a q35 VM with 2 GB RAM and an 8 GB disk on `local`, plus a small cloud-init seed ISO;
- waits for cloud-init and the guest agent, then deletes everything.

One subtest live-migrates its VM to the second node. The run takes about 4 minutes.

| Requirement | Why |
| ----------- | --- |
| 2 nodes in one PVE cluster, Proxmox VE 9.x | the migration subtest needs a second node; the provider targets PVE 9 |
| 6 GB RAM and 30 GB on `local` free on node 1; 2 GB RAM and 8 GB free on node 2 | 3 VMs at once, plus the migrated one |
| `local` with the `import`, `images` and `iso` content types | image download, VM disks and the seed ISO all go to `local` |
| A bridge with DHCP and internet access on **both** nodes, same name | the guests `apt install qemu-guest-agent`; a migrated VM must find its bridge |
| PVE API (port 8006) reachable from the machine running the tests | the tests use only the API, no SSH |
| An API token that can manage VMs and `local` | create, start, migrate and delete VMs; upload and delete files |

## 1. Servers

Order **two dedicated servers in the same Hetzner location**, so the cluster link has low latency. Any current AMD
model with at least 32 GB RAM and NVMe disks is plenty, e.g. AX41 or AX52. In this doc they're `pve1` and `pve2`, with
public IPs `PVE1_IP` and `PVE2_IP`.

Optional but recommended: put both servers on a Hetzner **vSwitch**. That gives them a private link for the cluster
traffic, so corosync doesn't run over the public internet.

## 2. Install Debian 13, then Proxmox VE 9

In the Hetzner Robot rescue system, run `installimage`, choose **Debian 13 (trixie)**, and set the hostname to
`pve1` or `pve2`.
- Use software RAID 1 across the two NVMe disks.
- Give the root filesystem most of the space, because `local` (`/var/lib/vz`) lives on it.

Then follow Proxmox's own guide, [Install Proxmox VE on Debian 13 Trixie](https://pve.proxmox.com/wiki/Install_Proxmox_VE_on_Debian_13_Trixie),
on each server. In short:
- make `/etc/hosts` map the hostname to the public IP, not to 127.0.1.1;
- add the Proxmox VE repository and key;
- `apt full-upgrade`, then install the Proxmox kernel and reboot;
- install `proxmox-ve postfix open-iscsi chrony`;
- remove the Debian kernel and `os-prober`.

Check with `pveversion` that it reports `pve-manager/9.x` on both servers.

## 3. Lock down access

The PVE web UI and API listen on port 8006 on the public IP. Use the Hetzner Robot firewall, or `pve-firewall`, to
allow 8006 and 22 **only from the IPs that run the tests**. If the servers are on a vSwitch, also allow the cluster
ports (UDP 5405-5412 for corosync, TCP 60000-60050 for migration) between them.

## 4. Guest network: a NAT bridge with DHCP, on both nodes

Hetzner only routes traffic from the server's own MAC address, so test VMs can't sit on the public network directly.
Give each node an identical private NAT bridge instead. The bridge name, subnet and gateway must be the same on both
nodes, so a VM that migrates keeps working.

Append to `/etc/network/interfaces` on **each** node. Replace `enp0s31f6` with the server's public interface, from
`ip route show default`:

```text
auto vmbr1
iface vmbr1 inet static
    address 10.10.10.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    post-up   echo 1 > /proc/sys/net/ipv4/ip_forward
    post-up   iptables -t nat -A POSTROUTING -s 10.10.10.0/24 -o enp0s31f6 -j MASQUERADE
    post-down iptables -t nat -D POSTROUTING -s 10.10.10.0/24 -o enp0s31f6 -j MASQUERADE
```

Bring it up with `ifreload -a`. Then run DHCP on it with dnsmasq:

```sh
apt install -y dnsmasq
cat > /etc/dnsmasq.d/vmbr1.conf <<'EOF'
interface=vmbr1
bind-interfaces
dhcp-range=10.10.10.100,10.10.10.200,12h
dhcp-option=option:router,10.10.10.1
dhcp-option=option:dns-server,1.1.1.1,8.8.8.8
EOF
systemctl restart dnsmasq
```

The two nodes' bridges are separate networks, so handing out the same range on both is fine.

## 5. Make the two nodes a cluster

On `pve1`, run `pvecm create glueops-acc`. Add `--link0 <vSwitch IP>` if you use a vSwitch.

On `pve2`, run `pvecm add PVE1_IP`, adding `--link0 <pve2 vSwitch IP>` with a vSwitch.

Check that `pvecm status` shows 2 nodes and `Quorate: Yes`.

## 6. Storage: let `local` hold everything the tests use

`local` is shared config, so this is one command on either node:

```sh
pvesm set local --content iso,vztmpl,backup,import,images,snippets
```

Check with `pvesm status --content images`. It should list `local` on both nodes.

## 7. API user and token

On either node:

```sh
pveum user add terraform-acc@pve --comment "GlueOps fork release gate"
pveum acl modify / --users terraform-acc@pve --roles Administrator
pveum user token add terraform-acc@pve gate --privsep 0
```

The last command prints the token's secret **once**. The token value for `testacc.env` is
`terraform-acc@pve!gate=<that secret>`.
- Keep it in your password manager.
- Never paste it into chat, a PR or a commit.
- If it leaks, remove it with `pveum user token remove terraform-acc@pve gate` and create a new one.

The Administrator role on `/` is the simple choice for a dedicated test cluster. A least-privilege role hasn't been
tested.

## 8. Fill in `testacc.env`

Create `testacc.env` in the root of your provider clone. It's gitignored by `*.env`; never commit it.

| Variable | Value |
| -------- | ----- |
| `TF_ACC` | `1` |
| `PROXMOX_VE_ENDPOINT` | `https://PVE1_IP:8006/` |
| `PROXMOX_VE_API_TOKEN` | `terraform-acc@pve!gate=<secret>` from step 7 |
| `PROXMOX_VE_INSECURE` | `true`, unless you've given the nodes trusted certificates (`pvenode acme`) |
| `PROXMOX_VE_ACC_NODE_NAME` | `pve1`, the name in `pvecm nodes` |
| `PROXMOX_VE_ACC_NODE_2_NAME` | `pve2` |
| `PROXMOX_VE_ACC_CLOUDINIT_BRIDGE` | `vmbr1` |
| `PROXMOX_VE_ACC_CLOUDINIT_VLAN_ID` | `0` (the bridge isn't VLAN-aware) |

Leave out the `PROXMOX_VE_SSH_*` variables; the resource uses only the API.

## 9. Check the lab before running the gate

From the machine that runs the tests, with the variables from `testacc.env` loaded into your shell:

```sh
curl -fsSk -H "Authorization: PVEAPIToken=$PROXMOX_VE_API_TOKEN" \
  "${PROXMOX_VE_ENDPOINT}api2/json/nodes" | jq -r '.data[] | "\(.node) \(.status)"'            # pve1 online, pve2 online
curl -fsSk -H "Authorization: PVEAPIToken=$PROXMOX_VE_API_TOKEN" \
  "${PROXMOX_VE_ENDPOINT}api2/json/storage/local" | jq -r .data.content                          # includes import,images,iso
```

Then run the gate as FORK.md describes:

```sh
scripts/glueops-dev.sh ./testacc TestAccResourceCloudInitBootstrap
```

All 3 subtests must report `--- PASS`.

## Troubleshooting

- **The bootstrap times out waiting for the guest agent:** the VM didn't get an address or internet access. On the
  node, `journalctl -u dnsmasq` should show a DHCPACK. `iptables -t nat -L POSTROUTING` should show the MASQUERADE
  rule. `cat /proc/sys/net/ipv4/ip_forward` should be `1`.
- **The image download fails:** the node itself needs outbound HTTPS to `cloud-images.ubuntu.com`.
- **Only 2 subtests ran:** `PROXMOX_VE_ACC_NODE_2_NAME` is missing or wrong.
- **Migration fails:** `vmbr1` or the `local` content types differ between the nodes, or the cluster ports are blocked
  between them.
- **Leftovers after an interrupted run:** delete VMs named `test-*` and files named `test-*` or `cloudinit-*` from
  `local` on both nodes.
