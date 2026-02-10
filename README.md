# optimal_zfs_recordsize

A shell script for Linux that analyzes file size distribution on a directory and recommends ZFS `recordsize` settings for different workload types.

```bash
./optimal_zfs_recordsize.sh /path/to/dataset
```

## How it works

Pipes `find` directly into `gawk`, builds a space-weighted cumulative distribution function (CDF) and picks recordsize at three percentile thresholds:

- **P90** → Read-heavy (archives, media, backups)
- **P70** → Mixed / Unknown
- **P50** → Write-heavy sequential (downloads, rendering, compilation)

Also provides a reference table for random I/O workloads (databases, VMs) where file size ≠ I/O size.
For now this table is just a static one, it outputs general suggestion. Maybe in the future I will add a file type detection for databases we'll see.
Detects heavily skewed distributions and suggests dataset splits.

## Requirements

- Bash
- GNU Awk (`gawk`)
- GNU `find` with `-printf` support

## Example output

![output](https://raw.githubusercontent.com/subnetdusk/optimal_zfs_recordsize/assets/screenshot.jpg)
