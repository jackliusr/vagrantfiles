# vagrantfiles

Vagrant environments I use in different projects or while learning different
software products: Oracle databases and clustering, configuration management,
and Windows. Everything is driven by a `Vagrantfile` in its own directory, and
the larger labs wrap the common commands in a `./lab` helper.

## Contents

| Directory | What it builds | Provider / box | Provisioning |
|-----------|----------------|----------------|--------------|
| [rhel-ha-oracle](rhel-ha-oracle/) | Two-node Red Hat HA cluster (Pacemaker + Corosync + `pcs`) with SBD fencing and an Oracle 19c single instance on shared iSCSI storage | libvirt/QEMU, `generic/oracle8` | Bundled shell steps `01`–`07` via `./lab` |
| [vcs-oracle](vcs-oracle/) | Two-node Veritas InfoScale (VCS) cluster with VXFEN I/O fencing and an Oracle 19c single instance on PR-capable iSCSI LUNs | libvirt/QEMU, `generic/oracle8` | Bundled shell steps `01`–`08` via `./lab` |
| [oracle-11g](oracle-11g/) | Single-node Oracle Database 11g R2 installation | VirtualBox, `boxcutter/oel66` | Puppet (`manifests/base.pp`, `oracle` module) |
| [chef-workstation](chef-workstation/) | ChefDK workstation with `vim` | VirtualBox, `hashicorp/precise64` | `setupChefDk.sh` |
| [puppet-template](puppet-template/) | Puppet walkthrough that pulls a module from Puppet Forge and installs Elasticsearch | VirtualBox, `ubuntu/trusty64` | `apt-update.sh`, `install-puppet-modules.sh`, Puppet |
| [windows_2012_r2_standard](windows_2012_r2_standard/) | Windows Server 2012 R2 desktop VM | VirtualBox GUI, `opentable/win-2012r2-standard-amd64-nocm` | none (WinRM) |

Each directory has its own README; the two cluster labs document their network
layout, provisioning steps, verification, failover demos and troubleshooting in
detail.

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
* The cluster labs use `generic/oracle8` (Oracle Linux 8.9) by default; the
  Oracle 19c base release cannot be built on Oracle Linux 9 (glibc 2.34).
* Licensed under the [MIT License](LICENSE.md).
