# Oracle RAC lab: two nodes, Grid Infrastructure, ASM on iSCSI

A two-node Oracle Real Application Clusters 19c cluster on libvirt, built the way
the rest of this repository builds clusters: Oracle Linux 8 guests, shared LUNs
exported by an LIO iSCSI target on the host, and a `./lab` helper that sequences
the installation.

```
        ┌──────────────────────── private interconnect 10.40.1.0/24 ───────────────┐
        │                                                                          │
  ┌─────┴──────────────┐                                          ┌───────────────┴────┐
  │  rac1              │                                          │  rac2              │
  │  public  10.40.2.11│                                          │  public  10.40.2.12│
  │  VIP     10.40.2.101                                          │  VIP     10.40.2.102
  │  storage 10.40.3.11│                                          │  storage 10.40.3.12│
  │  +ASM1              │                                          │  +ASM2              │
  └─────┬──────────────┘                                          └───────────────┬────┘
        │            SCAN 10.40.2.110/.111/.112 (3 A records in DNS)              │
        │                                                                          │
        └──────── storage network 10.40.3.0/24 ──► LIO iSCSI target 10.40.3.1 ◄────┘
                                                    ocr1/ocr2/ocr3 + data + fra
```

## What gets built

| Component | Implementation |
|-----------|----------------|
| Nodes | `rac1`, `rac2`: Oracle Linux 8.9, 8 GB and 4 vCPU each, three lab networks |
| Shared storage | 5 iSCSI LUNs from an LIO target on the host: 3 × 2 GB for OCR/voting, 12 GB DATA, 8 GB FRA |
| Disk discovery | udev rules that turn each LUN into `/dev/asm-disk1..5`, owned by `grid:asmadmin` |
| Clusterware | Grid Infrastructure 19c: CRS/CSS, ASM, two node VIPs, three-address SCAN |
| Database | RAC 19c, `ORCL`, policy-managed (one server pool, `AUTOMATIC`), data on `+DATA`, archive logs and FRA on `+FRA` |
| Name resolution | SCAN from DNS served by libvirt's own dnsmasq; node names in `/etc/hosts` |
| Time sync | CTSS (GI keeps the nodes in step), no external NTP needed |

## Requirements

* KVM, libvirt, QEMU, Vagrant 2.4+ with `vagrant-libvirt`, `targetcli-fb` on the
  host for the iSCSI target (`./host/lio-target.sh` needs **sudo**).
* ~17 GB RAM free (2 × 8 GB) and ~70 GB disk.
* **Two** Oracle homes in [`software/`](software/):
  * `LINUX.X64_193000_grid_home.zip` — Grid Infrastructure (required)
  * `LINUX.X64_193000_db_home.zip` — Database 19c with the RAC option

  Oracle downloads are not redistributable, so they are git-ignored. A symlink to
  another lab's copy is enough for the database home; see
  [`software/README.md`](software/README.md).

Without the grid zip the lab still produces two fully prepared nodes (accounts,
kernel parameters, SSH trust, three networks, five ASM devices, SCAN resolving),
and `./lab grid` reports exactly what is missing instead of half-installing.

## Quick start

```bash
cd rac-oracle
ln -s ../../rhel-ha-oracle/software/LINUX.X64_193000_db_home.zip software/   # if you have it
./lab up        # host iSCSI LUNs + two provisioned nodes (~15 min)
./lab scan      # publish rac-scan.lab (3 A records) on the lab network (sudo)
./lab status    # storage, ASM devices, DNS, cluster state
```

Then, once the grid media is in place:

```bash
./lab grid         # Grid Infrastructure + OCR disk group   (20-40 min)
./lab asm          # DATA and FRA disk groups
./lab db-software  # RAC database home on both nodes        (20-30 min)
./lab database     # create ORCL on +DATA/+FRA
# or all four at once:
./lab install
```

Connect through SCAN once the database exists:

```bash
./lab sql "select instance_name, host_name from v\$instance;"
sqlplus system/Oracle123@//rac-scan.lab/ORCL      # from either node
```

## How it fits together

### SCAN needs DNS, not `/etc/hosts`

Grid Infrastructure validates that SCAN resolves to the same addresses on every
node and refuses to install when the name comes from `/etc/hosts`. The lab's DNS
server is therefore the dnsmasq that **libvirt already runs** for the public
network (`rac-pub`, 10.40.2.1) — it is the only resolver that can bind port 53
on that bridge, so running a second one is not an option. `./lab scan` adds three
A records through `virsh net-update`, which is persistent across reboots:

```
rac-scan.lab -> 10.40.2.110, 10.40.2.111, 10.40.2.112
```

Three addresses are what makes SCAN behave like production: the resolver rotates
the order, so clients spread their connections over the cluster. The nodes use
10.40.2.1 as their first resolver and the libvirt gateway as a fallback for names
outside the lab (`01-base.sh` writes `/etc/resolv.conf` itself and sets
NetworkManager `dns=none`, so the order cannot drift).

### ASM devices

`02-storage.sh` matches each LUN by `ID_MODEL`, which the LIO target sets to the
backstore name (`ocr1`, `ocr2`, `ocr3`, `data`, `fra`). That is stable across
reboots and re-logins in a way `sd*` names are not, and unlike `DEVLINKS` it is
already populated when the rule runs:

```
/dev/asm-disk1 -> sda   grid:asmadmin 0660   ocr1
/dev/asm-disk4 -> sdd   grid:asmadmin 0660   data
```

### Accounts and SSH

Grid Infrastructure needs `grid` and `oracle` to be able to ssh to each other on
both nodes, without a password. Both nodes are provisioned **in parallel**, so
the exchange is bootstrapped with the shared key the `Vagrantfile` generates
(`.runtime/lab_root_key`, uploaded to both nodes): each node waits for the peer
to trust that key, then installs its per-user keys, appending and de-duplicating
rather than truncating, so it does not matter which node finishes first.

The `asmadmin`/`asmoper`/`asmdba` groups are created with the first free GIDs
above 54340, because `oracle-database-preinstall-19c` has already taken
54321-54330.

### Installation order, and why

`03-grid-install.sh` runs on `rac1` only and enforces the order Grid
Infrastructure requires:

1. `gridSetup.sh -silent` installs the software on both nodes over SSH
   (the response file lists `rac1:rac1-vip:HUB,rac2:rac2-vip:HUB`, the private
   network as the cluster interconnect with priority 1 and the public network
   as the second interface, and the three OCR LUNs with `NORMAL` redundancy);
2. `orainstRoot.sh` on `rac1`;
3. `root.sh` on `rac1` — this is the one that creates the cluster *and* the OCR
   disk group, so it takes 10-20 minutes;
4. `root.sh` on `rac2`, only after `rac1` finished.

`CV_ASSUME_DISTID=OEL8` is set for the same reason as in the other labs: the 19c
base release only knows the Oracle Linux 8 releases that existed when it shipped.

## What each provisioning step does

| Step | Script | Details |
|------|--------|---------|
| (host) | `host/lio-target.sh` | 5 sparse LUN images, LIO fileio backstores with PR emulation, portal on the storage bridge, `rac-iscsi-target.service` so the LUNs survive a host reboot |
| (host) | `host/scan-dns.sh` | publishes/removes the three SCAN A records on the `rac-pub` network |
| `base` | `01-base.sh` | hostnames, `/etc/hosts` (loopback entries for the node names removed), SELinux permissive, firewalld off, preinstall + cluster packages, `grid`/`oracle` accounts, kernel parameters, limits, THP, three networks, DNS, SSH trust, chrony off for CTSS |
| `storage` | `02-storage.sh` | iSCSI discovery/login, udev rules for `/dev/asm-disk*`, ownership verification, stale signature removal |
| `grid_install` | `03-grid-install.sh` | cvuqdisk on both nodes, response file, `gridSetup.sh`, root scripts in order |
| `asm` | `04-asm.sh` | `asmca -silent` for `DATA` and `FRA` (EXTERNAL redundancy, one LUN each) |
| `db_install` | `05-db-install.sh` | database home with `CLUSTER_NODES`, root.sh on both nodes, node-local profile/oratab |
| `db_create` | `06-db-create.sh` | `dbca -policy AUTOMATIC -nodeinfo rac1,rac2` on ASM, archivelog, per-instance `local_listener` to the node VIP |
| `status` | `07-status.sh` | the per-node report behind `./lab status` |
| — | `cluster-action.sh` | `start-grid`, `stop-grid`, `start-db`, `stop-db`, used by `./lab start`/`./lab stop` |

## Network layout

| Use | Subnet | Members | libvirt network |
|-----|--------|---------|-----------------|
| Private interconnect | 10.40.1.0/24 | host .1, rac1 .11, rac2 .12 | `rac-priv` |
| Public / SCAN | 10.40.2.0/24 | host .1, rac1 .11, rac2 .12, VIPs .101/.102, SCAN .110-.112 | `rac-pub` |
| Storage (iSCSI) | 10.40.3.0/24 | host .1 (target), rac1 .11, rac2 .12 | `rac-storage` |
| Management | 192.168.121.0/24 | DHCP | `vagrant-libvirt` |

## Verifying the cluster

```bash
./lab status                 # both nodes: devices, DNS, CRS, ASM, database
sudo ./host/scan-dns.sh status
```

Inside a node:

```bash
sudo su - grid
crsctl check cluster -all
crsctl stat res -t
asmcmd lsdg                  # OCR, DATA, FRA, with OCR showing NORMAL redundancy
srvctl status database -d ORCL
```

Useful checks for the RAC-specific pieces:

```bash
# which instances are running where
srvctl status database -d ORCL

# the same table visible from both instances
sqlplus system/Oracle123@//rac-scan.lab/ORCL <<'SQL'
select instance_name, host_name from v$instance;
select inst, count(*) from rac_test group by inst;
SQL

# SCAN load balancing: repeatedly resolve and connect, the instance changes
for i in 1 2 3; do
  sqlplus -s system/Oracle123@//rac-scan.lab/ORCL <<<'select instance_name from v$instance;'
done
```

## How the Grid Infrastructure SSH validation issue was fixed

`./lab grid` originally stopped at Grid Infrastructure's own SSH validation
(`INS-44000` / `INS-06006` "Passwordless SSH connectivity is not setup … [rac2]").
Everything the check relies on worked by hand: `grid`/`oracle` could
`ssh`/`scp` to the peer and to themselves with the installer's exact options,
host keys were pre-seeded, both nodes shared a key pair, `UseDNS no` was set.

The root cause was found with `strace` on the installer's `scp` invocation:
Oracle's CVU runs `scp -p rac2:'/path' dest` with **literal single quotes** in
the remote path (it execs scp directly, without a shell). OpenSSH 8.0's scp sink
keeps the quote in the filename pattern and `fnmatch()` rejects it, so the
remote side fails with `protocol error: filename does not match request` and the
answer never lands. OpenSSH 7.x tolerated this; OpenSSH 8.0 does not.

`01-base.sh` installs a tiny dequoting wrapper at `/usr/bin/scp` (the real scp
is kept as `/usr/bin/scp.orig`) that strips single quotes from the arguments
before exec'ing the original. The same wrapper also fixes the database
installer's equivalent check.

## Limitations of this lab

* **Demo-mode iSCSI.** No CHAP and no initiator ACLs on the LUNs; the storage
  bridge is isolated, but this is the first thing to change for anything real.
* **EXTERNAL redundancy for DATA and FRA.** One LUN each, so there is no ASM
  mirroring there. OCR uses NORMAL across three LUNs, which is the real layout.
  A production DATA group would be NORMAL or HIGH across many LUNs.
* **CTSS instead of NTP.** There is no time source in the lab, so GI synchronises
  the nodes with each other. A real cluster uses NTP.
* **No TAF/Application Continuity service work, no RAC One Node, no Data Guard.**
  The database is a plain policy-managed RAC database.
* **The cluster does not survive `vagrant destroy`.** ASM and the OCR live in the
  array LUN images on the host, but the Grid Infrastructure home is inside the
  guests, so a destroy means re-running `./lab grid`.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `./lab up` fails with `groupadd: GID '54323' already exists` | already handled: the ASM groups take the first free GID above 54340. If you hit it, re-run `./lab provision rac1 base` |
| `root SSH to … is not working` | the shared key must exist on both nodes: check `.runtime/lab_root_key` and re-run the base step on both |
| `SCAN rac-scan.lab does not resolve` | `sudo ./host/scan-dns.sh setup`; the records live on the `rac-pub` libvirt network, so it must exist (`./lab up`) |
| `gridSetup.sh` aborts with `PRVF-4664 : Found inconsistent name resolution entries` | a loopback entry for the node names is still in `/etc/hosts`; `01-base.sh` removes them, re-run the base step |
| `gridSetup.sh` / `runInstaller` stop with `INS-44000` / `INS-06006` "Passwordless SSH connectivity" | the dequoting scp wrapper is missing (older boxes before this fix): re-run `./lab provision <node> base` to install it |
| `gridSetup.sh` fails on prerequisites about `cvuqdisk` | it is installed from the grid media by `03-grid-install.sh`; check `rpm -q cvuqdisk` on both nodes |
| `runInstaller` (DB) stops with `INS-32060` "Insufficient permissions … [rac2]" | the Oracle base/home tree must pre-exist on both nodes; `05-db-install.sh` creates it, re-run `./lab db-software` |
| `dbca` crashes with `Could not initialize class … StorageUtil` (NPE) | the 19c base release cannot detect Oracle Linux 8.9's distribution ID; the script now sets `CV_ASSUME_DISTID=OEL8`. Re-run `./lab database` |
| `dbca` prints its usage and exits | an invalid flag was passed; the script now uses `-policyManaged -serverPoolName ORCLPool -createServerPool` (not `-policy`/`-nodeinfo`/`-timeZone`) |
| `root.sh` on rac1 hangs at "Adding Clusterware entries to inittab" | it is not hanging, that step takes minutes; watch `tail -f /u01/app/19.0.0/grid/install/root_rac1_*.log` |
| `asmca` says `ORA-15032`/`ORA-15018` when creating DATA | the LUN still carries an old signature: `wipefs -a /dev/asm-disk4` then re-run `./lab asm` |
| `dbca` fails with `ORA-15055`/`+DATA` not mounted | check `asmcmd lsdg` as `grid`; the DATA group must be mounted on both instances |
| `sqlplus … @//rac-scan.lab/ORCL` gives `ORA-12545` | one of the SCAN addresses is unroutable, or the listener is not registered: `srvctl status scan_listener` |
| After `vagrant reload` the cluster does not come up | `./lab start-grid` on rac1, then `./lab start` |

## Teardown

```bash
./lab destroy   # removes both VMs, keeps the LUN images
./lab clean     # also removes the LUN images, the SCAN records and .runtime/
```
