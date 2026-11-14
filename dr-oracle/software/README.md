# Oracle installer media

Put the Oracle 19c database home zip here:

```
LINUX.X64_193000_db_home.zip
```

The Oracle home is installed locally on **both** database hosts, so the same zip
is uploaded to `db1` and `db2` (the arrays do not need it). Oracle downloads are
not redistributable, so nothing in this directory is tracked by git.

If you already have the media in another lab of this repository, a symlink is
enough - the `Vagrantfile` resolves it before uploading:

```bash
ln -s ../../rhel-ha-oracle/software/LINUX.X64_193000_db_home.zip .
```

Without the zip `vagrant up` still produces working VMs: `06-oracle-install.sh`
reports what is missing and the database-related steps are skipped.
