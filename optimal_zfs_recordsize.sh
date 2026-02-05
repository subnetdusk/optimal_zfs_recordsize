#!/bin/bash

# A script to generate a file size histogram and provide an intelligent ZFS recordsize recommendation.

# --- Script Setup and Validation ---
set -e
set -o pipefail

# Check for gawk
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

# Estimate maximum possible number of files by reading no of inodes
# on underlying datastore which is hyper-conservative so we will tell user.

TOTAL_ESTIMATE=$(/usr/bin/df --output=iused $TARGET_DIR|tail -1)

# --- Main Logic via find and gawk ---
# The AWK script is passed as a command-line argument.
(
    FILE_COUNT=0
    BAR_WIDTH=48
    UPDATE_EVERY=727 # Increase this prime number if dealing with huge numbers of files

    printf "Assume analyzing entire dataset of %d inodes.\n" "$TOTAL_ESTIMATE" >&2
    printf "(If analyzing a subdir of dataset, estimate will be conservative!)\n\n" >&2

    /usr/bin/find -O3 "$TARGET_DIR" -type f -printf "%s\n" | while read -r size; do
        FILE_COUNT=$((FILE_COUNT + 1))
        if (( FILE_COUNT % UPDATE_EVERY == 0 )); then
            PERCENT=$(( FILE_COUNT * 100 / TOTAL_ESTIMATE ))

            printf "\r: %d" "$TOTAL_ESTIMATE" >&2

            # Update progress only occasionally
            FILLED=$(( PERCENT * BAR_WIDTH / 100 ))
            EMPTY=$(( BAR_WIDTH - FILLED ))

            printf "\r|%-*s%*s|%3d%% Processed: %d   " \
                "$FILLED" "$(printf '%*s' "$FILLED" | tr ' ' '|')" \
                "$EMPTY" "" \
                "$PERCENT" \
                "$FILE_COUNT" >&2
        fi
    echo "$size"
    done

    PERCENT=100
    FILLED=$BAR_WIDTH
    EMPTY=0
   
    printf "\r|%-*s%*s|%3d%% DONE!               " \
        "$FILLED" "$(printf '%*s' "$FILLED" | tr ' ' '|')" \
        "$EMPTY" "" \
        "$PERCENT" >&2


) | /usr/bin/gawk '

# --- AWK BEGIN Block: Initialization ---
BEGIN {
    # Define the file size bins (powers of 2)
    bins[0] = 512;       # 512 B
    bins[1] = 1024;      # 1 KiB
    bins[2] = 2048;      # 2 KiB
    bins[3] = 4096;      # 4 KiB
    bins[4] = 8192;      # 8 KiB
    bins[5] = 16384;     # 16 KiB
    bins[6] = 32768;     # 32 KiB
    bins[7] = 65536;     # 64 KiB
    bins[8] = 131072;    # 128 KiB (ZFS Default Recordsize)
    bins[9] = 262144;    # 256 KiB
    bins[10] = 524288;   # 512 KiB
    bins[11] = 1048576;  # 1 MiB
    bins[12] = 4194304;  # 4 MiB
    bins[13] = 8388608;  # 8 MiB
    bins[14] = 16777216; # 16 MiB

    num_bins = 15; # Total number of bins from index 0 to 14

    # ANSI color codes for the gradient
    C_GREEN = "\033[32m";
    C_YELLOW = "\033[33m";
    C_RED = "\033[31m";
    C_RESET = "\033[0m";

    # Initialize arrays
    for (i = 0; i < num_bins; i++) {
        counts[i] = 0;
        total_size[i] = 0;
    }
    large_count = 0;
    large_size = 0;
    total_files = 0;
    total_bytes = 0;
}

# --- AWK Functions ---
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

# --- AWK Main Block: Process each file size from find ---
{
    size = $1;
    total_files++;
    total_bytes += size;

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

# --- AWK END Block: Print reports and recommendation ---
END {
    if (total_files == 0) {
        print "No files found in the specified directory.";
        exit;
    }

    # Final progress output here to avoid subshell isolation to get total
    printf "\n\nProcessed %s files! Generating report...\n\n", total_files;

    # --- 1. Detailed Statistics Table ---
    print "=======================================================";
    print "              File Size Distribution";
    print "=======================================================";
    printf "%-15s %15s %15s\n", "Size Range", "File Count", "Total Size";
    print "-------------------------------------------------------";

    for (i = 0; i < num_bins; i++) {
        if (counts[i] > 0) {
            printf "%-15s %15d %15s\n", format_bin_name(bins[i]), counts[i], hr(total_size[i]);
        }
    }

    if (large_count > 0) {
        printf "%-15s %15d %15s\n", "> " hr(bins[num_bins-1]), large_count, hr(large_size);
    }

    print "-------------------------------------------------------";
    printf "%-15s %15d %15s\n", "TOTAL", total_files, hr(total_bytes);
    print "=======================================================\n";

    # --- 2. Visual Histograms ---
    max_s = large_size;
    max_c = large_count;
    for (i = 0; i < num_bins; i++) {
        if (total_size[i] > max_s) max_s = total_size[i];
        if (counts[i] > max_c) max_c = counts[i];
    }

    bar_char = "█";

    print "Visual Histogram (by total size in each bin)";
    print "-------------------------------------------------------";
    for (i = 0; i < num_bins; i++) {
        bar_len = (max_s > 0) ? (total_size[i] / max_s) * 50 : 0;
        if (total_size[i] > 0 && bar_len < 1) bar_len = 1;
        bar = sprintf("%*s", int(bar_len + 0.5), ""); gsub(/ /, bar_char, bar);
        
        percentage = (max_s > 0) ? (total_size[i] / max_s) * 100 : 0;
        color = C_RED;
        if (percentage > 66) color = C_GREEN;
        else if (percentage > 33) color = C_YELLOW;
        
        printf "%-15s |%s%s%s\n", format_bin_name(bins[i]), color, bar, C_RESET;
    }
    if (large_size > 0) {
        bar_len = (max_s > 0) ? (large_size / max_s) * 50 : 0;
        if (large_size > 0 && bar_len < 1) bar_len = 1;
        bar = sprintf("%*s", int(bar_len + 0.5), ""); gsub(/ /, bar_char, bar);
        printf "%-15s |%s%s%s\n\n", "> " hr(bins[num_bins-1]), C_GREEN, bar, C_RESET; # Largest is always green
    } else { print "" }


    print "Visual Histogram (by number of files in each bin)";
    print "-------------------------------------------------------";
    for (i = 0; i < num_bins; i++) {
        bar_len = (max_c > 0) ? (counts[i] / max_c) * 50 : 0;
        if (counts[i] > 0 && bar_len < 1) bar_len = 1;
        bar = sprintf("%*s", int(bar_len + 0.5), ""); gsub(/ /, bar_char, bar);

        percentage = (max_c > 0) ? (counts[i] / max_c) * 100 : 0;
        color = C_RED;
        if (percentage > 66) color = C_GREEN;
        else if (percentage > 33) color = C_YELLOW;

        printf "%-15s |%s%s%s\n", format_bin_name(bins[i]), color, bar, C_RESET;
    }
    if (large_count > 0) {
        bar_len = (max_c > 0) ? (large_count / max_c) * 50 : 0;
        if (large_count > 0 && bar_len < 1) bar_len = 1;
        bar = sprintf("%*s", int(bar_len + 0.5), ""); gsub(/ /, bar_char, bar);

        percentage = (max_c > 0) ? (large_count / max_c) * 100 : 0;
        color = C_RED;
        if (percentage > 66) color = C_GREEN;
        else if (percentage > 33) color = C_YELLOW;

        printf "%-15s |%s%s%s\n\n", "> " hr(bins[num_bins-1]), color, bar, C_RESET;
    } else { print "" }

    # --- 3. Intelligent Recordsize Recommendation ---
    print "=======================================================";
    print "            ZFS Recordsize Recommendation";
    print "=======================================================";

    max_data_in_bin = 0;
    suggested_bin_index = -1;
    for (i = 0; i < num_bins; i++) {
        if (total_size[i] > max_data_in_bin) {
            max_data_in_bin = total_size[i];
            suggested_bin_index = i;
        }
    }
    if (large_size > max_data_in_bin) {
        suggested_bin_index = num_bins; # Special index for "large"
    }

    small_file_count = 0;
    for (i = 0; i <= 7; i++) { # Sum counts for all bins <= 64 KiB
        small_file_count += counts[i];
    }
    small_file_count_percentage = (total_files > 0) ? (small_file_count / total_files) * 100 : 0;

    if (suggested_bin_index >= 11) {
        if (small_file_count_percentage > 40 && small_file_count > 5000) {
            print "  This is a MIXED WORKLOAD. The data volume is in large files,";
            print "  but there is also a very high number of small files.";
            printf("  (%.0f%% of files, numbering over %d, are 64 KiB or smaller).\n\n", small_file_count_percentage, small_file_count);
            print "  RECOMMENDATION: Use the default 128k recordsize.";
            print "  This provides the best balance, protecting the performance of tens of";
            print "  thousands of small files from read-modify-write penalties.";
            print "\n  > zfs set recordsize=128k <pool>/<dataset>";

        } else {
            print "  This is a LARGE FILE WORKLOAD. The data is dominated by large, sequential files.";
            print "  While some small metadata files may exist, their number is not significant";
            print "  enough to compromise on optimizing for the vast majority of the data.\n";
            print "  RECOMMENDATION: Use a 1M recordsize.";
            print "  This reduces metadata overhead and provides peak performance for sequential I/O.";
            print "\n  > zfs set recordsize=1M <pool>/<dataset>";
        }
    }
    else {
        suggested_size_bytes = bins[suggested_bin_index];
        print "  This is a SMALL/MEDIUM FILE WORKLOAD. ";
        print "  Your data distribution is dominated by files in the " hr(suggested_size_bytes) " range.\n";
        print "  RECOMMENDATION: Match the recordsize to this dominant file size.";
        print "  This provides a good balance of performance and storage efficiency for";
        print "  your specific workload.";
        printf("\n  > zfs set recordsize=%dk <pool>/<dataset>\n", suggested_size_bytes / 1024);
    }
    print "=======================================================";
    print "NOTE: This is a suggestion. Always benchmark your specific workload.";
}
'