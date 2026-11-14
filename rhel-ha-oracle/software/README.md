# Installer media

Everything in this directory except the README and its `.gitignore` is ignored
by git. The lab only needs the Oracle 19c database home; missing media only
skips the matching provisioning step, so `vagrant up` still produces a working
Pacemaker cluster.

| File | Used by | Notes |
|------|---------|-------|
| `LINUX.X64_193000_db_home.zip` (any `*db_home*.zip` works) | `04-oracle-install.sh` | Oracle 19c database home zip (~3 GB). |

The media is copied into the guests (`/home/vagrant/ha-lab/software`) by a
Vagrant file provisioner, so it only has to exist on the host. The provisioner
is only added when this directory contains a file, so add the media before the
first `./lab up` - or run `vagrant up --provision` afterwards.
