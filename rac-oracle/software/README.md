# Oracle installer media

RAC needs **two** homes, and both zips belong here:

| File | What it installs |
|------|------------------|
| `LINUX.X64_193000_grid_home.zip` | Grid Infrastructure: Clusterware (CRS/CSS), ASM, SCAN listeners |
| `LINUX.X64_193000_db_home.zip`   | Oracle Database 19c with the RAC option |

The database home alone cannot form a cluster — the OCR, the voting files, the
node membership and ASM all come from the Grid Infrastructure home, so
`./lab grid` is the step that has to happen first.

Oracle downloads are not redistributable, so nothing in this directory is
tracked by git. A symlink to a copy in another lab of this repository is enough
for the database home; the `Vagrantfile` resolves it before uploading:

```bash
ln -s ../../rhel-ha-oracle/software/LINUX.X64_193000_db_home.zip .
```

Without the grid zip `./lab up` still produces two prepared nodes: packages,
accounts, SSH trust, the three lab networks, the five ASM LUNs with their udev
names and DNS for SCAN are all in place, and `./lab grid` explains what is
missing instead of half-installing.
