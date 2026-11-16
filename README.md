# vagrantfiles

Vagrant environments I use in different projects or while learning different
software products: Oracle databases and clustering, configuration management,
and Windows. Everything is driven by a `Vagrantfile` in its own directory, and
the larger labs wrap the common commands in a `./lab` helper.

## Contents

| Directory | What it builds | Provider / box | Provisioning |
|-----------|----------------|----------------|--------------|
| [rac-oracle](rac-oracle/) | Oracle 19c Real Application Clusters lab: two nodes, Grid Infrastructure, three-address SCAN and ASM on five iSCSI LUNs exported by a host LIO target | libvirt/QEMU, `generic/oracle8` | Bundled shell steps `01`–`07` via `./lab` |
| [dr-oracle](dr-oracle/) | Oracle 19c disaster-recovery lab: two data centres, each with its own iSCSI SAN array emulated by `targetcli`, block-replicated between the sites with DRBD (SRDF/SnapMirror/ActiveDR style) | libvirt/QEMU, `generic/oracle8` | Bundled shell steps `01`–`10` via `./lab` |
| [rhel-ha-oracle](rhel-ha-oracle/) | Two-node Red Hat HA cluster (Pacemaker + Corosync + `pcs`) with SBD fencing and an Oracle 19c single instance on shared iSCSI storage | libvirt/QEMU, `generic/oracle8` | Bundled shell steps `01`–`07` via `./lab` |
| [vcs-oracle](vcs-oracle/) | Two-node Veritas InfoScale (VCS) cluster with VXFEN I/O fencing and an Oracle 19c single instance on PR-capable iSCSI LUNs | libvirt/QEMU, `generic/oracle8` | Bundled shell steps `01`–`08` via `./lab` |
| [cephfs](cephfs/) | Ceph File System cluster lab: three nodes with three monitors, two managers, six OSDs and an active/standby MDS pair serving a CephFS volume to a fourth VM over the kernel client | libvirt/QEMU, `generic/oracle9` | Bundled shell steps `01`–`04` via `./lab` |
| [oracle-11g](oracle-11g/) | Single-node Oracle Database 11g R2 installation | VirtualBox, `boxcutter/oel66` | Puppet (`manifests/base.pp`, `oracle` module) |
| [chef-workstation](chef-workstation/) | ChefDK workstation with `vim` | VirtualBox, `hashicorp/precise64` | `setupChefDk.sh` |
| [puppet-template](puppet-template/) | Puppet walkthrough that pulls a module from Puppet Forge and installs Elasticsearch | VirtualBox, `ubuntu/trusty64` | `apt-update.sh`, `install-puppet-modules.sh`, Puppet |
| [windows_2012_r2_standard](windows_2012_r2_standard/) | Windows Server 2012 R2 desktop VM | VirtualBox GUI, `opentable/win-2012r2-standard-amd64-nocm` | none (WinRM) |

Each directory has its own README; the labs built on libvirt document their
network layout, provisioning steps, verification, failover demos and
troubleshooting in detail.

## Cluster labs (libvirt)

`rhel-ha-oracle` and `vcs-oracle` follow the same pattern: two Oracle Linux 8.9
VMs on libvirt, shared storage exported over iSCSI from an **LIO target on the
host** (so SCSI-3 persistent reservations work and the data survives
`vagrant destroy`), and cluster software that needs both nodes up applied as a
separate step.

### Requirements

* KVM (`/dev/kvm`), libvirt, QEMU, `targetcli-fb` and `iscsi-initiator-utils`
  on the host. `./host/lio-target.sh` needs **sudo**.
* Vagrant 2.4.3+ with `vagrant-libvirt`
  (`vagrant plugin install vagrant-libvirt`; needs `libvirt-dev`, `libxml2-dev`,
  `zlib1g-dev`, `libxslt1-dev` and a compiler to build the plugin).
* ~10 GB RAM free (2 VMs x 4 GB) and ~30 GB disk.
* Oracle 19c media (`LINUX.X64_193000_db_home.zip`) placed in the lab's
  `software/` directory. Oracle and Veritas downloads are not redistributable,
  so they are **not** in this repository. Missing media only skips the matching
  provisioning step, so `vagrant up` still produces working nodes.

`cephfs` has no host-side storage to set up and needs no sudo on the host, but
its guests do need internet access: the Ceph RPMs come from `download.ceph.com`
and cephadm pulls the Ceph container image from `quay.io`. See
[cephfs/README.md](cephfs/README.md) for the 14 GB / 40 GB sizing.

### rhel-ha-oracle

Pacemaker/Corosync cluster with SBD (storage-based death) fencing on a dedicated
iSCSI LUN and an `ora` resource group that moves the LVM volume group,
filesystem, floating service IP (`10.20.3.100`), listener and database.

```bash
cd rhel-ha-oracle
./lab up        # iSCSI target + two provisioned nodes (ha1, ha2)
./lab cluster   # Pacemaker cluster, SBD fencing, ora resource group
./lab status    # storage, quorum, fencing and resource state
./lab crash     # power off a node (default ha1) to watch fencing and failover
```

The instance runs on one node at a time; `sudo su - oracle` on that node gives
you `sqlplus` with `ORACLE_SID=orcl` already set. From the host,
`sqlplus system/Oracle123@//10.20.3.100:1521/orcl` works through the client
bridge.

### vcs-oracle

Veritas InfoScale 7.4.2 cluster with LLT/GAB heartbeats and an `ora_sg` service
group. With Foundation/Enterprise media (which adds VxVM) I/O fencing (VXFEN)
is enabled with three coordinator disks; with Availability-only media the
cluster runs unfenced.

```bash
cd vcs-oracle
cp /path/to/InfoScale_Availability_7.4.2_Linux.tar.gz software/
cp /path/to/vxlic.key software/            # optional license
./lab up        # iSCSI target + two provisioned nodes (vcs1, vcs2)
./lab cluster   # fencing + VCS cluster + ora_sg
./lab status    # storage, fencing, cluster and database state
./lab switch    # move ora_sg to a node (default vcs2)
```

Connect from the host or either node with
`sqlplus system/Oracle123@//10.10.3.100:1521/orcl`.

In both labs `./lab` also supports `ssh [node]`, `provision NODE STEP`,
`storage [setup|status|teardown]`, `destroy` (keeps the LUN images) and `clean`
(deletes `.storage/` and `.runtime/` as well).

### cephfs

Ceph's own distributed file system: three Oracle Linux 9 nodes run three
monitors, two managers and six OSDs (two 8 GB disks each, size 3 pools with the
host as the CRUSH failure domain), and one active plus one standby MDS serve a
`cephfs` volume. A fourth VM mounts it on `/mnt/cephfs` with `ceph-fuse` (the
9.3 kernel client cannot read Squid's default `aes256k` cephx keys), so the
difference between the cluster, the file system and its consumers is visible as
three separate machines.

```bash
cd cephfs
./lab up        # four provisioned VMs (~10 min)
./lab cluster   # cephadm bootstrap, mons, mgrs, OSDs, MDS pair, CephFS
./lab client    # join the client VM and mount /mnt/cephfs
./lab status    # health, daemons, PGs, OSD tree, mount state
./lab demo      # snapshots, quotas, subvolumes, self-healing
./lab crash ceph2   # lose a node; writes keep working
./lab recover ceph2 # and heal
```

Capacity is 6 x 8 GB raw, 16 GB usable at size 3 — small on purpose, so
rebalancing and recovery finish while you watch. `./lab bench` measures RADOS
and CephFS throughput, and the dashboard is on `https://10.60.1.11:8443`.

## Disaster recovery lab (libvirt)

### dr-oracle

Oracle Database DR the storage-replication way: two data centres, each with its
own SAN array, and the arrays copy every block between the sites. The arrays are
Linux VMs (`targetcli` front end, DRBD back end) so both halves of a SAN
replication product are visible and controllable, and the DR site recovers by
opening the replicated filesystems and letting Oracle perform instance crash
recovery.

```bash
cd dr-oracle
ln -s ../../rhel-ha-oracle/software/LINUX.X64_193000_db_home.zip software/
./lab up          # db1, db2, san1, san2 (~17 GB RAM)
./lab storage     # DRBD link, iSCSI exports, LUNs on both hosts
./lab database    # create the database at site A, validate the DR site
./lab status      # DRBD roles, mounts, VIP, instance state
./lab switchover  # planned DR: clean stop, demote, promote, open at site B
./lab failover    # unplanned: power off site A, promote site B, crash recovery
./lab recover     # resync the returned site and switch back
```

`./lab sql "select * from dr_test;"` queries the active site through the floating
address `10.50.40.100:1521`, and `./lab mode async` / `./lab wan 20ms` show what
asynchronous replication and a slow WAN do to the data-loss window.

## RAC lab (libvirt)

### rac-oracle

A two-node RAC cluster: Grid Infrastructure 19c (Clusterware + ASM), node VIPs,
a three-address SCAN served by DNS, and a policy-managed database on `+DATA`.
The five shared LUNs (three for OCR/voting, one DATA, one FRA) come from an LIO
iSCSI target on the host, and each one is presented as `/dev/asm-diskN` through
udev rules that match the LUN's own name.

```bash
cd rac-oracle
./lab up        # host LUNs + two prepared nodes (rac1, rac2)
./lab scan      # publish rac-scan.lab (3 A records) on the lab network (sudo)
./lab status    # storage, ASM devices, DNS, cluster state
./lab grid      # needs LINUX.X64_193000_grid_home.zip in software/
./lab install   # grid + asm + db-software + database
./lab sql "select instance_name, host_name from v\$instance;"
```

RAC needs **two** Oracle homes (Grid Infrastructure and Database), so the grid
zip is the one hard prerequisite. Without it the lab still produces two fully
prepared nodes and `./lab grid` says exactly what is missing.

## Other environments

### oracle-11g

Installs Oracle Database 11g R2 on `boxcutter/oel66` with Puppet. The
`Vagrantfile` names the VM `oracle`, forwards port 1521 (listener) and 1158
(Enterprise Manager), enables X11 forwarding, and reserves 2 GB of RAM.
`setupPuppet.sh` installs Puppet from the Puppet Labs EL6 repository, then
`manifests/base.pp` applies the bundled `oracle` module with `ORACLE_SID=orcl`,
`ORACLE_ROOT=/oracle` and a password you should change in the manifest.

Before `vagrant up`, put the install media in `modules/oracle/files`:

* `linux.x64_11gR2_database_1of2.zip`
* `linux.x64_11gR2_database_2of2.zip`

The module also runs the 11.2.0.1 CVU fixup scripts from
`CVU_11.2.0.1.0_vagrant/`, creates `/etc/init.d/oracle`, and enables the
instance in `/etc/oratab`.

### chef-workstation

Ubuntu `precise64` VM whose `setupChefDk.sh` installs
`chefdk_0.6.2-1_amd64.deb` from the synced folder, plus `vim`. Drop that
package into this directory before provisioning.

### puppet-template

Ubuntu `trusty64` template derived from
[Jeroen Reijn's vagrants](https://github.com/jreijn/vagrants). It runs
`apt-get update`, installs the `elasticsearch-elasticsearch` module (0.4.0) from
Puppet Forge in `install-puppet-modules.sh`, and then applies
`manifests/default.pp`, which installs Elasticsearch 1.3.2 with the
`elasticsearch-head` plugin on `0.0.0.0`.

### windows_2012_r2_standard

VirtualBox VM with a GUI (`opentable/win-2012r2-standard-amd64-nocm`), 2 vCPUs,
8 GB RAM and 256 MB of video memory, reached over WinRM. VirtualBox Guest
Additions are updated only when the host is Windows.

## Notes

* `.vagrant/` directories and the installer media directories
  (`rhel-ha-oracle/software/`, `vcs-oracle/software/`) are git-ignored.
* The Oracle cluster labs use `generic/oracle8` (Oracle Linux 8.9) by default;
  the Oracle 19c base release cannot be built on Oracle Linux 9 (glibc 2.34).
  The `cephfs` lab uses `generic/oracle9` because the current Ceph packages
  (`cephadm`, `ceph-common`) are only built for EL9.
* Licensed under the [MIT License](LICENSE.md).
