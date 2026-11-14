# Installer media

Everything in this directory except this file is ignored by git. The lab
expects the following files here; missing media only skips the matching
provisioning step, so `vagrant up` still produces working nodes.

| File | Used by | Notes |
|------|---------|-------|
| `InfoScale_Availability_7.4.2/` (directory containing `installer`), `VCS_InfoScale_Availability_7.4.2_Linux.tar.gz` or `InfoScale_Availability_7.4.2_Linux.iso` | `06-vcs-install.sh` | Veritas/Arctera download. 7.4.2 is the release documented for Oracle Linux 8. Use **Foundation** or **Enterprise** media if you want I/O fencing: VXFEN needs VxVM for the `vxfencoorddg` disk group. |
| `vxlic.key` | `06-vcs-install.sh` | Optional VCS license key file. Without it VCS runs unlicensed (evaluation warnings, cluster stops enforcing after the grace period). |
| `LINUX.X64_193000_db_home.zip` (any `*db_home*.zip` works) | `04-oracle-install.sh` | Oracle 19c database home zip. |

The media is copied into the guests (`/home/vagrant/vcs-lab/software`) by a
Vagrant file provisioner, so it only has to exist on the host. Because the
provisioner is only added when this directory contains files, add the media
before the first `./lab up` - or run `vagrant up --provision` afterwards.

The Veritas installer needs a response file for unattended use. The lab derives
`$CFG{prod}` from the media name (`InfoScale_Availability_7.4.2` ->
`AVAILABILITY742`, `InfoScale_Enterprise_7.4.2` -> `ENTERPRISE742`). If your
media does not carry the edition in its name, override the tag, for example:

```bash
VCS_LAB_INFOSCALE_PRODUCT=AVAILABILITY743 vagrant provision vcs1 --provision-with vcs_install
```
