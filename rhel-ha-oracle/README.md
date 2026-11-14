# rhel-ha-oracle

A two-node **Red Hat High Availability** cluster (Pacemaker + Corosync + `pcs`)
running an **Oracle 19c** single-instance database on shared storage, built with
Vagrant and **libvirt/QEMU**. Fencing is **SBD** (storage-based death) on a
dedicated iSCSI LUN with the `softdog` watchdog, which is the RHEL-recommended
layout for a two-node cluster without a quorum device.

```
        host (KVM/QEMU + libvirt + LIO iSCSI target)
  ┌──────────────────────────────────────────────────────────────┐
  │  LIO iSCSI target  iqn.2026-11.lab.rhelha:storage   :3260    │
  │    LUN 0  data.img  8 GB  -> vg_ora / lv_u02 / /u02          │
  │    LUN 1  sbd.img   1 GB  -> SBD fencing device              │
  │                                                              │
  │  bridge 10.20.1.0/24  (corosync cluster network)             │
  │  bridge 10.20.3.0/24  (client network + service IP)          │
  └───────┬──────────────────────────────────────────┬───────────┘
          │                                          │
   ┌──────┴───────┐                          ┌───────┴──────┐
   │     ha1      │  corosync / pacemaker    │     ha2      │
   │ 10.20.1.11   │ <──────────────────────> │ 10.20.1.12   │
   │ 10.20.3.11   │      SBD fencing         │ 10.20.3.12   │
   │ Oracle home  │                          │ Oracle home  │
   └──────────────┘                          └──────────────┘
         └──────── iSCSI LUNs (shared) ─────────┘

   Service IP 10.20.3.100  ──  IPaddr2, moved with the ora group
```

The `ora` resource group, in start order:

| Resource | Agent | Purpose |
|----------|-------|---------|
| `ora_vg` | `ocf:heartbeat:LVM-activate` (`vg_access_mode=system_id`) | activates `vg_ora` on one node only |
| `ora_fs` | `ocf:heartbeat:Filesystem` | mounts `/dev/vg_ora/lv_u02` on `/u02` |
| `ora_ip` | `ocf:heartbeat:IPaddr2` | floating service address |
| `ora_lsnr` | `ocf:heartbeat:oralsnr` | starts/stops the listener |
| `ora_db` | `ocf:heartbeat:oracle` | starts/stops the instance |

The listener comes before the database: it has to be up when the instance
starts so that PMON registers the service with `local_listener`
(`10.20.3.100:1521`) straight away. With the opposite order the listener starts
too late and `sqlplus` fails with `ORA-12514` until someone runs
`alter system register`.

`ora_db`/`ora_lsnr` are only added once the Oracle home exists on both nodes, so
the cluster is useful (VIP + filesystem failover) before the media is installed.

| Component | Version | Notes |
|-----------|---------|-------|
| Guest OS | Oracle Linux 8.9 (`generic/oracle8`) | RHEL 8 compatible, `ol8_addons` enabled for the HA packages |
| Cluster | Pacemaker 2.1, Corosync 3.1, pcs 0.10 | knet transport on the dedicated cluster network |
| Fencing | SBD + `softdog` | device on iSCSI LUN 1, `auto_tie_breaker` for two nodes |
| Database | Oracle 19c, single instance, `orcl` | `$ORACLE_HOME` local, data/SPFILE/archivelogs on `/u02` |
| Storage | LVM on LUN 0 | `vg_ora`/`lv_u02`, ext4, `LVM-activate` with system IDs |

## Requirements

* KVM (`/dev/kvm`), libvirt, QEMU, `targetcli-fb` and `iscsi-initiator-utils` on
  the host. `./host/lio-target.sh` needs **sudo** (targetcli).
* Vagrant 2.4.3+ with `vagrant-libvirt`
  (`vagrant plugin install vagrant-libvirt`, needs `libvirt-dev` and a compiler).
* ~10 GB RAM free (2 VMs x 4 GB) and ~30 GB disk.
* Oracle 19c media for the database part - not redistributable, so it is **not**
  in this repository (see [Installer media](#installer-media)).

## Quick start

```bash
cd rhel-ha-oracle
cp /path/to/LINUX.X64_193000_db_home.zip software/     # optional

./lab up          # iSCSI target + two provisioned nodes (~15 min)
./lab cluster     # Pacemaker cluster, SBD fencing, ora resource group
./lab status      # storage, quorum, fencing and resource state
```

`./lab up` runs `sudo ./host/lio-target.sh setup` and then `vagrant up`. The
cluster is a separate step because it needs both nodes running. `vagrant up`
alone is safe: the nodes end up with pcs/pcsd, LLT-free corosync packages, the
Oracle prerequisites and the shared LUNs attached.

### Connecting to the database

The instance runs on **one** node at a time: the one that owns the `ora` group.
`./lab status` (or `sudo crm_resource --resource ora_db --locate`) tells you
which one. `sudo su - oracle` sets `ORACLE_SID=orcl`, `ORACLE_HOME` and `PATH`
from `~oracle/.bash_profile`, so no `oraenv` is needed.

```bash
./lab ssh ha1
sudo su - oracle
```

| Where | Command | Notes |
|-------|---------|-------|
| active node, OS auth | `sqlplus / as sysdba` | no password, no listener |
| active node, local | `sqlplus system/Oracle123` | bequeath protocol, uses `ORACLE_SID` |
| any node or host | `sqlplus system/Oracle123@orcl` | `orcl` alias in `tnsnames.ora` → service IP |
| any node or host | `sqlplus system/Oracle123@//10.20.3.100:1521/orcl` | full connect string |
| any node or host | `sqlplus sys/Oracle123@//10.20.3.100:1521/orcl as sysdba` | remote SYSDBA, needs `orapw$ORACLE_SID` on that node |

From the host, `10.20.3.100:1521` is reachable through the `ha-client` bridge
(`1521/tcp` is open in `firewalld`), so any client — `sqlcl`, SQL Developer,
DBeaver — can connect with the same connect string.

The listener is bound to the service IP only and PMON registers the service with
`local_listener` at every instance start, so all of the above survive
`./lab switch` / `./lab crash`. On the passive node `sqlplus / as sysdba` still
fails with `ORA-01034` — that node simply has no instance running, and the
password file (`$ORACLE_HOME/dbs/orapw$ORACLE_SID`, node-local) is copied to the
peer by the `oracle_database` step so remote SYSDBA works after a failover.

Accounts created by the lab: `SYS`/`SYSTEM` with `Oracle123`
(`LAB_ORACLE_PASSWORD` if you changed it) and `OCFMON`/`Ocfmon123`, the account
the `ocf:heartbeat:oracle` agent uses for monitoring — don't use it to log in
by hand.

## What the provisioning steps do

| Step | Script | Details |
|------|--------|---------|
| (host) | `host/lio-target.sh` | creates sparse LUN images in `.storage/`, LIO `fileio` backstores, exports data + SBD over iSCSI |
| `base` | `scripts/01-base.sh` | hostname + `/etc/hosts`, SELinux permissive, `ol9_addons`/`ol8_addons` repo, pcs/pacemaker/corosync/resource-agents/sbd, firewalld `high-availability` service plus `1521/tcp` for the listener, static IPs via nmcli (MAC-matched), `softdog`, LVM system ID, hacluster password, pcsd, root SSH |
| `storage` | `scripts/02-shared-storage.sh` | iSCSI login (`node.startup=automatic`), LUN 0/1 discovery, LVM devices-file entry, `vg_ora` with a system ID + ext4 on `ha1`, SBD device recorded, `sbd.service` ordered after iSCSI |
| `oracle_prereq` | `scripts/03-oracle-prereq.sh` | `oracle-database-preinstall-19c`, `/u01` layout, `oraInst.loc`, `oracle` profile, `~oracle/.oraenv_ha`, THP disabled |
| `oracle_install` | `scripts/04-oracle-install.sh` | silent `runInstaller`, `root.sh`, node-local `init<sid>.ora`, `listener.ora`/`tnsnames.ora` bound to the service IP, `oratab` |
| `oracle_database` | `scripts/05-oracle-database.sh` | `dbca -silent` on `ha1` with datafiles/redo/FRA on `/u02`, shared SPFILE (with `local_listener` → service IP) and archivelog enabled, password file copied to the peer, instance shut down |
| `cluster` | `scripts/06-cluster.sh` | `pcs host auth` + `pcs cluster setup` (knet, `addr=` on the cluster network), SBD device setup (cluster stopped) + `pcs stonith sbd enable`, resource group creation |
| `status` | `scripts/07-status.sh` | read-only report |

Oracle Linux 8 is the default on purpose: the Oracle 19c **19.3 base release**
cannot be built on Oracle Linux 9 (its `genclntsh`/`ins_rdbms.mk` fail against
glibc 2.34), so `04-oracle-install.sh` only works around the OS check and the
missing `libpthread_nonshared.a` when you point `HA_LAB_BOX` at OL9. On OL9 use
a 19c release update (19.19 or later) or 23ai media instead.

The Oracle steps skip themselves with an explanation when the media is missing.
`06-cluster.sh` is idempotent: run `./lab cluster` again after installing Oracle
and it adds `ora_db` and `ora_lsnr` to the existing group.

## Installer media

Put the Oracle 19c database home zip in [`software/`](software/) (ignored by
git). The directory is copied into the guests by a file provisioner that is only
added when it contains files, so either add the media before the first
`./lab up` or run `vagrant up --provision` afterwards.

## Verifying the lab

```bash
./lab status
```

Healthy output (abridged):

```
== Cluster status
    Cluster name: ha_lab
      * 2 nodes configured
      * 6 resource instances configured
    Node List:
      * Online: [ ha1 ha2 ]

== SBD fencing
    SBD STATUS
    <node name>: <installed> | <enabled> | <running>
    ha1: YES | YES | YES
    ha2: YES | YES | YES
  * sbd  (stonith:fence_sbd):  Started ha2

== Resource group ora
    * Resource Group: ora:
      * ora_vg  (ocf:heartbeat:LVM-activate):  Started ha1
      * ora_fs  (ocf:heartbeat:Filesystem):    Started ha1
      * ora_ip  (ocf:heartbeat:IPaddr2):       Started ha1
      * ora_lsnr  (ocf:heartbeat:oralsnr):     Started ha1
      * ora_db  (ocf:heartbeat:oracle):        Started ha1

== Service IP 10.20.3.100
    reachable

== Oracle instance
    instance orcl: OPEN / ACTIVE
    listener is running
```

On the other node the same section reports where the instance actually runs,
instead of dumping an `ORA-01034` from a sqlplus call against a stopped local
instance:

```
== Oracle instance
    instance orcl is not running on ha2 (it is active on ha1)
```

## Failover and fencing

```bash
./lab switch ha2      # planned failover: pcs resource move ora ha2 (+ clear)
./lab crash ha1       # hard power off the active node
./lab start ha1       # power it back on; it rejoins the cluster
```

`./lab switch` is idempotent: it first removes constraints and fail counts left
behind by an earlier run, and if the group already runs on the requested node it
says so and exits 0 (Pacemaker refuses to "move" a resource onto the node it is
already running on).

* **Planned failover** stops the group on the current node and starts it on the
  other one, moving the VIP and re-mounting `/u02` from the shared LUN.
* **Node loss**: hard powering off the active node makes the survivor take over
  as soon as SBD declares the node dead.
* **Real fencing** happens when a node is alive but partitioned (for example
  `sudo iptables -I INPUT -p udp --dport 5405 -j DROP` and the same on OUTPUT
  on one node): it loses quorum and SBD resets it through `/dev/watchdog`
  (softdog). Verify with `pcs stonith history` on the survivor, which shows
  `reboot of ha2 successful: delegate=ha1`.

## How the cluster is configured

* `pcs cluster setup ha_lab ha1 addr=10.20.1.11 ha2 addr=10.20.1.12` - corosync
  (knet) uses the dedicated cluster network, not the client network.
* `pcs stonith sbd enable device=/dev/sdb watchdog=/dev/watchdog` initialises
  the SBD header on the shared LUN and writes `/etc/sysconfig/sbd`; enabling it
  also turns on `auto_tie_breaker` (two nodes, no quorum device). The cluster
  has to be stopped for this, the script handles it.
* `pcs stonith create sbd fence_sbd devices=/dev/sdb pcmk_delay_max=30` adds
  the actual fence device. Without it Pacemaker logs "No fence device" and
  cannot fence a peer - pcs 0.11 does not create it automatically when the
  cluster is stopped.
* `pcs property set no-quorum-policy=ignore` keeps the survivor serving; fencing
  still protects the data.
* `pcs resource defaults resource-stickiness=100` keeps the group on the node it
  runs on; without it the scheduler is free to move everything back to the
  previous node the moment the temporary constraint of `./lab switch` is
  removed.
* `LVM-activate` runs in `system_id` mode: the VG carries an LVM system ID that
  the agent rewrites to the node that activates it, so `vg_ora` can only be
  online on one node. Each node has `local { system_id = <hostname> }` in
  `/etc/lvm/lvmlocal.conf` and `system_id_source = "lvmlocal"` in `lvm.conf`.
* Firewalld keeps the `high-availability` service open (2224/tcp, 3121/tcp,
  5405/udp, 21064/tcp) plus `1521/tcp` for the listener.

## Network and storage layout

| Use | Subnet | ha1 | ha2 | libvirt network |
|-----|--------|-----|-----|-----------------|
| Management | 192.168.121.0/24 | DHCP | DHCP | `vagrant-libvirt` (used by Vagrant) |
| Cluster (corosync) | 10.20.1.0/24 | .11 | .12 | `ha-cluster`, isolated bridge |
| Client / service | 10.20.3.0/24 | .11 | .12 | `ha-client`, isolated bridge; host is .1 |
| Service IP | 10.20.3.100 | - | - | moved by Pacemaker |

The iSCSI portal is the host address of the client bridge (`10.20.3.1`); the
LUNs are identified through
`/dev/disk/by-path/ip-10.20.3.1:3260-iscsi-...-lun-N`.

## Limitations of this lab

* **Demo-mode iSCSI.** No CHAP, any initiator may log in; the portal is only on
  host-only bridges. Do not expose port 3260.
* **Single host.** Both nodes and the "SAN" run on one KVM host; a host failure
  takes everything down. SBD protects against node-level split brain only.
* **Two nodes without a quorum device** rely on `auto_tie_breaker`, which is
  fine for a lab but a production cluster would add a QDevice.
* **Plain LVM with system IDs**, not `lvmlockd`. For concurrently active VGs
  (rare for a single-instance Oracle) use `vgcreate --shared` + `lvmlockd`/`dlm`
  and `vg_access_mode=lvmlockd`.
* Oracle homes are local; datafiles/redo/SPFILE/archivelogs are on the shared
  LUN - classic active/passive failover, not RAC.

## Customisation

| Variable | Default | Meaning |
|----------|---------|---------|
| `HA_LAB_BOX` | `generic/oracle8` | Vagrant box (needs a libvirt provider) |
| `HA_LAB_CLUSTER` | `ha_lab` | Pacemaker cluster name |
| `HA_LAB_SID` | `orcl` | Oracle SID and service name |
| `HA_LAB_SERVICE_IP` | `10.20.3.100` | floating service address |
| `HA_LAB_DATA_MB` | `8192` | size of the data LUN |
| `HA_LAB_SBD_MB` | `1024` | size of the SBD LUN |
| `HA_LAB_STORAGE_IP` | `10.20.3.1` | iSCSI portal (client bridge address) |
| `HA_LAB_ISCSI_IQN` | `iqn.2026-11.lab.rhelha:storage` | target IQN |
| `HA_LAB_HACLUSTER_PASS` | `Hacluster123` | password for the `hacluster` user (pcs) |
| `LAB_ORACLE_PASSWORD` | `Oracle123` | SYS/SYSTEM password used by `dbca` |

Node names, addresses and MAC addresses are defined in the `NODES` array at the
top of the [Vagrantfile](Vagrantfile).

## Re-running a step

```bash
./lab provision ha1 oracle_install      # after adding the Oracle media
./lab provision ha2 oracle_install
./lab provision ha1 oracle_database
./lab cluster                           # adds ora_db/ora_lsnr once Oracle exists
```

Markers in `/etc/ha-lab/done/` make completed steps skip quickly; delete a
marker to force a re-run. Scripts are edited on the host and copied into the
guests, so re-upload them after a change with
`vagrant provision --provision-with lab-scripts`.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `dnf` cannot find `pcs`, `pacemaker`, `resource-agents` | `01-base.sh` enables `ol9_addons`; check `dnf repolist` inside the guest |
| Oracle install fails in `all_no_orcl` with `undefined reference to stat`, or earlier with `cannot find /usr/lib64/libpthread_nonshared.a` | the 19.3 base release does not build on glibc 2.34 (Oracle Linux 9). Use Oracle Linux 8 (default) or a newer 19c RU / 23ai |
| `sshd -t` fails with an OpenSSL version mismatch | the cluster packages pull a newer `openssl-libs`; `openssh-server`/`openssh-clients` are upgraded in the same transaction - re-run the base step if the box was provisioned piecemeal |
| `pcs host auth` fails | `hacluster` must have the same password on both nodes and `pcsd` must be running (`systemctl status pcsd`) |
| `pcs stonith sbd enable` complains that corosync is running | expected; the script stops the cluster around the change |
| `ora_vg` fails with "Incorrect VG access mode detected" | the VG needs a system ID: `vgcreate --system-id <host> ...` and `system_id_source = "lvmlocal"` |
| `ora_vg` fails with "no local system ID is set" | `/etc/lvm/lvmlocal.conf` must contain `local { system_id = <hostname> }` |
| group does not move after `./lab switch` | check `pcs status` and `pcs constraint`; a leftover location constraint is cleared by `pcs resource clear ora`. `./lab switch` does that itself, and it also clears the target node's fail counts, otherwise Pacemaker moves the group back as soon as the constraint is gone |
| `./lab switch` says `crm_resource: Requested item already exists` | the group already runs on that node, or an earlier switch left a `cli-prefer-ora` constraint behind. Current `./lab switch` clears leftovers first and reports "the ora group already runs on <node>" instead of failing; with an older copy, run `pcs resource clear ora` |
| `./lab switch` prints "the ora group already runs on X" | not an error: `crm_resource --move` cannot target the node the group is already on, so the helper is a no-op there |
| `ORA-12514: TNS:listener does not currently know of service` | the instance started before the listener; `ora_lsnr` must precede `ora_db` in the group. Workaround: `alter system register` |
| `ORA-12543: TNS:destination host unreachable` from a client | `1521/tcp` is filtered; the base step opens it in `firewalld` (`firewall-cmd --permanent --add-port=1521/tcp`) |
| VIP unreachable from the host | the `ha-client` bridge must exist (`virsh net-list`) and the group started |

## Teardown

```bash
./lab destroy     # removes the VMs, keeps .storage/ LUN images
./lab clean       # removes the VMs, the iSCSI target and .storage/ + .runtime/
```

`vagrant halt --force` (used by `./lab crash`) is an abrupt power-off, so
unflushed guest cache is lost - which is exactly what a fencing demo should do.

## Repository layout

```
rhel-ha-oracle/
├── Vagrantfile          two libvirt nodes, two bridges, file provisioners
├── lab                  helper: up, cluster, status, switch, crash, storage, clean
├── host/lio-target.sh   LIO iSCSI target for the data and SBD LUNs (needs sudo)
├── scripts/             provisioning steps 01..07 plus lib.sh
└── software/            Oracle media (git-ignored, see its README)
```
