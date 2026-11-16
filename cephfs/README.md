# Ceph File System lab: three servers, six OSDs, two clients, one file system

A three-node Ceph cluster on libvirt that serves a **Ceph File System** (CephFS)
volume to two client VMs through the FUSE client. It is built like the other
cluster labs in this repository: Oracle Linux guests on libvirt, everything
declared in the `Vagrantfile`, and a `./lab` helper that sequences the steps that
need more than one node.

```
                     lab network 10.60.1.0/24
   ┌────────────────┐   ┌────────────────┐   ┌────────────────┐
   │     ceph1      │   │     ceph2      │   │     ceph3      │
   │  10.60.1.11    │   │  10.60.1.12    │   │  10.60.1.13    │
   │ MON  MGR       │   │ MON  MGR       │   │ MON            │
   │ MDS  OSD×2     │   │ MDS  OSD×2     │   │      OSD×2     │
   └───────┬────────┘   └───────┬────────┘   └───────┬────────┘
           │ 8 GB + 8 GB        │ 8 GB + 8 GB        │ 8 GB + 8 GB
           └────────────────────┴────────────────────┘
                     CephFS  (MDS on ceph1/ceph3)
                          │              │
              ┌───────────┴───┐      ┌───┴───────────┐
              │   client1     │      │   client2     │
              │  10.60.1.21   │      │  10.60.1.22   │
              │  ceph-fuse    │      │  ceph-fuse    │
              └───────────────┘      └───────────────┘
```

## What gets built

| Component | Implementation |
|-----------|----------------|
| Servers | `ceph1`, `ceph2`, `ceph3`: Oracle Linux 9, 4 GB and 2 vCPU each, one lab interface plus the libvirt management interface |
| Clients | `client1`, `client2`: Oracle Linux 9, 2 GB and 1 vCPU each, mount the file system with `ceph-fuse` (add or remove them with `CEPH_LAB_CLIENTS`) |
| Deployment | `cephadm` (Ceph Squid, 19.2.x) with every daemon in a rootful podman container managed through `ceph orch` |
| Monitors | 3, one per server: a quorum survives the loss of any single server |
| Managers | 2: one active, one standby, for the dashboard, the orchestrator and the volumes module |
| OSDs | 6: two 8 GB disks per server, BlueStore, one OSD per disk |
| Data protection | Pool size 3, `min_size` 2, CRUSH failure domain `host` — the cluster stays writable with one server down |
| CephFS | `cephfs` file system: `cephfs_metadata` + `cephfs_data` pools, one active and one standby MDS |
| Client access | one CephX user per client (`client.client1`, `client.client2`) with `rwps` on `/`, each mounted on `/mnt/cephfs` by `ceph-fuse` and kept across reboots by `/etc/fstab` |
| Time sync | `chronyd` on every node; the VMs share the host clock, so no external NTP is needed for a lab |

Capacity is 6 × 8 GB raw, 16 GB usable with size 3. That is enough to show
replication, rebalancing and recovery on a timescale of seconds, which is the
point of a lab.

## Requirements

* KVM (`/dev/kvm`), libvirt, QEMU and Vagrant 2.4+ with `vagrant-libvirt`
  (`vagrant plugin install vagrant-libvirt`; needs `libvirt-dev`, `libxml2-dev`,
  `zlib1g-dev`, `libxslt1-dev` and a compiler to build the plugin).
  Nothing on the host needs **sudo**: this lab has no iSCSI target.
* ~16 GB RAM free (3 × 4 GB + 2 × 2 GB) and ~40 GB disk for the sparse OSD
  volumes. `CEPH_LAB_CLIENTS` sets how many client VMs are built (default 2).
* **Internet access from the guests.** Ceph is no longer shipped in Oracle
  Linux's own repositories and cephadm runs containers, so the provisioning
  downloads two things:
  * the `ceph-common`, `cephadm`, `podman` and `ceph-fuse`/`attr` RPMs from
    `download.ceph.com` — about 100 MB per server, 30 MB per client;
  * the Ceph container image (`quay.io/ceph/ceph:v19.2.x`, ~490 MB to download,
    ~1.4 GB on disk) on every server, pulled by cephadm the first time it starts
    a daemon.

  No Ceph media has to be placed in this directory — unlike the Oracle labs,
  there is nothing to download by hand.

Set `CEPH_LAB_IMAGE=quay.io/ceph/ceph:v19.2.7` to pin the container image, for
instance when the lab has to work offline after one successful run (the image
is cached on each node's disk and survives `./lab halt`).

`download.ceph.com` is slow from some networks. Any mirror of it works, so pass
one in before the first `./lab up`:

```bash
CEPH_LAB_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/ceph ./lab up
```

## Quick start

```bash
cd cephfs
./lab up        # five provisioned VMs (ceph1-3, client1, client2)
./lab cluster   # bootstrap, monitors, managers, OSDs, MDS pair, CephFS (~5-25 min)
./lab client    # join both client VMs and mount /mnt/cephfs on each
./lab status    # cluster health, daemons, placement groups, mount state
```

`./lab install` runs the last two steps in one go.

Then poke at it:

```bash
./lab ceph -s                       # cluster summary
./lab ceph fs status cephfs         # MDS ranks and the file system's pools
./lab df                            # pool usage and both client mounts
./lab shell                         # cephadm shell on ceph1 for ad-hoc ceph/rados commands
./lab ssh client2                   # df -h /mnt/cephfs, write files, ...
```

The dashboard is at `https://10.60.1.11:8443` with `admin` /
`Ceph12345` (change it with `CEPH_LAB_DASHBOARD_PASSWORD` before the first
`./lab cluster`; after that set it with `ceph dashboard ac-user-set-password`).

## What each provisioning step does

| Step | Script | What it does |
|------|--------|--------------|
| `base` | `scripts/01-base.sh` | Host name, `/etc/hosts` for all four nodes, the 10.60.1.0/24 interface, SELinux permissive and firewalld off, journal size cap, `chronyd`, the Ceph package repository, `ceph-common`/`cephadm`/`podman`/`lvm2` (plus `ceph-fuse` on the client), the shared lab SSH key and passwordless root SSH between the nodes |
| `cluster` | `scripts/02-cluster.sh` | Runs on `ceph1`: `cephadm bootstrap`, hands the cephadm public key to the other servers, adds them as cluster hosts with the `_admin` label, spreads the monitors, places two managers, `ceph orch apply osd --all-available-devices`, creates the CephFS pools and the file system, deploys two MDS daemons and authorises `client.cephfs` |
| `client` | `scripts/03-client.sh` | Runs on each client (`./lab client client2` for one): pulls `ceph.conf` and its own keyring from `ceph1`, mounts `/mnt/cephfs` with `ceph-fuse`, adds the `/etc/fstab` entry and does a write/read round trip |
| `status` | `scripts/04-status.sh` | Read-only report for any node; on the cluster nodes it shows hosts, daemons, OSD tree, CephFS and capacity, on the client the mount and the file system status |

`base` runs during `vagrant up`; `cluster` and `client` need every node up (and
`client` needs the cluster), so they are `run: "never"` provisioners that `./lab`
launches. Both are safe to re-run: bootstrap, host add, pool creation, the file
system and the keyring are all guarded or idempotent.

## How it fits together

### Why the monitors are on all three servers

A Ceph monitor holds the cluster map, and clients and OSDs can only act on a map
they agree on. Three monitors on three hosts means a quorum of two survives any
single node disappearing — which is exactly what `./lab crash ceph2` shows. The
cluster is bootstrapped with one monitor and the placement spec in
`02-cluster.sh` spreads it:

```bash
ceph orch apply mon --placement="ceph1,ceph2,ceph3"
```

### Where the data lives

`ceph orch apply osd --all-available-devices` is cephadm's declarative way of
saying "use every whole disk that is not in use". The Vagrantfile adds two
8 GB qcow2 volumes to each server after the root disk, so this creates six
OSDs — two per host. Because the CRUSH failure domain is the host, a pool of
size 3 stores one copy on each server: any one server (and its two OSDs) can be
lost without data loss, and the cluster stays writable because `min_size` is 2.

```
$ ./lab ceph osd tree
ID  CLASS  WEIGHT   TYPE NAME       STATUS  REWEIGHT  PRI-AFF
 -1         0.04688  root default
 -3         0.01562      host ceph1
  0    hdd  0.00781          osd.0       up   1.00000  1.00000
  1    hdd  0.00781          osd.1       up   1.00000  1.00000
...
```

### CephFS metadata and data

CephFS splits a file system in two: the *metadata pool* holds the directory
tree, file names, permissions and layouts, and the *data pool* holds file
contents. `02-cluster.sh` creates both pools, tags them `cephfs` and builds the
file system on top:

```bash
ceph osd pool create cephfs_metadata
ceph osd pool create cephfs_data
ceph osd pool application enable cephfs_metadata cephfs
ceph osd pool application enable cephfs_data cephfs
ceph fs new cephfs cephfs_metadata cephfs_data
```

Then one MDS serves the namespace and a second one waits:

```bash
ceph orch apply mds cephfs --placement="2 ceph1 ceph2 ceph3"
```

`ceph fs status` shows the ranks and which daemon is active; killing the active
MDS (`./lab crash ceph1`, or `systemctl restart` on that MDS) hands the rank to
the standby in seconds, with no client-visible outage beyond a short stall.

### The clients

`ceph-fuse` talks to the monitors once to get the map and then to the OSDs
directly, so a client only needs the monitor list and a key:

```
ceph1,ceph2,ceph3:/ /mnt/cephfs fuse.ceph ceph.id=client1,ceph.conf=/etc/ceph/ceph.conf,_netdev,defaults 0 0
```

Each client has its own CephX user — `client.client1` on `client1`,
`client.client2` on `client2` — so `ceph fs status` counts two clients and the
MDS keeps a session per mount, and revoking one does not disturb the other.
(`ceph fs status` sometimes counts one more: the mgr `volumes` module mounts the
file system itself to create subvolume directories.) The key is scoped to the file system's
path and has no `mon`/`osd` administrative caps, which is why `ceph -s` works on
a client but `ceph osd tree` does not. Administrative commands run on `ceph1`,
where cephadm bootstrapped the admin keyring.

The `rwps` caps matter for the demo: `s` is the snapshot right, and without it
creating `/mnt/cephfs/.../.snap/<name>` fails with `EACCES` no matter what the
directory mode says.

Both clients mount the same file system, so a file written on one is visible on
the other with the same inode — `./lab demo` shows that, and it is the whole
point of a clustered file system.

### Writing a file on one client and reading it on the other

There is no copy step: both clients mount the same file system, so the file
created on `client1` *is* the file `client2` reads — same inode, same data, no
`scp`, no `rsync`, no `sync`.

```bash
./lab ssh client1
echo hello > /mnt/cephfs/shared/hello.txt
exit
./lab ssh client2
cat /mnt/cephfs/shared/hello.txt
stat -c 'inode=%i %n' /mnt/cephfs/shared/hello.txt
```

```
hello
inode=1099511628294 /mnt/cephfs/shared/hello.txt
```

`03-client.sh` creates `/mnt/cephfs/shared` mode 1777 for exactly this: the file
system root belongs to `root` (`ceph-fuse` runs as root and mounts with
`allow_other`, but a normal user cannot create files in a `root`-owned 0755
directory), so this is the one place the `vagrant` user can write without
`sudo`.

The same thing without a shell, which is what `./lab demo` automates:

```bash
vagrant ssh client1 -c 'echo hello > /mnt/cephfs/shared/hello.txt'
vagrant ssh client2 -c 'cat /mnt/cephfs/shared/hello.txt'
```

Both mounts take their view from the MDS, which owns the namespace: `ls`,
`stat`, `cat` and `open` on the second client see the write as soon as the first
client has closed the file. A descriptor that was already open keeps its own
offset and does not pick the change up mid-stream — reopen it.

### Why the client mounts with ceph-fuse

Ceph Squid issues cephx keys with the `aes256k` cipher by default — Squid's
"secure key types" — while the kernel's Ceph client only implements `aes`:
`net/ceph/crypto.c` accepts `CEPH_CRYPTO_NONE` and `CEPH_CRYPTO_AES` and returns
`-ENOTSUPP` for anything else, from 5.14 through the 6.x kernels. `mount -t ceph`
therefore fails before it ever reaches a monitor:

```
adding ceph secret key to kernel failed: Unknown error 524
couldn't append secret option: -524
```

524 *is* `ENOTSUPP` — the kernel's private errno for "this key type is not
supported". `ceph-fuse` uses libcephfs, which speaks the current cephx, so it
mounts without changes and gives the same file system semantics (kernel client
and FUSE client both go through the MDS and the OSDs).

The alternative is to make the cluster issue `aes` keys (`ceph mon set
auth_service_cipher aes` plus a key rotation), but Squid reports that as
`AUTH_INSECURE_SERVICE_TICKETS` with `HEALTH_ERR`, so this lab keeps the secure
defaults and lets the userspace client do the talking.

## Demo commands

`./lab demo` walks through the things CephFS is usually chosen for:

* **shared files** — `client1` writes `/mnt/cephfs/demo/shared.txt`, `client2`
  reads it back with the same inode, and the active MDS shows one session per
  mount (`client1` and `client2`, both on `/mnt/cephfs`).
* **snapshots** — `mkdir /mnt/cephfs/demo/snap/.snap/before-edit` creates a
  read-only view of that directory; the demo edits the file, reads the snapshot
  copy and restores it.
* **quotas** — `setfattr -n ceph.quota.max_bytes -v 10485760` caps a directory
  at 10 MiB, and the following 20 MiB write stops with `EDQUOT` shortly after
  the limit (a file system quota is checked as data lands, not per write, so it
  overshoots by a block or two).
* **subvolumes** — `ceph fs subvolume create cephfs web --group_name apps
  --size 2147483648` creates an independent tree with its own quota. The demo
  asks the cluster for its path (`ceph fs subvolume getpath ...`), which is
  `/volumes/apps/web/<uuid>`, and shows the 2 GiB `ceph.quota.max_bytes` on it.
  This is the abstraction Kubernetes CSI and OpenStack Manila use.
* **self-healing** — one OSD is taken out of the CRUSH map, the cluster
  rebalances, and putting it back lets the cluster backfill to
  `active+clean`.

`./lab bench` adds numbers: `rados bench` against a dedicated `bench` pool and a
512 MB `dd` round trip through the mount.

## Failure labs

```bash
./lab crash ceph2      # virsh destroy: the node dies without stopping anything
./lab ceph -s          # one mon out of quorum, two OSDs down, still writable
./lab recover ceph2    # boot it again, then wait for active+clean
```

The monitors keep quorum, writes keep working (size 3, `min_size` 2) and the
cluster backfills when the node returns. `./lab crash ceph1` also takes the
active MDS and the dashboard with it — the standby MDS picks up the rank.

For a graceful stop of a single node's daemons, use `./lab stop ceph2` and
`./lab start ceph2`; `./lab halt` stops all five VMs with the disks intact, and
`./lab up` brings the cluster back (every daemon is a systemd unit enabled on
boot, and the clients mount from `/etc/fstab` through `remote-fs.target`).

Killing a client (`./lab crash client1`) is harmless by design: the MDS notices
the session goes away, and `./lab recover client1` brings the mount back.

## Limitations of this lab

* Only one network. Real clusters separate a public (client) network from a
  cluster (replication) network so OSD recovery traffic does not compete with
  clients; here both are 10.60.1.0/24, which is also why `cluster_network` is
  left unset.
* Two OSDs per host and 8 GB each. Recovery finishes in seconds, so the
  interesting "watch it heal" phase is short, and `PG_AVAILABILITY` warnings
  appear while an OSD is out because there is no spare capacity to move data
  to — that is expected with 3 hosts at size 3.
* The monitoring stack (Prometheus, Grafana, Alertmanager) is skipped
  (`--skip-monitoring-stack`); it needs several GB of RAM per node.
* SELinux is permissive and firewalld is off instead of opening the Ceph ports.
* Every daemon runs as a rootful podman container on the VM's own disk, managed
  by cephadm; only the CLI comes from an RPM.
* The client uses `ceph-fuse` rather than the kernel client, because the box's
  5.14 kernel does not understand Squid's default `aes256k` cephx keys. The
  mount behaves the same for everything the lab demonstrates, but throughput
  goes through a userspace daemon (see above).

## Troubleshooting

Run `./lab status` first; it prints the cluster view from `ceph1` and the mount
view from `client` without changing anything.

| Symptom | What to look at |
|---------|-----------------|
| `./lab cluster` stops at bootstrap | `/var/log/ceph/cephadm.log` and `journalctl -u ceph-*` on `ceph1`; almost always an image pull failure |
| Hosts stay `Offline` in `ceph orch host ls` | `lab_ssh ceph2 true` from `ceph1`; the cephadm key in `/etc/ceph/ceph.pub` must be in `root`'s `authorized_keys` on the peer |
| No OSDs created | `./lab ceph orch device ls --wide` — a device that still has a partition, LVM metadata or a file system is refused. `wipefs -a /dev/vdb` on the host and re-run `./lab cluster` |
| PGs stuck `inactive`/`undersized` with 3 hosts | expected while an OSD or host is down; check `./lab ceph health detail` and wait for the backfill |
| `ceph-fuse` does not start (`mount: only root can mount` / no such file) | the keyring must be `/etc/ceph/ceph.client.cephfs.keyring`, mode 0600, and `ceph.conf` must resolve the monitors |
| `mount -t ceph` fails with `Unknown error 524` | the kernel client on this box cannot use `aes256k` keys; use `ceph-fuse` (this is what `./lab client` does) |
| snapshot creation fails with `EACCES` | `client.cephfs` needs the `s` cap: `ceph fs authorize cephfs client.cephfs / rwps`, then remount so the session picks up the new caps |
| `ceph -s` on the client says `EACCES` | `client.cephfs` is deliberately not an admin key; use `./lab ceph` on `ceph1` |
| Health warning `clock skew` | the VMs share the host clock; `chronyc tracking` shows whether NTP is reachable |
| Health warning after `./lab bench` | the `bench` pool is left behind with its application tag; remove it with `./lab ceph osd pool rm bench bench --yes-i-really-really-mean-it` |
| a provisioning step has to be re-run | `./lab provision ceph1 base` (or `cluster`, `client`, `status`); `./lab client client2` re-joins one client |
| the second client cannot mount | `./lab ceph auth get client.client2` must exist (re-run `./lab cluster`), and `./lab client client2` pulls its keyring again |

Logs for one node: `./lab logs ceph2` (the last 100 lines of the Ceph daemon
units), or `./lab ssh ceph2` followed by `sudo podman logs ceph-<fsid>-osd-2`.

## Teardown

```bash
./lab halt        # stop the VMs, keep the cluster and its disks
./lab up          # start them again; the daemons come back by themselves
./lab destroy     # destroy the VMs and the cluster with them
./lab clean       # destroy, plus the .runtime/ directory (the lab SSH key)
```

Everything the lab creates lives in the VMs and in `.runtime/`, so there is no
host-side state to clean up.
