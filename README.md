# Slurm Cluster Setup Scripts

Three Bash scripts that turn fresh Ubuntu machines into a working **Slurm** cluster: one head node plus any number of workers, with static networking, time sync, passwordless SSH, Munge authentication and shared NFS storage.

Built for a Physics lab computational cluster. Every step prints a clear `[ OK ]` / `[WARN]` / `[FAIL]` message with a hint on how to fix it, and the scripts are safe to re-run.

> Want to understand every step by hand first? See the original manual guide: [Setting Up a Slurm Cluster: Complete Beginners Guide](https://github.com/sahan-maker). These scripts automate that guide.

---

## Table of Contents

1. [The Cluster](#the-cluster)
2. [Repository Layout](#repository-layout)
3. [Requirements](#requirements)
4. [BIOS Setup: Boot Menu and Auto Power-On](#bios-setup-boot-menu-and-auto-power-on)
5. [Cluster Setup Generator (optional)](#cluster-setup-generator-optional)
6. [Step-by-Step Installation](#step-by-step-installation)
7. [Script Reference](#script-reference)
8. [Verify the Cluster](#verify-the-cluster)
9. [Troubleshooting](#troubleshooting)
10. [Credits and Contributing](#credits-and-contributing)

---

## The Cluster

Desktop PCs stacked on a lab bench and wired to one network switch. One machine is the **head node** (monitor and keyboard attached); the others are headless **workers**.

| Front view | Rear view (cabling) |
| :---: | :---: |
| ![Cluster front view: two stacks of three desktop PCs with the head node monitor and keyboard]([images/cluster-front.jpg](https://raw.githubusercontent.com/MeshanNawod/slurm_cluster/refs/heads/main/1001135624.jpg)) | ![Cluster rear view: blue Ethernet cables from each node to the switch, with power strips](images/cluster-rear.jpg) |

```mermaid
flowchart LR
    Internet((Internet)) --- Switch[Network switch]
    Switch --- Head["head<br/>slurmctld + NFS server"]
    Switch --- N0["node0<br/>slurmd"]
    Switch --- N1["node1<br/>slurmd"]
    Switch --- N2["nodeN<br/>slurmd"]
    Head -. "NFS: /mnt/shared" .- N0
    Head -. "NFS: /mnt/shared" .- N1
    Head -. "NFS: /mnt/shared" .- N2
```

| Component | Runs on | Purpose |
| :--- | :--- | :--- |
| `slurmctld` | Head | Scheduler / controller |
| `slurmd` | Workers | Runs the jobs |
| Munge | All machines | Authentication (one shared key) |
| NFS `/mnt/shared` | Head exports, workers mount | Shared storage for job scripts and output |
| Chrony | All machines | Time sync (clock differences break Munge) |

---

## Repository Layout

```
.
├── README.md
├── Cluster Setup Generator.html   # optional: pre-fills the script questions
├── scripts/
│   ├── node-setup.sh              # run on every worker (first)
│   ├── head-setup.sh              # run on the head
│   └── slurm-setup.sh             # run on the head (last)
└── images/
    ├── cluster-front.jpg
    └── cluster-rear.jpg
```

On the USB drive, put the three scripts in a folder named **`Slurm`** (the commands below use `/mnt/usb/Slurm/`).

---

## Requirements

- Ubuntu 22.04 LTS
  - Head: Desktop (GUI) edition, so you can open the Slurm configurator in a browser
  - Workers: Server edition (no GUI)
- Head hostname must be exactly **`head`**; workers use a prefix and a number (`node0`, `node1`, ...)
- **The same username and password on every machine** (script default: `elec_cluster`)
- All machines connected to one network switch with internet access
- A free static IP for the head and for every worker (ask your network admin)
- A USB drive to carry the scripts to the machines

---

## BIOS Setup: Boot Menu and Auto Power-On

Do this **once on every machine** (head and workers) before or right after installing Ubuntu. The cluster in the photos uses Dell desktops; menu names below are for Dell BIOS and can differ slightly between models and BIOS versions. Other brands have the same options under similar names.

### 1. Boot menu (to boot from the USB installer)

1. Power on the PC and repeatedly tap **F12** (one-time boot menu on Dell).
2. Choose your USB drive from the list and press Enter.

Other common keys: **F2** or **Del** opens the full BIOS setup; **Esc**, **F9**, **F10** or **F11** open the boot menu on other brands.

### 2. Power management: AC Recovery (power back on after a power cut)

By default most PCs stay off after the power is cut and restored. With **AC Recovery** set correctly, every PC starts by itself when the plug gets power again. This matters for a cluster that runs unattended.

1. Tap **F2** at startup to enter BIOS setup.
2. Go to **Power Management** (called **Power** on some models).
3. Find **AC Recovery** (also shown as *AC Power Recovery*, *Restore on AC Power Loss* or *After Power Loss*).
4. Set it to **Power On**.

   | Option | Behaviour |
   | :--- | :--- |
   | Power Off | Stays off when power returns (default on most machines) |
   | **Power On** | **Starts automatically when power returns (use this)** |
   | Last Power State | Returns to whatever it was doing before the cut |

   *Last Power State* also works, but a machine that was switched off will then stay off. **Power On** is the safest choice for a cluster.
5. Save and exit (**F10**, or **Apply Changes** then **Exit**).

Optional settings in the same menu:

- **AC Recovery Time** or **Auto On Time** (if your BIOS has it): add a small delay, or a different delay per machine, so all PCs do not draw their start-up current at the same moment.
- **Deep Sleep Control**: leave it disabled if you want the PC to start reliably after power returns.
- **Wake on LAN**: enable it if you also want to power machines on remotely over the network.

### 3. Test it

1. Shut the PC down, then unplug the power cable (or switch off the power strip).
2. Wait about 10 seconds and plug it back in.
3. The PC should power on by itself without pressing the power button.

### After a power cut: what starts by itself

- `slurmd` (workers) and `slurmctld` (head) are enabled by the setup scripts, so they start on boot.
- The workers mount `head:/mnt/shared` with the `nofail` option. If a worker boots **before** the head is ready, the mount can fail at boot and the machine still starts normally. When the head is up, run this on the worker:

  ```bash
  sudo mount -a
  ```

  or simply reboot the worker.
- If a node shows `down` or `unk*` in `sinfo` after the cluster is back, see [Troubleshooting](#troubleshooting).

---

## Cluster Setup Generator (optional)

`Cluster Setup Generator.html` lets you type your cluster details **once** so the scripts do not ask you again. This reduces the interaction time during setup.

### How to use it

1. Open the page and enter these once:
   - cluster user
   - head IP
   - node0 IP
   - node name prefix
   - first node index and how many nodes
   - gateway and DNS (they are filled in for you and you can edit them)
   - netmask bits
2. Click **Download all 3 scripts (.zip)**, then run:

   ```bash
   unzip cluster-scripts.zip
   ```

   It is a zip because the page cannot download `.sh` files on their own. If the download is blocked, the page has a copy button for each script.
3. Put the three scripts in the **`Slurm`** folder on your USB drive and continue with the [installation steps](#step-by-step-installation).

### What each script still asks you (generated scripts)

| Script | What it still asks |
| :--- | :--- |
| `node-setup.sh` (on each worker) | Only the node name, e.g. `node3`. Node IP, gateway, DNS and interface come from your values, and the final "Continue?" question is removed. |
| `head-setup.sh` | Only the password. The "Continue?" question is removed. |
| `slurm-setup.sh` | Only the password. |

**Automatic updates:** the generated `node-setup.sh` turns off automatic updates on each worker. It disables and masks the `apt-daily` timers and `unattended-upgrades`, and writes `20auto-upgrades` with zeros.

**Unchanged:** the generated scripts are the original scripts with the typed questions replaced by your values, so all checks and messages are the same. One question is kept on purpose: the duplicate-IP warning in `node-setup.sh`, because that needs a human decision.

**Run order:** `node-setup.sh` on every worker, then `head-setup.sh`, then create `slurm.conf`, then `slurm-setup.sh`.

> The scripts in `scripts/` are the original interactive versions and ask every question. Use the generator if you want fewer prompts.

---

## Step-by-Step Installation

Run the steps **in this order**: all workers first, then the head, then `slurm.conf`, then `slurm-setup.sh`.

### Part A: Set up every worker node (one by one)

Do all of the following on **each worker**, then move to the next one.

**1. Install the operating system**

First set the BIOS options from [BIOS Setup](#bios-setup-boot-menu-and-auto-power-on) (boot menu key and **AC Recovery = Power On**). Then install Ubuntu Server 22.04 on the node. Use the same username and password as on every other machine, and give the node its own name (`node0`, `node1`, ...). Connect the node to the network switch with an Ethernet cable.

**2. Plug in the USB drive and find it with `lsblk`**

```bash
lsblk
```

Example output:

```text
NAME   MAJ:MIN RM   SIZE RO TYPE MOUNTPOINTS
loop0    7:0    0  63.9M  1 loop /snap/core20/2318
sda      8:0    0 238.5G  0 disk
├─sda1   8:1    0     1G  0 part /boot/efi
└─sda2   8:2    0 237.4G  0 part /
sdb      8:16   1   7.3G  0 disk
└─sdb1   8:17   1   7.3G  0 part
```

How to pick the USB partition:

- The USB drive is the disk with **`RM` = 1** (removable) and a size that matches your flash drive (here `sdb`, 7.3 GB).
- Use its **partition** (`TYPE` = `part`) with no mount point yet, here **`sdb1`**.
- Do **not** pick `sda`: that is the computer's own disk (it has `/` and `/boot/efi` mounted).

Your USB may show up with a different name (for example `sdc1`). Use whatever `lsblk` shows for your drive.

**3. Create a folder to mount it on**

```bash
sudo mkdir -p /mnt/usb
```

**4. Mount the USB drive**

```bash
sudo mount /dev/sdb1 /mnt/usb
```

**5. Go to the scripts folder**

```bash
cd /mnt/usb/Slurm/
```

**6. Run the worker script**

```bash
sudo ./node-setup.sh
```

If you get `Permission denied` (some USB file systems do not keep the executable flag), run it this way instead:

```bash
sudo bash node-setup.sh
```

Answer the questions (with the generator you are only asked for the node name):

| Prompt | Example |
| :--- | :--- |
| Head IP | `10.40.52.183` |
| IP of node0 (first node) | `10.40.52.175` |
| This node's name | `node8` |
| Node IP | Press Enter to accept the calculated one |
| Gateway / DNS | Press Enter to accept the guess (`x.x.x.254` / `x.x.2.1`) or type your own |
| Network interface | Press Enter to accept the detected one |

How the node IP is calculated: node0's IP plus the node number, skipping the head's IP. With head `.183` and node0 `.175`: node7 = `.182`, node8 = `.184`, node9 = `.185`.

**7. Reboot and check**

```bash
sudo reboot
# after it boots:
ip a        # the static IP should still be there
```

**8. Repeat for every worker node** (steps 1 to 7).

---

### Part B: Set up the head node

Once **all** workers are done, go to the head node.

**1.** Install Ubuntu 22.04 Desktop (GUI) on the head. Same username and password as the workers, hostname `head`.

**2.** Plug in the USB drive and mount it the same way:

```bash
lsblk
sudo mkdir -p /mnt/usb
sudo mount /dev/sdb1 /mnt/usb
cd /mnt/usb/Slurm/
```

**3.** Run the head script as your **normal user** (not root, not `sudo`):

```bash
bash ./head-setup.sh
```

Enter your password when asked. (Without the generator it also asks: cluster user, head IP, node name prefix, first and last node index, and node0's IP.)

For every worker it sets up passwordless SSH, Chrony, `/etc/hosts`, the Slurm packages, one shared Munge key (checked and tested in both directions), and NFS (`/mnt/shared` exported from the head and mounted on each worker). A summary table at the end shows which nodes are OK or FAILED. Fix any failed node and run the script again.

---

### Part C: Create `slurm.conf`

**1.** On the head, open the Slurm configurator in a web browser:

```bash
xdg-open /usr/share/doc/slurmctld/slurm-wlm-configurator.html
```

(or open `/usr/share/doc/slurmctld/slurm-wlm-configurator.html` from Firefox).

**2.** On a worker, run `lscpu` to get the hardware values.

**3.** Fill in only these fields:

| Field | Value |
| :--- | :--- |
| ClusterName | Your cluster name |
| SlurmctldHost | `head` |
| NodeName | e.g. `node[0-7]` (must match your real node names) |
| CPUs, Sockets, CoresPerSocket, ThreadsPerCore | From `lscpu` |
| ProctrackType | `LinuxProc` |

**4.** Click **Submit** and copy the text that appears.

**5.** Paste it into the config file on the head:

```bash
sudo nano /etc/slurm/slurm.conf
```

Save with `Ctrl+O`, `Enter`, then exit with `Ctrl+X`.

---

### Part D: Start Slurm

**1.** Go back to the scripts folder on the head (if you are not already there):

```bash
cd /mnt/usb/Slurm/
```

**2.** Run the final script as your **normal user**:

```bash
bash ./slurm-setup.sh
```

Enter your password when asked. It checks every node (SSH, `slurmd`, Munge key, clock), copies `slurm.conf` to each worker (checksum verified), creates the Slurm directories, starts `slurmd` on the workers and `slurmctld` on the head, then waits for the nodes to register and explains any node that is not `idle`.

**3.** Check the cluster:

```bash
sinfo
```

All nodes should show **idle**. That is it, the cluster is ready.

---

## Script Reference

| Script | Run on | Command | Run as | What it does |
| :--- | :--- | :--- | :--- | :--- |
| `node-setup.sh` | Each worker | `sudo ./node-setup.sh` | root (re-runs itself with sudo) | Static IP via netplan (with backup and automatic restore on failure), disables cloud-init network config, network tests, hostname, `/etc/hosts`, OpenSSH, `slurmd` + `slurm-client` |
| `head-setup.sh` | Head | `bash ./head-setup.sh` | normal user | Reachability check, passwordless SSH, Chrony, `/etc/hosts`, `slurm-wlm`, Munge key sync, NFS server and client mounts |
| `slurm-setup.sh` | Head | `bash ./slurm-setup.sh` | normal user | Pre-flight check per node, `slurm.conf` sync, directories, starts `slurmd` and `slurmctld`, node state report |

Notes:

- The scripts assume a **/24 network**.
- A node that fails an early check is skipped; the others continue, and a summary is printed at the end.
- The password you type is kept only in memory during the run and wiped on exit.
- Backups are kept: `/etc/hosts.bak` and `/etc/netplan/*.bak.<timestamp>`.

---

## Verify the Cluster

```bash
sinfo                 # every node should show "idle"
srun -N8 hostname     # use your worker count; prints one hostname per node
```

Quick shared-storage check:

```bash
touch /mnt/shared/test && ls -l /mnt/shared
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
| :--- | :--- | :--- |
| `sudo ./node-setup.sh`: Permission denied | USB file system does not keep the executable flag | Run `sudo bash node-setup.sh` |
| `node-setup.sh`: no link on the interface | Cable unplugged or switch off | Check the cable and switch power |
| `node-setup.sh`: IP "already answers ping" | Another machine uses that IP | Pick a free IP |
| `netplan apply` fails | Missing Open vSwitch package | The script installs `openvswitch-switch` and retries (needs internet) |
| `head-setup.sh`: SSH port closed or no reply | Node off, wrong IP, or `node-setup.sh` not run | Run `node-setup.sh` on that node, check power and cable |
| `ssh-copy-id` fails: "IDENTIFICATION HAS CHANGED" | Node was reinstalled | `ssh-keygen -R <node-ip>`, then re-run |
| `ssh-copy-id` fails: wrong password | Different password or username on the node | Use the same user and password everywhere |
| "munge rejected head's credential" | Different `munge.key` or clock skew | Re-run `head-setup.sh` (copies head's key); check `chrony` and `date` |
| NFS mount fails | Export or firewall problem | On head: `sudo exportfs -v`, `sudo ufw status`; on node: `showmount -e head` |
| Node shows `inval` | `CPUs` / `RealMemory` in `slurm.conf` exceed the hardware | Run `slurmd -C` on the node, fix `slurm.conf`, then `sudo scontrol update nodename=<node> state=resume` |
| Node shows `down` / `unk*` | `slurmd` cannot reach `slurmctld` | `ping head` from the node, check `ufw status`, `sudo journalctl -u slurmd -n 20` |
| Job stuck in `PD` | No free resources or node drained | `scontrol show job <id>` |
| `slurmctld` stops right after start | Error in `slurm.conf`, wrong `SlurmctldHost`, Munge problem | `sudo journalctl -u slurmctld -n 20` |

Useful logs:

```bash
sudo journalctl -u slurmctld -f
sudo journalctl -u slurmd -f
sudo tail -f /var/log/slurm/slurmctld.log
```

---

## Credits and Contributing

- Original guide and cluster build: **Sahan Prathibha Wijethunga** ([sahanprathibhawije@gmail.com](mailto:sahanprathibhawije@gmail.com))
- Fork and customise the defaults (user, subnet, packages) for your own infrastructure. Issues and pull requests are welcome.
