# Load Monitoring Tool

This script provides a set of functionalities for monitoring system load and file/directories changes. It also cleans up created directories and files when not required anymore. Below is a detailed description of its usage and options.

## Usage
To download the script:

```bash
wget -O loadmonitoring.sh https://raw.githubusercontent.com/cloudlinux/tools/refs/heads/main/loadmonitoring/loadmonitoring.sh 
```

Then run it over bash:
```
bash loadmonitoring.sh [OPTION] [ARGUMENTS]
```

## **Options**  

### **General Options**
- `-h, --help`  
  Prints the help message with available options.

- `-c, --cleanup`  
  Deletes the script's created directories and files to clean up the environment.

### **Load Monitoring**
- `-l, --load-monitoring`  
  Starts monitoring system load and other load-related parameters. If the script was installed previously, the execution will be stopped to avoid removing custom configurations. This is the default behavior unless the "--override" tag is used.

  **Optional Arguments:**  
  - `-o, --override`  
    Overrides the existing script and cronjob. 
  - `-t, --threshold VALUE`  
    Allows manual setting of the load threshold for monitoring. If not provided, defaults to 75% of CPU core count.  

### **File Monitoring**
- `-f, --file-monitoring FILE/DIRECTORY`  
  Monitors changes to a specified file or directory. 


## How it works

The script starts by checking if it's running on a compatible system (RHEL or Debian based), then sets the logging directories. For the `--load-monitoring` option, it checks if there's enough space on the partition, creates the actual load monitoring script based on a template (getstats) and sets the respective cronjob. If load average is greater or equal to load threshold, it triggers the additional stats' collection. The `--file-monitoring` option is relatively simple and uses auditctl to monitor files/directories.


### Error Handling
- If an unrecognized option is provided, the script will display an error message and the help text.
- If the `-f` or `--file-monitoring` option is missing its required argument, the script will show an error message and terminate.
- The script has several safeguards to exit if there are issues during execution.
- The "--override" or "--threshold" must be use in conjuction with "--load-monitoring" or the script will not recognize them.

## Example Usage
1. Print help:
   ```bash
   bash loadmonitoring.sh --help
   ```

2. Monitor system load:
   ```bash
   bash loadmonitoring.sh --load-monitoring --override --threshold 5
   ```

3. Monitor changes to a file:
   ```bash
   bash loadmonitoring.sh --file-monitoring /etc/container/mysql-governor.xml
   ```

4. Cleanup files and directories created by the script:
   ```bash
   bash loadmonitoring.sh --cleanup
   ```
