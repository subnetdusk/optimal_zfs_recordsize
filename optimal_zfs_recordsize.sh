#!/bin/bash

# optimal_zfs_recordsize.sh v1.1
# Analyzes file size distribution and provides ZFS recordsize recommendations
# for all workload types (read-heavy, write-heavy, balanced).

# --- Script Setup and Validation ---
set -e
set -o pipefail

command -v gawk >/dev/null 2>&1 || {
    echo "Error: 'gawk' (GNU Awk) is required but not found. Please install it." >&2
    exit 1
}

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <path_to_directory>"
    exit 1
fi

TARGET_DIR="$1"

if [ ! -d "$TARGET_DIR" ]; then
    echo "Error: '$TARGET_DIR' is not a valid directory." >&2
    exit 1
fi

echo "Analyzing files in: $TARGET_DIR"
echo ""

# Estimate max files via inode count.
# Falls back to find | wc -l on filesystems where df reports iused=0 (Btrfs).
TOTAL_ESTIMATE=$(/usr/bin/df --output=iused "$TARGET_DIR" 2>/dev/null | tail -1)

if (( TOTAL_ESTIMATE <= 0 )) 2>/dev/null; then
    printf "Counting files (no inode estimate available)...\n" >&2
    TOTAL_ESTIMATE=$(find "$TARGET_DIR" -type f | wc -l)
fi

printf "Assume analyzing entire dataset of %d inodes.\n" "$TOTAL_ESTIMATE" >&2
printf "(If analyzing a subdir of ZFS dataset, estimate will be conservative!)\n\n" >&2

# --- Main Logic: find pipes directly to gawk (no bash loop) ---
/usr/bin/find -O3 "$TARGET_DIR" -type f -printf "%s\n" | /usr/bin/gawk -v total_est="$TOTAL_ESTIMATE" '

BEGIN {
    bins[0]  = 512;
    bins[1]  = 1024;
    bins[2]  = 2048;
    bins[3]  = 4096;
    bins[4]  = 8192;
    bins[5]  = 16384;
    bins[6]  = 32768;
    bins[7]  = 65536;
    bins[8]  = 131072;
    bins[9]  = 262144;
    bins[10] = 524288;
    bins[11] = 1048576;
    bins[12] = 2097152;
    bins[13] = 4194304;
    bins[14] = 8388608;
    bins[15] = 16777216;
    bins[16] = 33554432;
    bins[17] = 67108864;
    bins[18] = 134217728;
    bins[19] = 268435456;
    bins[20] = 536870912;
    bins[21] = 1073741824;

    num_bins = 22;

    C_GREEN  = "\033[32m";
    C_YELLOW = "\033[33m";
    C_BRYELLOW = "\033[93m";
    C_RED    = "\033[31m";
    C_BOLD   = "\033[1m";
    C_RESET  = "\033[0m";

    DSEP  = "-----------------------------------------------------------------------------------------------";
    IDSEP = "---------------------------------------------------------------------------------------------";

    bar_width = 48;
    update_every = 727;
    bar_block = "\342\226\210";

    for (i = 0; i < num_bins; i++) {
        counts[i] = 0;
        total_size[i] = 0;
    }
    large_count = 0;
    large_size = 0;
    total_files = 0;
    total_bytes = 0;
}

function hr(bytes,    suffix, tier) {
    if (bytes == 0) return "0 B";
    split("B KiB MiB GiB TiB PiB", suffix, " ");
    tier = 0;
    while (bytes >= 1024 && tier < 5) {
        bytes /= 1024;
        tier++;
    }
    return sprintf("%.1f %s", bytes, suffix[tier+1]);
}

function format_bin_name(bin_value) {
    return "<= " hr(bin_value);
}

function to_zfs_recordsize(bytes) {
    if (bytes <= 4096)   return "4k";
    if (bytes <= 8192)   return "8k";
    if (bytes <= 16384)  return "16k";
    if (bytes <= 32768)  return "32k";
    if (bytes <= 65536)  return "64k";
    if (bytes <= 131072) return "128k";
    if (bytes <= 262144) return "256k";
    if (bytes <= 524288) return "512k";
    return "1M";
}

# Find the bin index where cumulative space >= threshold
function find_percentile(thresh,    cum, i) {
    cum = 0;
    for (i = 0; i < num_bins; i++) {
        cum += total_size[i];
        if (total_bytes > 0 && (cum / total_bytes) >= thresh) {
            return i;
        }
    }
    return num_bins; # overflow
}

function rec_from_bin(bin_idx) {
    if (bin_idx >= num_bins) return "1M";
    if (bins[bin_idx] < 4096) return "4k";
    return to_zfs_recordsize(bins[bin_idx]);
}

{
    size = $1;
    total_files++;
    total_bytes += size;

    # Progress bar (every N files, print to stderr)
    if (total_files % update_every == 0 && total_est > 0) {
        pct = int(total_files * 100 / total_est);
        if (pct > 100) pct = 100;
        filled = int(pct * bar_width / 100);
        empty = bar_width - filled;
        bar = "";
        for (b = 0; b < filled; b++) bar = bar bar_block;
        printf "\r|%-*s%*s|%3d%% Processed: %d   ", \
            filled, bar, empty, "", pct, total_files > "/dev/stderr";
        fflush("/dev/stderr");
    }

    matched = 0;
    for (i = 0; i < num_bins; i++) {
        if (size <= bins[i]) {
            counts[i]++;
            total_size[i] += size;
            matched = 1;
            break;
        }
    }
    if (matched == 0) {
        large_count++;
        large_size += size;
    }
}

END {
    if (total_files == 0) {
        print "No files found in the specified directory.";
        exit;
    }

    # Final progress bar: 100% DONE
    bar = "";
    for (b = 0; b < bar_width; b++) bar = bar bar_block;
    printf "\r|%s|100%% DONE!               \n", bar > "/dev/stderr";
    fflush("/dev/stderr");

    printf "\nProcessed %s files! Generating report...\n", total_files;

    # --- 1. Side-by-side Visual Histograms ---
    max_s = large_size;
    max_c = large_count;
    for (i = 0; i < num_bins; i++) {
        if (total_size[i] > max_s) max_s = total_size[i];
        if (counts[i] > max_c) max_c = counts[i];
    }

    bar_char = bar_block;
    bw = 35; # bar width per side

    printf "\nHistograms\n";
    print DSEP;
    printf "  %-15s  %-35s  %s\n", "", "by total size", "by file count";
    print DSEP;
    for (i = 0; i < num_bins; i++) {
        # Left bar: by size
        if (counts[i] > 0 && max_s > 0) {
            bl = int((total_size[i] / max_s) * bw + 0.5);
            if (bl < 1) bl = 1;
            pct = (total_size[i] / max_s) * 100;
            col = C_RED;
            if (pct > 66) col = C_GREEN;
            else if (pct > 33) col = C_YELLOW;
        } else { bl = 0; col = ""; }
        lbar = ""; for (b = 0; b < bl; b++) lbar = lbar bar_char;
        lpad = ""; for (b = bl; b < bw; b++) lpad = lpad " ";

        # Right bar: by count
        if (counts[i] > 0 && max_c > 0) {
            br = int((counts[i] / max_c) * bw + 0.5);
            if (br < 1) br = 1;
            pct = (counts[i] / max_c) * 100;
            cor = C_RED;
            if (pct > 66) cor = C_GREEN;
            else if (pct > 33) cor = C_YELLOW;
        } else { br = 0; cor = ""; }
        rbar = ""; for (b = 0; b < br; b++) rbar = rbar bar_char;

        if (bl > 0 || br > 0)
            printf "  %-15s |%s%s%s%s |%s%s%s\n", \
                format_bin_name(bins[i]), col, lbar, C_RESET, lpad, cor, rbar, C_RESET;
        else
            printf "  %-15s |%*s |%s\n", format_bin_name(bins[i]), bw, "", "";
    }
    # Overflow bin
    if (large_count > 0) {
        bl = (max_s > 0) ? int((large_size / max_s) * bw + 0.5) : 0;
        if (bl < 1) bl = 1;
        lbar = ""; for (b = 0; b < bl; b++) lbar = lbar bar_char;
        lpad = ""; for (b = bl; b < bw; b++) lpad = lpad " ";

        br = (max_c > 0) ? int((large_count / max_c) * bw + 0.5) : 0;
        if (br < 1) br = 1;
        rbar = ""; for (b = 0; b < br; b++) rbar = rbar bar_char;
        pct_c = (max_c > 0) ? (large_count / max_c) * 100 : 0;
        cor = C_RED;
        if (pct_c > 66) cor = C_GREEN;
        else if (pct_c > 33) cor = C_YELLOW;

        printf "  %-15s |%s%s%s%s |%s%s%s\n", \
            "> " hr(bins[num_bins-1]), C_GREEN, lbar, C_RESET, lpad, cor, rbar, C_RESET;
    }
    print "";

    # ===========================================================
    # --- 2. Compute all three percentiles ---
    # ===========================================================

    p50_bin = find_percentile(0.50);
    p70_bin = find_percentile(0.70);
    p90_bin = find_percentile(0.90);

    rec_write = rec_from_bin(p50_bin);
    rec_mixed = rec_from_bin(p70_bin);
    rec_read  = rec_from_bin(p90_bin);

    # Precompute CDF for table
    cumulative = 0;
    for (i = 0; i < num_bins; i++) {
        cumulative += total_size[i];
        cum_pct[i] = (total_bytes > 0) ? (cumulative / total_bytes) * 100 : 0;
    }
    cumulative += large_size;
    cum_pct_large = (total_bytes > 0) ? (cumulative / total_bytes) * 100 : 0;

    # --- Skewness detection ---
    # A heavily right-skewed distribution has most files concentrated
    # in small sizes (by count) while most space is in the right tail
    # (large files). The two metrics point to opposite recordsizes.
    small_file_count = 0;
    small_file_size = 0;
    for (i = 0; i <= 7; i++) {
        small_file_count += counts[i];
        small_file_size += total_size[i];
    }
    small_pct_count = (total_files > 0) ? (small_file_count / total_files) * 100 : 0;

    big_file_size = 0;
    big_file_count = 0;
    for (i = 12; i < num_bins; i++) {
        big_file_size += total_size[i];
        big_file_count += counts[i];
    }
    big_file_size += large_size;
    big_file_count += large_count;
    big_pct_space = (total_bytes > 0) ? (big_file_size / total_bytes) * 100 : 0;

    is_skewed = 0;
    if (small_pct_count > 60 && big_pct_space > 80) {
        is_skewed = 1;
    }

    # --- Skewed overrides for write and mixed ---
    if (is_skewed) {
        rec_write = "128k";
        rec_mixed = "256k";
        # rec_read stays as-is (no RMW penalty on reads)
    }

    # ===========================================================
    # --- 3. Merged Table ---
    # ===========================================================

    print "\nData Table";
    print DSEP;
    printf "  %-15s %10s %8s %12s %8s %9s\n", \
        "Size Range", "Files", "% Files", "Total Size", "% Space", "% Cumul.";
    print "  " IDSEP;

    for (i = 0; i < num_bins; i++) {
        if (counts[i] > 0) {
            pct_count = (total_files > 0) ? (counts[i] / total_files) * 100 : 0;
            pct_space = (total_bytes > 0) ? (total_size[i] / total_bytes) * 100 : 0;

            cum_color = C_RED;
            if (cum_pct[i] >= 70) cum_color = C_GREEN;
            else if (cum_pct[i] >= 50) cum_color = C_YELLOW;

            printf "  %-15s %10d %7.1f%% %12s %7.1f%% %s%8.1f%%%s\n", \
                format_bin_name(bins[i]), counts[i], pct_count, \
                hr(total_size[i]), pct_space, cum_color, cum_pct[i], C_RESET;
        }
    }

    if (large_count > 0) {
        pct_count = (total_files > 0) ? (large_count / total_files) * 100 : 0;
        pct_space = (total_bytes > 0) ? (large_size / total_bytes) * 100 : 0;

        cum_color = C_RED;
        if (cum_pct_large >= 70) cum_color = C_GREEN;
        else if (cum_pct_large >= 50) cum_color = C_YELLOW;

        printf "  %-15s %10d %7.1f%% %12s %7.1f%% %s%8.1f%%%s\n", \
            "> " hr(bins[num_bins-1]), large_count, pct_count, \
            hr(large_size), pct_space, cum_color, cum_pct_large, C_RESET;
    }

    print "  " IDSEP;
    printf "  %-15s %10d          %12s\n", "TOTAL", total_files, hr(total_bytes);

    # ===========================================================
    # --- 4. Recommendations ---
    # ===========================================================

    printf "\n%sRecommendations%s\n", C_BOLD, C_RESET;
    print DSEP;

    if (rec_read == rec_write && rec_write == rec_mixed) {
        printf "  %sAll sequential workloads agree:  recordsize=%s%s\n\n", C_BOLD, rec_read, C_RESET;
        print  "  Read-heavy, mixed, and sequential write workloads all point to the same value.";
        printf "\n  > zfs set recordsize=%s <pool>/<dataset>\n", rec_read;

    } else {
        printf "  %sRead-heavy:              recordsize=%-5s%s  (space P90: optimize for data volume)\n", \
            C_BOLD, rec_read, C_RESET;
        print  "    Media libraries, backups, archives, static data.";
        print  "    Small files use variable-size blocks, no penalty on reads.\n";
        printf "  %sMixed / Unknown:         recordsize=%-5s%s  (space P70: balanced)\n", \
            C_BOLD, rec_mixed, C_RESET;
        print  "    Mixed or uncertain workload. Middle ground.\n";
        printf "  %sWrite-heavy (seq.):      recordsize=%-5s%s  (space P50: whole-file writes)\n", \
            C_BOLD, rec_write, C_RESET;
        print  "    Downloads, rendering, compilation, log rotation.";
        print  "    I/O size matches file size, protect against RMW on bulk data.";
    }

    printf "\n  %sWrite-heavy (random I/O):%s  match your application block size\n", C_BOLD, C_RESET;
    print  "    When I/O is much smaller than file size, recordsize must match the";
    print  "    application block size, not the file size. Suggested values:\n";
    print  "      PostgreSQL ......... 8k       MySQL/InnoDB ........ 16k";
    print  "      SQLite ............. 4k       MongoDB (WiredTiger). 4k";
    print  "      VM disk images ..... 4k-16k   BitTorrent .......... 16k";
    print  "      Elasticsearch ...... 4k       Redis (AOF) ......... 4k";

    # --- Skewed distribution warning ---
    if (is_skewed) {
        printf "\n%s\n%s%sHeavily Skewed Distribution%s\n", C_RESET, C_BRYELLOW, C_BOLD, C_RESET;
        printf "%s", C_BRYELLOW;
        print  DSEP;
        printf "  File count is concentrated in small files (%.0f%% of files are <= 64 KiB)\n", small_pct_count;
        printf "  while data volume is concentrated in large files (%.0f%% of space is in files > 1 MiB).\n", big_pct_space;
        print  "  The two metrics point to opposite recordsizes, so a single value is always";
        print  "  a compromise. The write-heavy and mixed recommendations have been adjusted";
        print  "  downward to protect small-file write performance.";

        # Compute small-file mode for split suggestion
        small_mode_count = 0;
        small_mode_bin = 0;
        for (i = 0; i <= 7; i++) {
            if (counts[i] > small_mode_count) {
                small_mode_count = counts[i];
                small_mode_bin = i;
            }
        }
        small_rec = to_zfs_recordsize(bins[small_mode_bin]);

        print  "";
        print  "  If possible, split into separate ZFS datasets:";
        print  "";
        printf "    > zfs create -o recordsize=1M    pool/data/large_files\n";
        printf "    > zfs create -o recordsize=%-5s pool/data/small_files\n", small_rec;
    }

    printf "\n%s%s\n", C_RESET, DSEP;
    print "NOTE: These are suggestions based on file size distribution.\n      Always benchmark your specific workload.";
}
'
