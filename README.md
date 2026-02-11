# optimal_zfs_recordsize

A shell script for Linux that analyzes file size distribution on a directory and recommends ZFS `recordsize` settings for different workload types.

```bash
./optimal_zfs_recordsize.sh /path/to/dataset
```

## How it works

- Pipes `find` directly into `gawk`, builds a space-weighted cumulative distribution function (CDF):
- finds the bins where the CDF exceeds 50%, 70%, and 90%
- maps the _write-heavy_ _sequential_ case to the bin falling on 50 percentile; the _mixed_ case to P70; and the _read-heavy_ case to P90
- if 60% of files are smaller than 64KiB AND 80% of the total space is in files bigger than 1MiB, it concludes the CDF is __heavily__ __skewed__ and forces the _write-heavy_ _seq._ suggestion to 128K and the _mixed_ to 256K as compromise. An alert will be shown.
- if all 3 cases match the same suggestion, it will give just one
- in any case the _write-heavy_ _random_ _i/o_ will give _always_ the same suggestion: to match the application block size, not the file size. (For now this case outputs a statica suggestion, maybe in the future I will add a file type detection for databases, we'll see).

## Requirements

- Bash
- GNU Awk (`gawk`)
- GNU `find` with `-printf` support

## Example output

![output](https://raw.githubusercontent.com/subnetdusk/optimal_zfs_recordsize/assets/screenshot.jpg)
