# Release gate lab: two Proxmox VE nodes on Hetzner

The release gate's acceptance tests ([FORK.md](../FORK.md#release-gate)) run against a small, dedicated Proxmox VE
cluster: two Hetzner dedicated servers. `scripts/glueops-acc-lab.sh` builds it from scratch and writes `testacc.env`.
This doc says what you need, how to run it, and what to do when a stage fails.

**The lab is disposable.** Rebuilding it wipes both servers. Nothing on them is kept, and the tests create and delete
VMs, so never point the script or the tests at servers that run anything real.

## What you need

- **Two Hetzner dedicated servers**, ordered in Robot, in the same location, each with 2 NVMe disks.
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

## Build the lab

From the repo root:

```sh
scripts/glueops-acc-lab.sh all        # about 18-20 minutes; or run the stages one at a time, in this order
```

| Stage | What it does | Time |
| ----- | ------------ | ---- |
| `rescue` | registers the lab key, boots both servers into Hetzner's rescue system (hardware reset) | 1-2 min |
| `install` | `installimage`: Debian 13 on software RAID 1 (UEFI layout), reboots into it | 6 min |
| `pve` | Proxmox VE 9 from the no-subscription repo; Proxmox kernel; key-only SSH | 10 min |
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
tests will run from another machine, rerun the stage with `LAB_ALLOW_IPS="<ip> ..." scripts/glueops-acc-lab.sh
firewall`.

## Run the gate

```sh
scripts/glueops-acc-lab.sh check
scripts/glueops-dev.sh ./testacc TestAccResourceCloudInitBootstrap
scripts/glueops-acc-lab.sh leftovers     # exits 0 if the tests left nothing behind
```

All 3 subtests must report `--- PASS`. They take about 2 minutes and clean up after themselves.

## Getting at the nodes

```sh
scripts/glueops-acc-lab.sh ips                 # the node IPs
scripts/glueops-acc-lab.sh ssh pve1            # root shell on pve1
scripts/glueops-acc-lab.sh ssh pve2 qm list    # one command on pve2
```

You never need to open `testacc.env` or Robot to find a node.

## When a stage fails

| Symptom | Cause and fix |
| ------- | ------------- |
| `install` stops with "isn't in rescue" on a re-run | A previous run already rebooted that node into Debian. Run `rescue install` to start the install over. |
| `install`: installimage prints only `Cancelled.` | The real reason is in `/root/debug.txt` on the server (the script prints its error lines). `ESP missing`: the layout needs an EFI partition, which the script includes. |
| A node doesn't come back after a reboot | These servers sometimes hang on a soft reboot. The script waits 8 minutes, then sends up to 2 hardware resets through Robot. If it still fails, rerun `rescue` and look at the server in Robot. |
| `rescue` times out | Rescue mode may not have armed. Rerun the stage, which re-arms it. If it keeps failing, check the server's status in Robot. |
| `cluster`: `Permission denied` writing `authorized_keys` | `/etc/pve` is read-only for a moment after `pvecm create`. The script waits for quorum; rerun the stage. |
| `check`: `pve1 has no vmbr1` | A pending `/etc/network/interfaces.new` left by the Proxmox install hides the bridge, and would drop it at the next boot. The `network` stage removes it; rerun `network check`. |
| `check`: 401 or connection refused | The token or the firewall: rerun `token`, or `firewall` with `LAB_ALLOW_IPS` set to the test machine's IP. |
| Test: the bootstrap times out waiting for the guest agent | The VM got no address or internet access. On the node, `journalctl -u dnsmasq` should show a DHCPACK, `iptables -t nat -L POSTROUTING` should show MASQUERADE, and `/proc/sys/net/ipv4/ip_forward` should be `1`. |
| Test: only 2 subtests ran | `PROXMOX_VE_ACC_NODE_2_NAME` is missing from `testacc.env`; rerun `token`. |
| `leftovers` lists VMs or files (after an interrupted test run) | Delete them: `scripts/glueops-acc-lab.sh ssh pve1 qm destroy <vmid> --purge` for the VMs, and `ssh <node> pvesm free <volume>` for the files on each node. Then rerun `leftovers`. |
| `firewall`: can't look up the public IP | `ifconfig.me` is unreachable; set `LAB_MY_IP`. |

## How it's put together (for changing the script)

- **Network:** Hetzner only routes the server's own MAC address, so guests can't sit on the public network. Each node has
  an identical private bridge `vmbr1` with NAT and DHCP. Because both have the same name, subnet and gateway, a VM
  that migrates keeps working.
- **Cluster traffic** runs over the public IPs. That's fine within one Hetzner location, and the firewall allows the two
  nodes to reach each other.
- **The API token** has the Administrator role on `/`: simple, and fine for a disposable lab. A least-privilege role
  hasn't been tested.
- **Credentials:** the Robot password and the token secret only ever live in `~/.config/hetzner-robot.env` and
  `testacc.env`. Both are mode 600 and outside git (`*.env` is gitignored).
