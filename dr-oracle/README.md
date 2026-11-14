# Oracle DR lab: two data centres, two SANs, block replication

An Oracle Database 19c disaster-recovery environment that fits on one Linux
workstation. Two data centres, each with its own SAN array and its own database
host, and the arrays replicate every block between the sites — the same model as
EMC SRDF, NetApp SnapMirror or Pure ActiveDR, only built from `targetcli` and
DRBD instead of a storage product.

```
        SITE A                                                      SITE B
  ┌───────────────┐   SAN fabric A                 SAN fabric B   ┌───────────────┐
  │  db1  .21     │   10.50.10.0/24               10.50.20.0/24    │  db2  .21     │
  │  Oracle 19c   │        │                            │          │  Oracle 19c   │
  │  (active)     │        │ iSCSI                      │          │  (idle / DR)  │
  └───────┬───────┘        │                            │          └───────┬───────┘
          │ .11      ┌─────┴──────┐    replication     ┌────────────┐      │ .12
          │          │  san1 .10  │  10.50.30.0/24     │  san2 .10  │      │
          │          │  array A   │◄══════════════════►│  array B   │      │
          │          │  /dev/drbd0│  DRBD, protocol C  │ /dev/drbd0 │      │
          │          └────────────┘  (or A for async)   └────────────┘      │
          └────────────── dr-app 10.50.40.0/24 ── VIP 10.50.40.100 ─────────┘
```

| Component | Implementation |
|-----------|----------------|
| Data centres | two sets of VMs, separate layer-2 segments, no shared fabric |
| SAN arrays | `san1`/`san2`: Linux VMs with two real block devices each, exported over iSCSI with `targetcli` |
| SAN replication | DRBD 9 between the two appliances over a dedicated link with WAN latency (`netem`) |
| Database hosts | `db1`/`db2`: Oracle Linux 8.9, Oracle 19c home on local disk, iSCSI initiator via `iscsiadm` |
| Database | single instance `orcl`, data/redo/SPFILE on LUN 0 (`/u02`), archive logs/FRA on LUN 1 (`/u03`) |
| Client access | floating service address `10.50.40.100:1521`, moved with the active site |

## Why block replication instead of Data Guard

Data Guard ships redo over the network and needs a second Oracle instance. This
lab models the other half of the DR world: the storage array does the copying,
the standby site holds a crash-consistent copy of the same filesystems, and the
recovery is *instance crash recovery* on the surviving copy. That is exactly what
happens when you fail over to a SnapMirror or SRDF target.

The consequence is visible and worth studying:

* a **synchronous** copy (DRBD `protocol C`, the default here) loses nothing on a
  failover, but every commit pays the round-trip to the remote site;
* an **asynchronous** copy (`protocol A`, `./lab mode async`) keeps the primary
  fast and loses the last few seconds on a failover — `./lab failover` shows the
  missing rows in `DR_TEST`.

### Who presents the LUNs

A real array hands out a LUN only from the controller that owns it, and DRBD
behaves the same way: a `Secondary` device cannot even be opened (`Wrong medium
type`), let alone written. So the site that is currently `Primary` presents the
LUNs over iSCSI (`dr-action.sh present-luns`), and a demotion removes them again
(`unpresent-luns`) before the write role is given up. The host at the passive
site keeps its iSCSI session but sees no LUN until the array is promoted.

This is also why the DR copy cannot simply be mounted or read at site B to
"prove" that replication works. The proof is DRBD's own:

```bash
./lab verify      # online verification, ~5-10 min: both copies are block-identical
```

`./lab status` shows the same information continuously (`disk:UpToDate` on both
sides, `out-of-sync` counters while a resync runs).

## Requirements

* KVM (`/dev/kvm`), libvirt, QEMU, Vagrant 2.4+ with `vagrant-libvirt`.
* ~17 GB RAM free (`db1`/`db2` 6 GB, `san1`/`san2` 2 GB) and ~60 GB disk.
* Oracle 19c media in [`software/`](software/) (git-ignored; a symlink to the
  copy in another lab works).

Everything runs as the unprivileged user; no host-side target or firewall setup
is needed, because both arrays are VMs.

## Quick start

```bash
cd dr-oracle
./lab up          # four VMs: db1, db2, san1, san2 (~15 min, two Oracle homes)
./lab storage     # DRBD link, iSCSI export, LUNs on both database hosts
./lab database    # create the database at site A, validate the DR site
./lab status      # replication, mounts, VIP and database state
./lab verify      # optional: online verification of the DR copy (5-10 minutes)
```

If the media only appeared after `./lab up`, install it first — the media is
uploaded to both database hosts, the Oracle homes are installed locally and the
rest of the lab is untouched:

```bash
./lab oracle      # upload the 19c zip and install the Oracle home on db1 and db2
./lab database
```

Without the Oracle media the storage half of the lab still works end to end
(`./lab switchover`, `./lab failover` and `./lab recover` move the LUNs, the
filesystems and the VIP); the steps that need the database say so and skip.

After `./lab database` the database runs at site A and `dr_test` holds one row.
`./lab sql` connects as `SYSTEM` through the service address, splits several
statements onto separate lines and stops at the first SQL error:

```bash
./lab sql "select * from dr_test;"
./lab sql "insert into dr_test (site, note) values ('A', 'hello'); commit;"
./lab start        # open the database at the active site
./lab stop         # close it again (shutdown immediate, unmount, VIP released)
```

From the host you can also reach the service address directly:

```bash
sqlplus system/Oracle123@//10.50.40.100:1521/orcl
```

## DR runbooks

### Planned switchover (both sites healthy)

```bash
./lab switchover
```

1. `dr-action.sh check-sync` verifies that every LUN on the DR array is
   `UpToDate` (it refuses to continue otherwise, `--force` overrides),
2. the instance is shut down cleanly, the filesystems unmounted, the VIP released,
3. the active array removes its LUNs and is demoted to `Secondary`, the DR array
   is promoted and presents its LUNs, the demoted host drops its stale devices,
4. the DR host mounts the same filesystems by label, opens the instance (no
   crash recovery is needed after a clean shutdown), starts the listener and
   takes over the VIP with a gratuitous ARP.

Running it twice returns you to the original site.

### Unplanned failover (site A is gone)

```bash
./lab failover
```

1. the active site's VMs are hard power-cycled (`vagrant halt --force`), which is
   indistinguishable from a data-centre loss for the survivor,
2. the surviving array is promoted with `drbdadm primary --force` — the "break
   the mirror" step of an array runbook — and starts presenting its LUNs,
3. the surviving host mounts the replicated filesystems and opens the instance,
   which performs **instance crash recovery** from the replicated redo logs.

Rows committed before the crash are in the DR copy with synchronous
replication; with `./lab mode async` the last few are not — compare with
`./lab sql "select count(*) from dr_test;"`.

### Failback

```bash
./lab recover
```

powers the failed site back on, waits for DRBD to resynchronise the stale array
from the promoted one, and then performs a clean switchover back.

### Watching replication and the WAN

```bash
./lab status                 # DRBD roles, connection state, LUNs, VIP, instance
./lab wan 20ms               # make the replication link slow
./lab mode async             # stop waiting for the remote site on commit
./lab mode sync              # back to zero-loss
```

`./lab status` on the arrays prints the DRBD view of both resources:

```
== DRBD replication
    version: 9.3.4
    ora_data role:Primary
      disk:UpToDate
      san2 role:Secondary
        peer-disk:UpToDate
```

## Network layout

| Use | Subnet | Members | libvirt network |
|-----|--------|---------|-----------------|
| Site A SAN fabric | 10.50.10.0/24 | host .1, san1 .10, db1 .21 | `dr-san-a` |
| Site B SAN fabric | 10.50.20.0/24 | host .1, san2 .10, db2 .21 | `dr-san-b` |
| Array replication | 10.50.30.0/24 | host .1, san1 .11, san2 .12 | `dr-repl` |
| Client network | 10.50.40.0/24 | host .1, db1 .11, db2 .12, VIP .100 | `dr-app` |
| Management | 192.168.121.0/24 | DHCP | `vagrant-libvirt` (Vagrant) |

The two SAN fabrics are separate bridges on purpose: `db1` has no route to
`san2`, so the only path for data between the sites is the array-to-array
replication link.

## What each provisioning step does

| Step | Script | Details |
|------|--------|---------|
| `array` | `01-array.sh` | OL8 + ELRepo DRBD 9 (`kmod-drbd90` links itself against the box kernel through weak-modules), `targetcli`, per-site static addresses, `netem` delay on the replication interface |
| `drbd` | `02-drbd.sh` | two resources (`ora_data` on `/dev/vdb`, `ora_fra` on `/dev/vdc`), internal metadata, protocol C, split-brain policy |
| `target` | `03-target.sh` | per-site IQN and portal, demo-mode ACLs, `target.service` ordered after `drbd.service`; presents the LUNs only where the array is `Primary` |
| `base` | `04-db-base.sh` | name resolution, `iscsi-initiator-utils`, initiator name, SAN + client interfaces, swap |
| `oracle_prereq` | `05-oracle-prereq.sh` | preinstall package, `/u01` layout, `oraInst.loc`, THP |
| `oracle_install` | `06-oracle-install.sh` | silent software-only install on both sites, `init<sid>.ora` pointing at the replicated SPFILE, listener bound to the VIP |
| `db_storage` | `07-db-storage.sh` | iSCSI discovery/login and by-path LUN names on both hosts; ext4 labels and `/u02` + `/u03` at site A only, since site B has nothing presented yet |
| `oracle_database` | `08-oracle-database.sh` | `dbca` with datafiles on `/u02` and FRA on `/u03`, shared SPFILE, archivelog, `dr_test` table |
| `dr_prepare` | `09-dr-prepare.sh` | proves the DR copy is a readable filesystem and that nothing is mounted there |
| `status` | `10-status.sh` | the per-node report used by `./lab status` |

`dr-action.sh` holds the operational verbs (`promote-array`, `demote-array`,
`check-sync`, `stop-db`, `start-db`, `mode`, `wan`) so that `./lab` only has to
sequence them.

## Files on the replicated LUNs

```
/u02 (LUN 0, ext4 LABEL=oradata)     /u03 (LUN 1, ext4 LABEL=orafra)
  app/oracle/oradata/                  app/oracle/fast_recovery_area/
  app/oracle/admin/orcl/adump/         (archive logs, FRA)
  app/oracle/admin/orcl/pfile/spfileorcl.ora
```

Both hosts have the same mount points and the same `LABEL=` entries in
`/etc/fstab` with the `noauto` option: a DR site must never mount a LUN that has
not been promoted, and DRBD refuses the writes even if somebody tries.

## Limitations of this lab

* **Demo-mode iSCSI.** No CHAP and no initiator ACLs; any host that reaches a
  fabric can log in. Fine for isolated lab bridges, not for anything real.
* **Replication is DRBD, not a real array.** DRBD gives synchronous/asynchronous
  block replication and mirror breaking, which is the part that matters for
  Oracle, but there is no snapshot, no consistency group and no write-order
  guarantee across the two LUNs beyond DRBD's own ordering.
* **Crash consistency, not application consistency.** Oracle's crash recovery is
  what makes the DR copy usable, exactly as with real array replication.
* **The replica is not readable in place.** DRBD does not allow opening a
  `Secondary` device, so `verify-replica` (and `./lab verify`) uses the online
  checksum comparison instead of mounting the DR copy read-only.
* **One instance per site.** No RAC, no Data Guard, no observer: the database is
  a single instance that moves between sites.
* **No automatic failover.** Deciding to promote the DR array is a human
  decision; `./lab failover` is the runbook, not a daemon.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `01-array.sh` fails with `the DRBD kernel module does not load` | the box kernel has no ABI-compatible weak-updates link; run `dnf update kernel` in the array VM and `vagrant reload san1 san2`, then re-provision |
| `drbdadm create-md` complains about an existing signature | the array disks are expected to be empty; `wipefs -a /dev/vdb` (or `vdc`) and re-run `./lab storage` |
| `./lab storage` hangs waiting for the initial sync | check `./lab status` on `san1`/`san2`; a `StandAlone` peer usually means the replication network or the `netem` delay is wrong (`./lab wan 0`) |
| `demote-array` fails with "a filesystem is still mounted" | `./lab switchover` stops the database and unmounts first; if you demoted by hand, unmount `/u02` and `/u03` on the active host |
| `./lab switchover` refuses with "not fully in sync" | wait for DRBD to finish (`./lab status`), or accept the loss with `./lab switchover --force` |
| after `./lab failover` the DR database opens with `ORA-01589`/media recovery errors | the archive/FRA LUN was not promoted; check both `ora_data` and `ora_fra` report `Primary` |
| the VIP does not answer from the host right after a switchover | the host's ARP cache still points at the old MAC: `ip neigh flush 10.50.40.100` (the lab sends a gratuitous ARP, some kernels still need this) |
| `dbca` fails with `DBT-10317 Specified SID Name (orcl) already exists` | dbca refuses a SID it finds in `$ORACLE_HOME/dbs` or `/etc/oratab`; `08-oracle-database.sh` hides the node-local init file and oratab entry while it runs |
| `./lab sql` says `the Oracle software is not installed` | run `./lab oracle` (it uploads `software/*.zip` to both hosts) and then `./lab database` |
| `Wrong medium type` when opening `/dev/drbdN` on the DR array | expected: a DRBD `Secondary` cannot be opened. Promote the array first (`dr-action.sh promote-array`) |
| `01-array.sh` warns that netem could not be installed | `tc` comes from `iproute-tc` and `sch_netem` from `kernel-modules-extra-$(uname -r)`; the step installs both, a kernel update may need `vagrant reload san1 san2` |
| `drbdadm verify` fails with "Need a verify algorithm" | the resource needs `net { verify-alg crc32c; }`; `02-drbd.sh` writes it, re-run that step after editing |
| the demoted host still shows an old `sdX` device | `dr-action.sh rescan` deletes the stale SCSI device; `./lab switchover` runs it automatically |
| `06-oracle-install.sh` reports a missing media zip | put `LINUX.X64_193000_db_home.zip` in `software/` and re-run `./lab provision db1 oracle_install` and `./lab provision db2 oracle_install` |

## Teardown

```bash
./lab destroy     # removes the four VMs
./lab clean       # also removes .runtime/
```

The LUN contents live inside the array VMs, so a `./lab destroy` discards the
database as well — this lab has no host-side storage to preserve.
