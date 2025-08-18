
# optimal_zfs_recordsize.sh  
  
A shell script that analyzes the file size distribution within a given directory to provide an intelligent ZFS `recordsize` recommendation. It helps you make an informed decision by visualizing the data and understanding the trade-offs between different record sizes for your specific workload.  
  
## Features  
  
- **Detailed Statistics:** Generates a table showing the number of files and the total data volume within various size ranges (from <= 512 B to > 16 MiB).  
- **Dual Histograms:** Provides two easy-to-read visual histograms to help you understand the data distribution at a glance:  
	- **By **total data size** in each bin.  
	- **By **total file count** in each bin.  
- **Intelligent Recommendation Engine:** Goes beyond simple analysis to provide a concrete `recordsize` suggestion based on a nuanced understanding of different workload types.  
  
## Usage  
  
1. **Save the Script:** Save the script content as a file, for example, `optimal_zfs_recordsize.sh`.  
  
2. **Make it Executable:**  
```bash  
sudo chmod +x optimal_zfs_recordsize.sh  
```  
  
3. **Run the Analysis:** Provide the path to the directory you want to analyze as the only argument.  
```bash  
./file-size-stats.sh /path/to/your/dataset  
```  
  
## Understanding the Recommendation  
  
The script can identify three primary types of workloads:  
  
1. **Small/Medium File Workload:**  
- **Trigger:** The largest portion of data is in files smaller than 1 MiB.  
- **Recommendation:** A recordsize that matches the dominant file size (e.g., `32k`, `64k`, `128k`).  
- **Example:** A source code repository or a web server root.  
  
2. **Large-File Workload:**  
- **Trigger:** The data is overwhelmingly dominated by large files (e.g., > 1 MiB) in both volume and count.  
- **Recommendation:** An aggressive `1M` recordsize for maximum sequential performance.  
- **Example:** A Plex media library or a folder of virtual machine disk images.  
  
3. **Mixed Workload:**  
- **Trigger:** The data *volume* is in large files, but there is also a massive number of small files (e.g., > 40% of the count AND > 5000 files).  
- **Recommendation:** A safe, balanced `128k` to protect small-file I/O performance.  
- **Example:** A system backup directory containing both disk images and thousands of small configuration files.  
  
## Dependencies  
  
- `bash`  
- `gawk` (GNU Awk)  
  
## Disclaimer  
  
This tool provides a well-reasoned suggestion based on file size distribution. However, the optimal `recordsize` can also be influenced by other factors like database access patterns or I/O block alignment. Always benchmark your specific workload to confirm the best setting for your needs.
