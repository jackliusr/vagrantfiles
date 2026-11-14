# vcs-oracle

A two-node **Veritas InfoScale (VCS) cluster** running an **Oracle 19c**
single-instance database on shared storage, built with Vagrant and
**libvirt/QEMU**. The shared LUNs come from an **LIO iSCSI target on the host**,
which emulates SCSI-3 persistent reservations - the part QEMU's file-backed
disks cannot do. With InfoScale Foundation/Enterprise media (which adds VxVM)
the cluster runs with **I/O fencing (VXFEN)** enabled; with Availability-only
media it runs unfenced.

```
        host (KVM/QEMU + libvirt)
  ┌──────────────────────────────────────────────────────────────┐
  │  LIO iSCSI target  iqn.2026-11.lab.vcs:storage   :3260       │
  │    LUN 0  data.img    8 GB   -> vg_ora / lv_u02 / /u02       │
  │    LUN 1  coord1.img  1 GB   -> VXFEN coordinator (VxVM)     │
  │    LUN 2  coord2.img  1 GB   -> VXFEN coordinator (VxVM)     │
  │    LUN 3  coord3.img  1 GB   -> VXFEN coordinator (VxVM)     │
  │                                                              │
  │  bridge virbrN 10.10.1.0/24  (LLT link 1)                    │
  │  bridge virbrN 10.10.2.0/24  (LLT link 2)                    │
  │  bridge virbrN 10.10.3.0/24  (client + service IP)           │
  └───────┬──────────────────────────────────────────┬───────────┘
          │                                          │
   ┌──────┴───────┐                          ┌───────┴──────┐
   │    vcs1      │  LLT / GAB heartbeats    │    vcs2      │
   │ 10.10.1.11   │ <──────────────────────> │ 10.10.1.12   │
   │ 10.10.2.11   │      VCS cluster         │ 10.10.2.12   │
   │ 10.10.3.11   │                          │ 10.10.3.12   │
   │ had + Oracle │                          │ had + Oracle │
   │ home (local) │                          │ home (local) │
   └──────────────┘                          └──────────────┘
         └────────── iSCSI LUNs (PR-capable) ─────────┘

   Service IP 10.10.3.100  ──  moved by VCS with the ora_sg group
```

`ora_sg` contains, in dependency order:

```
NIC ora_nic ──> IP ora_ip ──┐
                            ├──> Oracle ora_db ──> Netlsnr ora_lsnr
LVMVolumeGroup ora_vg ──> Mount ora_mnt ──┘
```

| Component | Version | Notes |
|-----------|---------|-------|
| Host | KVM + libvirt 9/10 + QEMU 8/9/10 | `vagrant-libvirt` 0.12.x plugin |
| Guest OS | Oracle Linux 8.9 (`generic/oracle8`) | RHEL-compatible, public yum repos |
| Cluster | InfoScale 7.4.2 | Availability (VCS) or Foundation/Enterprise (adds VxVM) |
| Database | Oracle 19c, single instance, `orcl` | `$ORACLE_HOME` local, data on `/u02` |
| Storage | LIO iSCSI on the host, 3 LUNs | `emulate_pr=1`, `fileio` backstore |
| Fencing | VXFEN, SCSI-3 PR, 3 coordinators | needs VxVM; `UseFence = SCSI3` in `main.cf` |

## Why iSCSI and not a shared virtio disk?

QEMU passes **SCSI-3 persistent reservations** through only for `scsi-block`/
`scsi-generic` devices backed by a real PR-capable LUN (`-object pr-manager-helper`).
A file-backed `scsi-hd` - which is what libvirt's `<shareable/>` disk creates -
implements only the legacy SCSI-2 `RESERVE`/`RELEASE` and returns
`ILLEGAL REQUEST` for `PERSISTENT RESERVE IN/OUT` (check with
`qemu-system-x86_64 -device scsi-hd,help`, which has no `pr-manager` property).
Two VMs on such a disk would happily write to the same image.

So the lab exports the LUNs over iSCSI from an **LIO target on the host**
(`fileio` backstore with `emulate_pr=1`). LIO emulates the register/reserve/
preempt commands that VXFEN uses, so the same three LUNs can serve as VxVM
coordinator devices. Side benefits: the data survives `vagrant destroy`, and
the layout looks like a real SAN.

Veritas 7.4.2 disk-based fencing is strict about the coordinators: they must be
**DMP devices in the `vxfencoorddg` VxVM disk group** with `coordinator=on`, and
Veritas recommends **three** coordination points. That means fencing needs
`VRTSvxvm`, i.e. **Foundation or Enterprise** media. `07-vcs-config.sh` detects
this: with Availability media it logs a clear message and builds the cluster
with `UseFence = NONE`.

## Requirements

* KVM (`/dev/kvm`), libvirt, QEMU, `targetcli-fb`, `iscsi-initiator-utils`
  (`iscsiadm`) on the host. `./host/lio-target.sh` needs **sudo** (targetcli).
* Vagrant 2.4.3+ with the `vagrant-libvirt` plugin:
  `vagrant plugin install vagrant-libvirt`
  (needs `libvirt-dev`, `libxml2-dev`, `zlib1g-dev`, `libxslt1-dev`, `build-essential`).
* ~10 GB RAM free (2 VMs x 4 GB) and ~30 GB disk (sparse LUN images + two
  128 GB thin root disks).
* Installer media - Veritas and Oracle downloads are not redistributable, so
  they are **not** in this repository. Use Foundation or Enterprise media if you
  want I/O fencing (VxVM is a prerequisite for the coordinator disk group).

## Quick start

```bash
cd vcs-oracle
cp /path/to/InfoScale_Availability_7.4.2_Linux.tar.gz software/
cp /path/to/LINUX.X64_193000_db_home.zip software/
cp /path/to/vxlic.key software/              # optional but recommended

./lab up          # creates the iSCSI target, then provisions both nodes (~25 min)
./lab cluster     # fencing + VCS cluster + ora_sg
./lab status      # storage, fencing, cluster and database state
```

`./lab up` is `sudo ./host/lio-target.sh setup` followed by `vagrant up`. The
cluster itself is a separate step because VCS needs **both** nodes running
(LLT/GAB peering, coordinator disks, `main.cf`). `vagrant up` alone is safe: the
nodes end up provisioned with LLT and GAB running.

### Connecting to the database

```bash
./lab ssh vcs1
sudo su - oracle
sqlplus system/Oracle123@//10.10.3.100:1521/orcl
```

From the host, `10.10.3.100:1521` is reachable through the `vcs-client` bridge,
so any Oracle client can use the same connect string.

## What the provisioning steps do

Each script is idempotent and keeps state in `/etc/vcs-lab/`; every script can
also be re-run on its own (see [Re-running a step](#re-running-a-step)).

| Step | Script | Details |
|------|--------|---------|
| (host) | `host/lio-target.sh` | creates sparse LUN images in `.storage/`, LIO `fileio` backstores with `emulate_pr=1`, exports them under one iSCSI target, enables `target.service` |
| `base` | `scripts/01-base.sh` | hostname + `/etc/hosts`, SELinux permissive, firewalld off, `kernel.hung_task_panic=0`, `rp_filter=2`, packages, **static addresses on the three cluster networks via nmcli (matched by MAC)**, root SSH key |
| `storage` | `scripts/02-shared-storage.sh` | logs the node in to the iSCSI target (`node.startup=automatic`), maps LUN 0/1/2 to data and coordinator disks, creates `vg_ora`/`lv_u02` + ext4 on `vcs1`, verifies the VG is visible but inactive on `vcs2` |
| `oracle_prereq` | `scripts/03-oracle-prereq.sh` | `oracle-database-preinstall-19c`, `/u01` layout, `oraInst.loc`, `oracle` profile, `~oracle/.oraenv_vcs`, THP disabled |
| `oracle_install` | `scripts/04-oracle-install.sh` | silent `runInstaller`, `root.sh`, node-local `init<sid>.ora`, `listener.ora`/`tnsnames.ora` bound to the service IP, `oratab` |
| `oracle_database` | `scripts/05-oracle-database.sh` | `dbca -silent` on `vcs1` with datafiles/redo/FRA on `/u02`, SPFILE moved to shared storage, archivelog enabled, instance shut down |
| `vcs_install` | `scripts/06-vcs-install.sh` | InfoScale prerequisite RPMs, `./installer -responsefile ... -noipc`, `OracleTypes.cf` import, `/etc/llttab`, `/etc/llthosts`, `/etc/gabtab`, starts LLT and GAB |
| `vcs_config` | `scripts/07-vcs-config.sh` | releases `/u02`, builds the **`vxfencoorddg` coordinator disk group** and starts VXFEN when VxVM and three PR-capable coordinators are present, renders `main.cf`, `hacf -verify`, copies it to the peer, starts VCS on both nodes, waits for `ora_sg` |
| `status` | `scripts/08-status.sh` | read-only report |

`04`, `05` and `06` skip themselves with an explanation when their media is
missing, so a `vagrant up` without downloads still gives you two prepared
cluster nodes.

## Installer media

Put the downloads in [`software/`](software/) (ignored by git). The directory is
copied into the guests by the `lab-media` file provisioner, which is only added
when the directory contains something.

| File | Purpose |
|------|---------|
| `InfoScale_Availability_7.4.2/`, `*.tar.gz` or `*.iso` | VCS/InfoScale installer. 7.4.2 is the release Veritas documents for Oracle Linux 8. |
| `vxlic.key` | VCS license key file passed to the installer via `$CFG{keys}{licensefile}`. The installer normally asks for a key; without one it may only proceed in keyless/evaluation mode. |
| `LINUX.X64_193000_db_home.zip` (any `*db_home*.zip`) | Oracle 19c database home. |

The InfoScale response file is generated by `06-vcs-install.sh`:

```perl
our %CFG;
$CFG{accepteula} = 1;
$CFG{prod} = "AVAILABILITY742";
$CFG{systems} = [ qw(vcs1) ];       # local node only
$CFG{opt}{install} = 1;             # packages only; the cluster is built by 07
```

Use `VCS_LAB_INFOSCALE_PRODUCT` if your media is a different 7.4.x build, for
example `VCS_LAB_INFOSCALE_PRODUCT=AVAILABILITY743 ./lab up`.

## Verifying the lab

```bash
./lab status
```

Healthy output looks like this (abridged):

```
== iSCSI sessions
    tcp: [1] 10.10.3.1:3260,1 iqn.2026-11.lab.vcs:storage (non-flash)
    data disk:      /dev/sda
    coordinators:  /dev/sdb /dev/sdc

== I/O fencing
    Fencing Mode: SCSI3
    Coordinator disks         : /dev/sdb /dev/sdc /dev/sdd
    vxfen: active

== Service group ora_sg
    ora_sg ONLINE
    ora_nic ONLINE
    ora_ip ONLINE
    ora_vg ONLINE
    ora_mnt ONLINE
    ora_db ONLINE
    ora_lsnr ONLINE

== Service IP 10.10.3.100
    reachable

== Oracle instance
    OPEN / ACTIVE
    listener is running
```

Fencing can be verified independently of VCS:

```bash
./lab ssh vcs1
sudo vxfenadm -d                                     # Fencing Mode: SCSI3
sudo sg_persist --in --report-capabilities --device /dev/sdb | grep 'Allow Commands'
sudo sg_persist --in --read-keys --device /dev/sdb   # VXFEN keys once the cluster runs
```

## Failover and fencing

```bash
./lab switch vcs2     # planned failover: hagrp -switch ora_sg -to vcs2
./lab kill vcs1       # hard power off: the surviving node fences the peer
./lab start vcs1
```

With fencing enabled, the surviving node uses the coordinator disks to decide
membership and revokes the failed node's reservations on the data LUN before
bringing `ora_sg` online; the fenced node is reset. Events land in
`/var/VRTSvcs/log/engine_A.log`, `/var/log/messages` and the `vxfen` logs on
both nodes. Without VxVM the same test only demonstrates a plain failover.

## How the cluster is configured

* `/etc/llttab` - `set-node <hostname>`, `set-cluster <id>` (default `13221`)
  and one `link` line per LLT NIC using the `eth-<mac>` form.
* `/etc/llthosts` - identical `0 vcs1` / `1 vcs2` table on both nodes.
* `/etc/gabtab` - `/sbin/gabconfig -c -n2`.
* VXFEN - coordinator LUNs are grouped into `vxfencoorddg` (`vxdg init ...`,
  `vxdg -g vxfencoorddg set coordinator=on`, then deported), `/etc/vxfendg`
  names the group, `/etc/vxfenmode` comes from
  `/etc/vxfen.d/vxfenmode_scsi3_dmp`, and `vxfen` is started after LLT/GAB and
  before VCS.
* [`files/main.cf.tmpl`](files/main.cf.tmpl) - the service group, rendered by
  `07-vcs-config.sh`, validated with `hacf -verify` before VCS starts, then
  copied to the peer:

| Resource | Attributes | Why |
|----------|-----------|-----|
| `LVMVolumeGroup ora_vg` | `VolumeGroup = vg_ora`, `StartVolumes = 1`, `EnableLVMTagging = 1`, `ScanDevices = 1` | iSCSI LUNs may log in after boot, so the agent rescans before activating |
| `Mount ora_mnt` | `BlockDevice = /dev/mapper/vg_ora-lv_u02`, `FsckOpt = "-y"` | LVM2 must use the mapper path; `FsckOpt` is mandatory for non-NFS mounts |
| `IP ora_ip` | `Address = 10.10.3.100`, `Device = eth3` | floating service address |
| `NIC ora_nic` | `Device = eth3`, `NetworkHosts = { peer }` | link monitoring for the client network |
| `Oracle ora_db` | `Pfile = $ORACLE_HOME/dbs/initorcl.ora`, `EnvFile = /home/oracle/.oraenv_vcs` | the init file is a one-line `SPFILE=` pointer to the shared SPFILE |
| `Netlsnr ora_lsnr` | `Listener = LISTENER`, `TnsAdmin = $ORACLE_HOME/network/admin` | listener follows the database |

## Network and storage layout

| Use | Subnet | vcs1 | vcs2 | libvirt network |
|-----|--------|------|------|-----------------|
| Management | 192.168.121.0/24 | DHCP | DHCP | `vagrant-libvirt` (Vagrant uses it for SSH) |
| LLT link 1 | 10.10.1.0/24 | .11 | .12 | `vcs-llt1`, isolated bridge |
| LLT link 2 | 10.10.2.0/24 | .11 | .12 | `vcs-llt2`, isolated bridge |
| Client / service | 10.10.3.0/24 | .11 | .12 | `vcs-client`, isolated bridge; host is .1 |
| Service IP | 10.10.3.100 | - | - | moved by VCS |

The three cluster networks are isolated bridges without DHCP: `01-base.sh`
configures the addresses itself with NetworkManager, matching the interface by
the MAC address that the Vagrantfile assigns. That keeps the naming independent
of `systemd` predictable names and of the hypervisor.

The iSCSI portal is the host address of the client bridge (`10.10.3.1`). The
LUNs are sparse files in `.storage/` and are identified by their
`/dev/disk/by-path/ip-10.10.3.1:3260-iscsi-...-lun-N` links.

## Limitations of this lab

* **Demo-mode iSCSI.** The target has no CHAP and accepts any initiator
  (`generate_node_acls=1`), because the portal is only on a host-only bridge.
  Do not expose port 3260 beyond the lab.
* **Single host.** Both nodes and the "SAN" run on one KVM host; a host failure
  takes everything down. Fencing protects against node-level split brain only.
* **Fencing needs VxVM.** Availability-only media cannot create the
  `vxfencoorddg` disk group, so the cluster then runs with `UseFence = NONE`.
  PR emulation by LIO is verified, but the Veritas side is not exercised.
* **Plain LVM, no VxVM/ASM.** Works with an Availability-only license;
  `EnableLVMTagging` prevents concurrent activation, but there is no cluster
  filesystem.
* **Oracle homes are local**, datafiles/redo/SPFILE/archive logs are shared -
  classic VCS failover, not RAC.
* **InfoScale 7.4.2 officially supports RHEL/OL 8 Update 1**; later updates
  (8.2+) require a matching product patch from Veritas/Arctera. `oracle8` 8.9
  works in practice but is outside the tested matrix.
* **Licence.** Unlicensed VCS stops enforcing after the evaluation period; put
  a valid key in `software/vxlic.key` for a stable lab.

## Customisation

| Variable | Default | Meaning |
|----------|---------|---------|
| `VCS_LAB_BOX` | `generic/oracle8` | Vagrant box (needs a libvirt provider) |
| `VCS_LAB_CLUSTER` | `vcsoracle` | VCS cluster name |
| `VCS_LAB_CLUSTER_ID` | `13221` | LLT cluster number (`set-cluster`) |
| `VCS_LAB_SID` | `orcl` | Oracle SID and service name |
| `VCS_LAB_SERVICE_IP` | `10.10.3.100` | floating service address |
| `VCS_LAB_SHARED_MB` | `8192` | size of the data LUN |
| `VCS_LAB_COORD_MB` | `1024` | size of each coordinator LUN |
| `VCS_LAB_COORD_COUNT` | `3` | number of coordinator LUNs exported by the host |
| `VCS_LAB_STORAGE_IP` | `10.10.3.1` | iSCSI portal (client bridge address) |
| `VCS_LAB_ISCSI_IQN` | `iqn.2026-11.lab.vcs:storage` | target IQN |
| `VCS_LAB_INFOSCALE_PRODUCT` | derived from media | installer product tag |
| `LAB_ORACLE_PASSWORD` | `Oracle123` | SYS/SYSTEM password used by `dbca` |

Node names, addresses and MAC addresses are defined once in the `NODES` array
at the top of the [Vagrantfile](Vagrantfile).

## Re-running a step

```bash
./lab provision vcs1 vcs_install         # after adding the InfoScale media
./lab provision vcs1 oracle_install      # after adding the Oracle media
./lab provision vcs1 oracle_database
./lab provision vcs2 vcs_install
```

`vcs_install` must succeed on **both** nodes before `./lab cluster`. Markers in
`/etc/vcs-lab/done/` make completed steps skip quickly; delete a marker to
force a re-run. Media added later is uploaded by `vagrant provision` only if the
`lab-media` provisioner exists in the Vagrantfile, which it does as soon as
`software/` contains a file - so re-run `vagrant up --provision` after adding
it.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| provisioning fails once and succeeds on retry | `vagrant up` provisions both nodes in parallel; simply re-run `vagrant provision` |
| `vagrant up` fails with "permission denied" on libvirt | add your user to the `libvirt` and `kvm` groups and re-login |
| `Could not create domain ... Storage pool not found` | `vagrant-libvirt` needs the default pool: `virsh pool-start default` |
| iSCSI discovery fails in `02` | the host target must be up: `./lab storage setup` (needs sudo); check `ss -ltnp | grep 3260` |
| `sg_persist` says "Illegal request" | the LUN has no PR emulation; check `targetcli /backstores/fileio/data get attribute emulate_pr` |
| PR commands fail with "logical unit communication failure" | `/etc/rtslib-fb-target/pr` is missing; `host/lio-target.sh setup` creates it |
| `./lab cluster` says fencing is disabled | `vxdg`/`vxfenconfig` missing (Availability-only media), fewer than three coordinators, or no PR support; the cluster still runs, check `haclus -display UseFence` |
| `vxdg init vxfencoorddg` fails | the LUNs must be unused and visible to VxVM: `vxdisk scandisks`, `vxdisk list`, and make sure the data LUN is not passed to `vxdg` |
| `gabconfig -a` shows no membership | firewalld off, both nodes on the same `set-cluster` id, `/etc/llthosts` identical, both LLT links up (`lltstat -n`) |
| `ora_sg` stays `PARTIAL` | `hastatus -summary`, `/var/VRTSvcs/log/engine_A.log`, resource logs, and `$ORACLE_BASE/diag/rdbms/orcl/orcl/trace/alert_orcl.log` |
| `ora_mnt` fails | `/u02` must not be mounted when VCS starts; `07` unmounts it and deactivates `vg_ora` first |
| Oracle installer runs out of space | `/u01` needs ~16 GB; check `df -h /u01` |

## Teardown

```bash
./lab destroy     # removes the VMs, keeps .storage/ LUN images
./lab clean       # removes the VMs, the iSCSI target and .storage/ + .runtime/
```

`vagrant destroy` powers the domains off abruptly, so guest page cache that was
not flushed is lost (the LVM metadata and anything you `sync`ed survives). Shut
the cluster down cleanly (`./lab offline`, `hagrp -offline`, `umount /u02`) if
you care about the last writes.

## Repository layout

```
vcs-oracle/
├── Vagrantfile          two libvirt nodes, three bridges, file provisioners
├── lab                  helper: up, cluster, status, switch, kill, storage, clean
├── host/lio-target.sh   LIO iSCSI target with PR emulation (needs sudo)
├── files/main.cf.tmpl   VCS service group template
├── scripts/             provisioning steps 01..08 plus lib.sh
└── software/            installer media (git-ignored, see its README)
```
