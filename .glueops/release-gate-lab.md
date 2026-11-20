# Release gate lab: a two-node Proxmox VE cluster

The release gate's acceptance tests ([FORK.md](../FORK.md#release-gate)) run against a small, dedicated Proxmox VE 9
cluster of two nodes. `scripts/glueops-acc-lab.sh` builds it from scratch and writes `testacc.env`. It has two
backends:

- **Local (preferred, the default):** both nodes are nested KVM VMs in one Docker container on this machine. Nothing to
  order or pay for, no credentials, and nothing reachable from outside the container.
- **Hetzner (fallback, `LAB_BACKEND=hetzner`):** two Hetzner dedicated servers. Use it when [the local lab can't
  answer the question](#when-to-use-the-hetzner-lab). There are no servers by default: a human orders them.

**The lab is disposable.** The tests create and delete VMs, and rebuilding wipes the nodes. Never point the script or
the tests at anything real.

## Local lab

### What you need

- **A machine with nested KVM:** `/dev/kvm`, and `kvm_amd` or `kvm_intel` loaded with `nested=1`. The GlueOps
  codespaces have it. The `up` stage checks this first and says what's missing.
- **Docker**, about 22 GB of free RAM while the lab is up (2 nodes of 10 GB, `LAB_MEM_MB`) and 40 GB of disk where
  Docker keeps its volumes.
- `bash`, `ssh`, `python3` and `git`. Run the script directly, **not** through `scripts/glueops-dev.sh`.

The script creates its own SSH key (`~/.ssh/glueops-acc-lab-local`); your own keys aren't used.

### Build, use and stop it

```sh
scripts/glueops-acc-lab.sh all        # about 15 minutes: up pve network cluster storage token check
scripts/glueops-acc-lab.sh check      # before each gate run
scripts/glueops-acc-lab.sh test       # ./testacc TestAccResourceCloudInitBootstrap (or other ./testacc arguments)
scripts/glueops-acc-lab.sh leftovers  # exits 0 if the tests left nothing behind
scripts/glueops-acc-lab.sh status     # container, VMs, SSH and cluster; exits 4 if the lab isn't running
scripts/glueops-acc-lab.sh down       # power both nodes off cleanly; the disks are kept
scripts/glueops-acc-lab.sh up         # start it again (about 1-2 minutes)
scripts/glueops-acc-lab.sh destroy    # remove the container, its disks and its testacc.env
```

`ssh pve1|pve2 [command]` and `ips` work as for Hetzner (below). The nodes' addresses exist only inside the
`glueops-acc-lab` container; SSH, the API check and `test` reach them through it, so the API is never exposed.

| Stage | What it does | Time |
| ----- | ------------ | ---- |
| `up` | checks KVM, nesting, RAM and disk; builds the lab image once; starts the container and two Debian 13 VMs (8 vCPU each, `LAB_VCPUS`), or starts an existing lab | 1-2 min |
| `pve` | Proxmox VE 9 from the no-subscription repo; Proxmox kernel; key-only SSH | 10-11 min |
| `network`, `cluster`, `storage`, `token`, `check` | as for Hetzner (below) | 1 min |

**Stop it with `down`, not `docker stop` or `docker rm`.** The VM disks favour speed over crash safety
(`cache=unsafe`). `down` powers the nodes off cleanly (it gives them up to 5 minutes); a plain `docker stop` does the same within its
3- to 5-minute timeout. If the
machine crashes or the container is killed, a node's disk can be corrupt: if `up` or `check` then fails, run `destroy`
and `all` (about 15 minutes). Nothing restarts the lab on its own after a reboot; run `up`.

The full command output goes to `~/.cache/glueops-acc-lab/local.log`. Only one run of the script uses the local lab at
a time (except `status`).

### When a local stage fails

| Symptom | Cause and fix |
| ------- | ------------- |
| `up`: "/dev/kvm can't be opened" or "nested virtualization is off" | This machine can't run the lab. Use another codespace, or the Hetzner lab. |
| `up`: "need … MB of free RAM" or "need 40 GB free" | Stop other containers or free disk; `LAB_MEM_MB` lowers the node size (the tests' VMs need 2 GB each). |
| `up`: "… has no KVM inside it" | The nodes didn't get the CPU's virtualization flag, so PVE couldn't run the test VMs. Check nesting on this machine. |
| `up`: "no SSH after 10 minutes" | The node didn't boot: the script prints the command that shows its console. |
| Any stage: "the local lab isn't running" | Run `up` (or `all` if it was never built). |
| `pve`: dpkg errors about `grub-pc` | `up` preseeds the grub install disk; rerun `up pve`. |
| `network`: "Another instance of this program is already running" | ifupdown2 is missing `/run/network`; the stage creates it, so rerun `network`. |
| `check` fails after a crash or a killed container | A disk is probably corrupt: `destroy`, then `all`. |
| `status`: a VM is `paused` | Docker's disk is full. Free space; the VM continues. |

### When to use the Hetzner lab

The nested lab runs the same Proxmox VE, so the gate's results carry over, with these limits:

- It can't test PCI or USB passthrough, IOMMU, hugepages, real NIC names, firmware or UEFI on real hardware, or disk
  performance. A release that changes those needs the Hetzner lab.
- Timing differs: the test VMs run nested twice, so the suite takes about 1.6 times as long (649 s vs 394 s), and
  migration copies disks inside one machine. **If a subtest fails only locally, with a timeout**, rerun it on Hetzner
  before calling it a provider bug, and don't raise the timeout to make it pass. A local failure still blocks the
  release until it passes on Hetzner and the gate comment says why.
- This machine can't run it (`up`'s preflight fails).

## Hetzner lab (fallback)

**Every command in this section needs `LAB_BACKEND=hetzner`.** Run `export LAB_BACKEND=hetzner` first, or prefix each
command: without it, the script uses the local lab, so a bare `all` would build a local lab instead of rebuilding the
servers. The script's own hints add the prefix.

### What you need

- **Two Hetzner dedicated servers**, ordered in Robot, in the same location, each with exactly 2 disks. Prefer NVMe:
  SATA hard disks work but are slow, and a new RAID 1 on large ones resyncs for hours. BIOS or UEFI boot both work.
- **A Robot webservice user** (Robot → Settings → Web service and app settings) and the two servers' Robot numbers,
  in a file only you can read. The first server becomes `pve1`:
  ```sh
  # ~/.config/hetzner-robot.env   (chmod 600; never commit it, never print it)
  HETZNER_ROBOT_USER='...'
  HETZNER_ROBOT_PASSWORD='...'
  LAB_SERVERS='<pve1 server number> <pve2 server number>'
  ```
  The GlueOps admins who own the lab keep this file.
- **On the machine that runs it:** `bash`, `ssh`, `curl`, `python3` and `git`, plus Docker for the tests.
- **Run it directly** on your workstation or devcontainer, **not** through `scripts/glueops-dev.sh`: it needs SSH and
  the Robot API. The tests' Docker containers must reach the internet through the same public IP. If they don't, add
  their IP with `LAB_ALLOW_IPS`.

The script creates its own SSH key (`~/.ssh/glueops-acc-lab`) and registers it in Robot. Your own keys aren't used.

### Build the lab

From the repo root:

```sh
LAB_BACKEND=hetzner scripts/glueops-acc-lab.sh all        # about 15-20 minutes; or run the stages one at a time, in this order
```

| Stage | What it does | Time |
| ----- | ------------ | ---- |
| `rescue` | registers the lab key, boots both servers into Hetzner's rescue system (hardware reset) | 1-2 min |
| `install` | `installimage`: Debian 13 on software RAID 1 (UEFI or BIOS layout, as rescue booted), reboots into it | 5-6 min |
| `pve` | Proxmox VE 9 from the no-subscription repo; Proxmox kernel; key-only SSH | 8-10 min |
| `network` | `vmbr1` on each node: 10.10.10.1/24, NAT to the internet, DHCP with dnsmasq | seconds |
| `cluster` | `pve1` creates the cluster `glueops-acc`, `pve2` joins over SSH | 1 min |
| `storage` | `local` gets the `import`, `images`, `iso` (and `snippets`) content types | seconds |
| `firewall` | pve-firewall: only this machine's public IP and the two nodes can reach them | seconds |
| `token` | API user `terraform-acc@pve` with a token; writes `testacc.env` (mode 600, secret never printed) | seconds |
| `check` | both nodes online, `local` content types, `vmbr1` active on both, the token works | seconds |

Most of the time is reboots, which run one node after the other.

**Output.** Each stage prints one progress line per step; the full command output goes to
`~/.cache/glueops-acc-lab/build.log` (`LAB_LOG`). On a failure, the script prints the end of that log. It never prints
the credentials or the token secret, and it masks IP addresses as `<ip>` (except in the `ips` stage), so its output
is safe to quote.

**Re-running.** Every stage can be re-run. To start over completely, run `all` again; `rescue` is the stage that wipes
the servers. Nothing local needs deleting first: the lab key (`~/.ssh/glueops-acc-lab`) is reused and `testacc.env` is
overwritten.

The `firewall` stage looks up this machine's public IP at `https://ifconfig.me`. Set `LAB_MY_IP` to skip that. If the
tests will run from another machine, rerun the stage with `LAB_ALLOW_IPS="<ip> ..." LAB_BACKEND=hetzner scripts/glueops-acc-lab.sh
firewall`.

### Run the gate

```sh
LAB_BACKEND=hetzner scripts/glueops-acc-lab.sh check
scripts/glueops-dev.sh ./testacc TestAccResourceCloudInitBootstrap
LAB_BACKEND=hetzner scripts/glueops-acc-lab.sh leftovers     # exits 0 if the tests left nothing behind
```

Every subtest must report `--- PASS`. They take about 7 minutes and clean up after themselves.

### Getting at the nodes

```sh
LAB_BACKEND=hetzner scripts/glueops-acc-lab.sh ips                 # the node IPs
LAB_BACKEND=hetzner scripts/glueops-acc-lab.sh ssh pve1            # root shell on pve1
LAB_BACKEND=hetzner scripts/glueops-acc-lab.sh ssh pve2 qm list    # one command on pve2
```

You never need to open `testacc.env` or Robot to find a node.

### When a stage fails

| Symptom | Cause and fix |
| ------- | ------------- |
| `install` stops with "isn't in rescue" on a re-run | A previous run already rebooted that node into Debian. Run `rescue install` to start the install over. |
| `install`: installimage prints only `Cancelled.` | The real reason is in `/root/debug.txt` on the server (the script prints its error lines). `ESP missing`: installimage wants an EFI partition on a UEFI server; the script adds one when rescue booted UEFI, so rerun `install`. |
| A node doesn't come back after a reboot | These servers sometimes hang on a soft reboot. The script waits 8 minutes, then sends up to 2 hardware resets through Robot. If it still fails, rerun `rescue` and look at the server in Robot. If it never boots its installed system while rescue always works, its firmware isn't booting the disks: a human asks Hetzner to check it, or swaps the server. |
| Any stage: "Robot has no server …" | The servers in `LAB_SERVERS` were cancelled (or the numbers are wrong). Ordering servers costs money, so a human does it: they order two as described in [What you need](#what-you-need-1) and put their numbers in `LAB_SERVERS`. Then run `all`. |
| Any stage: "LAB_SERVERS names server … twice" | Both entries are the same server, so every stage would run twice on one machine. Put the second server's number in `LAB_SERVERS`. |
| `install`: "… has N disks" | The RAID 1 layout needs exactly 2 non-removable disks. Use a server with 2 disks. |
| Any stage: "Robot request … failed" | Wrong or rotated Robot credentials in `~/.config/hetzner-robot.env`, or no network. |
| `rescue` times out | Rescue mode may not have armed. Rerun the stage, which re-arms it. If it keeps failing, check the server's status in Robot. |
| `cluster`: `Permission denied` writing `authorized_keys` | `/etc/pve` is read-only for a moment after `pvecm create`. The script waits for quorum; rerun the stage. |
| `check`: `pve1 vmbr1: missing` | A pending `/etc/network/interfaces.new` left by the Proxmox install hides the bridge, and would drop it at the next boot. The `network` stage removes it; rerun `network check`. |
| `check` fails | It prints which fix to try. If the nodes answer SSH, it's the token or the firewall: rerun `firewall token check` (add the test machine with `LAB_ALLOW_IPS` if it's another machine). If they don't, the lab is down or gone: rebuild with `all`. |
| Test: the bootstrap times out waiting for the guest agent | The VM got no address or internet access. On the node, `journalctl -u dnsmasq` should show a DHCPACK, `iptables -t nat -L POSTROUTING` should show MASQUERADE, and `/proc/sys/net/ipv4/ip_forward` should be `1`. |
| Test: only 2 subtests ran | `PROXMOX_VE_ACC_NODE_2_NAME` is missing from `testacc.env`; rerun `token`. |
| `leftovers` lists VMs or files (after an interrupted test run) | Delete them: `LAB_BACKEND=hetzner scripts/glueops-acc-lab.sh ssh pve1 qm destroy <vmid> --purge` for the VMs, and `ssh <node> pvesm free <volume>` for the files on each node. Then rerun `leftovers`. |
| `firewall`: can't look up the public IP | `ifconfig.me` is unreachable; set `LAB_MY_IP`. |

### How it's put together (for changing the script)

- **Network:** Hetzner only routes the server's own MAC address, so guests can't sit on the public network. Each node has
  an identical private bridge `vmbr1` with NAT and DHCP. Because both have the same name, subnet and gateway, a VM
  that migrates keeps working.
- **Cluster traffic** runs over the public IPs. That's fine within one Hetzner location, and the firewall allows the two
  nodes to reach each other.
- **The API token** has the Administrator role on `/`: simple, and fine for a disposable lab. A least-privilege role
  hasn't been tested.
- **Credentials:** the Robot password and the token secret only ever live in `~/.config/hetzner-robot.env` and
  `testacc.env`. Both are mode 600 and outside git (`*.env` is gitignored).
