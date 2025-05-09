#!/bin/bash

# Ensure the script is running with Bash.
if [ "$(ps -p $$ -o comm=)" != "bash" ]; then
    exec /bin/bash "$0" "$@"
fi

STATUS_DIR="/var/log"
SERVER_STATUS_DIR="$STATUS_DIR/server-status"
SCRIPT_DIR="/usr/local/bin"
PKG_MANAGER=""
SYSSTAT_DIR=""
LOAD_MONITORING_OVERRIDE=false
LOAD_THRESHOLD=""

## Function to better format the messages
colored_echo() {
    local color_reset="\033[0m"
    local color_red="\033[31m"
    local color_green="\033[32m"

    if [ "$1" == "green" ]; then
        echo -e "${color_green}$2${color_reset}"
    elif [ "$1" == "red" ]; then
        echo -e "${color_red}$2${color_reset}"
    else
        echo -e "$2"
    fi
}

## Function to verify if system is supported ##
check_system() {
    if ! grep -iE "(ubuntu)|(debian)|(rhel)|(fedora)" /etc/*-release >/dev/null 2>&1; then
        colored_echo red "OS is unsupported. Supported systems:\n- Debian-based\n- RHEL-based"
        exit 1
    fi

    if grep -iE "(ubuntu)|(debian)" /etc/*-release >/dev/null 2>&1; then
        echo -e "Debian-based system detected\n"
        PKG_MANAGER="/usr/bin/apt"
        SYSSTAT_DIR=$(dpkg -L sysstat | grep "log\/sysstat" | head -n1)
    else
        echo -e "RHEL-based system detected\n"
        PKG_MANAGER="/usr/bin/yum"
        SYSSTAT_DIR=$(rpm -ql sysstat | grep "/var" | head -n1)
    fi

}

## Function to install the audit package if needed ##
install_audit() {
    echo "auditctl not found. Installing the audit package..."
    
    if ! $PKG_MANAGER -y install audit && ! $PKG_MANAGER -y install auditd; then
        colored_echo red "\nError: Unable to install the audit package. Please check manually."
        exit 1
    fi

    systemctl enable auditd
    systemctl start auditd
    echo -e "\nAudit package successfully installed.\n"
}

### Initial data gathering and logging ###
set_up_logging() {
    LOGFILE="$SERVER_STATUS_DIR/initial_setup_report.log"
    mkdir -pv "$SERVER_STATUS_DIR"
    mv -f "$LOGFILE"{,.old} &>/dev/null
}

## Load monitoring function ##
load_monitoring() {

    check_system

    ### Checking space availability ###
    check_space() {
        local path="$1"
        available_space=$(df --output=avail -BG "$path" | tail -1 | tr -d 'G ')

        if [[ $available_space -lt 5 ]]; then
            return 1
        else
            return 0
        fi
    }

    echo "Checking available space on $STATUS_DIR..."
    if ! check_space "$STATUS_DIR"; then
        echo "Less than 5GB available on $STATUS_DIR."
        while true; do
            read -rp "Please provide another path with sufficient space (or press Enter to stop): " new_path
            if [[ -z "$new_path" ]]; then
                colored_echo red "No path provided. Exiting."
                exit 1
            elif [[ -d "$new_path" ]]; then
                if check_space "$new_path"; then
                    echo "Sufficient space is available on $new_path."
                    STATUS_DIR="$new_path"
                    break
                else
                    echo "Less than 5GB available on $new_path. Please try again."
                fi
            else
                echo "The provided path does not exist. Please try again."
            fi
        done
    fi
    echo -e "Proceeding.\n"

    ### Checking for legacy or existing versions ###
    legacy_file="/var/log/server-status/getstats.sh"
    if [[ -f "$legacy_file" ]]; then
        rm -fv "$legacy_file"
        echo -e "Removed legacy version: $legacy_file\n"
    fi

    if [[ -f "/usr/local/bin/getstats" ]]; then
        if [[ "${LOAD_MONITORING_OVERRIDE:-false}" == false ]]; then
            colored_echo red "Warning: /usr/local/bin/getstats exists."
            colored_echo red "Use -o or --override to bypass this check."
            exit 1
        else
            echo -e "Existing /usr/local/bin/getstats file will be overwritten.\n"
        fi
    fi

    set_up_logging
    exec > >(tee -a "$LOGFILE") 2>&1

    ### General info ###
    CPU_CORES=$(grep -c ^processor /proc/cpuinfo)
    echo "CPU cores: $CPU_CORES"
    TOTAL_MEMORY=$(free -mht | grep Mem | awk '{print $2}')
    echo "Total memory: $TOTAL_MEMORY"

    if [[ -z "$LOAD_THRESHOLD" ]]; then
        LOAD_THRESHOLD=$(((CPU_CORES * 3) / 4))
    fi

    ### Load averages from the past 2 weeks ###
    echo -e "\nSaving load averages from the past 2 weeks for reference...\n"
    if rpm -q --quiet sysstat &>/dev/null || dpkg-query -l sysstat &>/dev/null; then
        load_avg_files=$(ls -t "$SYSSTAT_DIR" | grep '^sa[0-9][0-9]$' | head -n 14)
        printf "%-10s %-10s %-10s %-10s\n" "ldavg-1" "ldavg-5" "ldavg-15" "Day"
        for file in $load_avg_files; do
            sar -q -f "$SYSSTAT_DIR/$file" | awk -v file="$file" '
    BEGIN {
        # Extract the day number directly from the filename
        day = substr(file, 3, 2)
    }
    /^Average/ {
        printf "%-10s %-10s %-10s %-10s\n", $4, $5, $6, day
    }'
        done 2>/dev/null
    else
        echo -e "Systat package not installed, skipping...\n"
    fi

    echo
    rm -fv "$SCRIPT_DIR"/getstats

    ### Getstats template ###
    cat <<EOF >"$SCRIPT_DIR"/getstats
#!/bin/bash

DATE=\$(date +%Y-%m-%d-%s)
SCRIPT_LOGFILE=$SERVER_STATUS_DIR/\$DATE/monitoring_script.log 
exec > >(tee -a "\$SCRIPT_LOGFILE") 2>&1

### Check if direction to store log exists, if doesn't - create it ###
if [ ! -d $SERVER_STATUS_DIR/"\$DATE" ]; then 
    mkdir -pv $SERVER_STATUS_DIR/"\$DATE" 
fi

### Function to gather site statistics when needed ###
get_site_statistics() {

    DB_AUTH=""

    if [[ -f "/usr/local/cpanel/cpanel" ]]; then
        echo -e "\n!-------------------------------------------- Number of requests by domain:" ; /usr/bin/find /usr/local/apache/domlogs/ -maxdepth 1 -type f | xargs grep "\$(date +%d/%b/%Y)" | awk '{print \$1}' | cut -d':' -f1 | sort | uniq -c | sort -n | tail -n5; echo; echo "!-------------------------------------------- IPs with most requests:";/usr/bin/find /usr/local/apache/domlogs/ -maxdepth 1 -type f | xargs grep "\$(date +%d/%b/%Y)" | awk '{print \$1}'|cut -d':' -f2|sort | uniq -c | sort -n | tail 

        echo -e "\n !---------------------------- mysqladmin processlist"
        /usr/bin/mysqladmin processlist -v 

    elif [[ -f "/usr/local/psa/version"  ]]; then
        echo -e "\n!-------------------------------------------- Number of requests by domain:"; for domain_log in /var/www/vhosts/system/*/; do
            domain_name=\$(echo "\$domain_log" | cut -d "/" -f 6 )
            echo -ne "\$domain_name\n"
            /usr/bin/find "\$domain_log"/logs -maxdepth 1 -name "access*log" -type f | xargs grep "\$(date +%d/%b/%Y)" | awk '{print \$1}' | cut -d':' -f1 | sort | uniq -c | sort -n | tail -n5; 
            echo
        done 
        echo "!-------------------------------------------- IPs with most requests:"; for domain_log in /var/www/vhosts/system/*/; do
            /usr/bin/find "\$domain_log"/logs -maxdepth 1 -name "access*log" -type f | xargs grep "\$(date +%d/%b/%Y)" | awk '{print \$1}' | cut -d':' -f2 | sort | uniq -c | sort -n | tail 
            echo
        done

        echo -e "\n !---------------------------- mysqladmin processlist"
        DB_AUTH="-uadmin -p\$(cat /etc/psa/.psa.shadow)"
        /usr/bin/mysqladmin \$DB_AUTH processlist -v 

    elif [[ -f "/usr/local/directadmin/directadmin" ]]; then
        echo -e "\n!-------------------------------------------- Number of requests by domain:" ; /usr/bin/find /var/log/httpd/domains/ -maxdepth 1 -type f | xargs grep "\$(date +%d/%b/%Y)" | awk '{print \$1}' | cut -d':' -f1 | sort | uniq -c | sort -n | tail -n5; echo; echo "!-------------------------------------------- IPs with most requests:";/usr/bin/find /var/log/httpd/domains/ -maxdepth 1 -type f | xargs grep "\$(date +%d/%b/%Y)" | awk '{print \$1}'|cut -d':' -f2|sort | uniq -c | sort -n | tail 

        echo -e "\n !---------------------------- mysqladmin processlist"
        DB_AUTH="-uda_admin -p\$(grep -oP 'password="\K[^"]+' /usr/local/directadmin/conf/my.cnf)"
        /usr/bin/mysqladmin \$DB_AUTH processlist -v 
    else
        echo 'Unable to get domain stats'
    fi 
}

### Add blank line and head 5 of top on every script run ###
echo
echo "!-------------------------------------------- top 20"
COLUMNS=512 /usr/bin/top -cSb -n 1 | head -20                         

echo "!---------------------------------------- vmstat 1 4"
/usr/bin/vmstat 1 4                                        

### Check if load average is greater or equal than load threshold (by default, it's 75% of CPU core count). If it does - collects needed stats ###
one_minute_load_avg=\$(awk '{print int(\$1)}' /proc/loadavg)
if [[ "\$one_minute_load_avg" -ge $LOAD_THRESHOLD ]]; then

    echo "!---------------------------------- netstat by state"
    /bin/netstat -an|awk '/tcp/ {print \$6}'|sort|uniq -c       

    echo "!-------------------------------- ps by memory usage"
    ps aux | sort -nk +4 | tail                                

    echo "!------------------------------------- iotop -b -n 3"
    /usr/sbin/iotop -b -o -n 3                                 

    echo "!------------------------------------------- ps axuf"
    ps axuf                                                    

    get_site_statistics                        

fi

### Removing directories older then 15 days ###
/usr/bin/find $SERVER_STATUS_DIR -maxdepth 1 -mindepth 1 -type d -ctime +15 -print0 | xargs -0 rm -rf

EOF

    ### Making the script executable ###
    if [ -f "$SCRIPT_DIR"/getstats ]; then
        chmod +x "$SCRIPT_DIR"/getstats
        echo -e "\nScript $SCRIPT_DIR/getstats created and made executable."
    else
        colored_echo red "\nError: Failed to create the getstats script!"
        exit 1
    fi

    ### Installing cron task ###
    existing_dirs=$(find "$SERVER_STATUS_DIR" -name "20*" -type d 2>/dev/null)
    echo "* * * * * root /usr/bin/flock -n /var/run/cloudlinux_getstats.cronlock /bin/bash $SCRIPT_DIR/getstats >/dev/null 2>&1 " >/etc/cron.d/getstats
    echo -e "\nCronjob installed.\n"

    ### Verification ###
    echo -e "\nWaiting for the cron job to run..."
    SECONDS=0
    SPINNER=("-" "\\" "|" "/") # Spinner animation
    SPINNER_INDEX=0

    while ((SECONDS < 120)); do
        new_dirs=$(find "$SERVER_STATUS_DIR" -name "20*" -type d 2>/dev/null)

        for dir in $new_dirs; do
            if ! grep -q "$dir" <<<"$existing_dirs"; then
                echo -e "\nCronjob successfully verified.\n\n* The actions just performed were logged at $SERVER_STATUS_DIR/initial_setup_report.log for future reference.\n* Getstats script saved at $SCRIPT_DIR/getstats.\n* Logs saved at $SERVER_STATUS_DIR."
                colored_echo green "\n\nSetup completed."
                exit 0
            fi
        done

        printf "\rChecking cron job status... %s" "${SPINNER[$SPINNER_INDEX]} "
        SPINNER_INDEX=$(((SPINNER_INDEX + 1) % 4))

        sleep 1
    done

    colored_echo red "\n\nThe addition of the cronjob timed out after 120 seconds. Please check manually the /etc/cron.d directory."
    exit 1

}

## File monitoring function ##
file_monitoring() {
    check_system
    set_up_logging

    if ! command -v /usr/sbin/auditctl &>/dev/null; then
        install_audit
    else
        echo -e "\nAudit package is already installed.\n"
    fi

    exec > >(tee -a "$LOGFILE") 2>&1

    local target=$1
    if [ -z "$target" ]; then
        colored_echo red "Usage: $0 <file_or_dir_to_monitor>"
        exit 1
    fi

    if [ ! -e "$target" ]; then
        colored_echo red "Error: Target '$target' does not exist."
        exit 1
    fi

    local audit_key=""
    audit_key=$(echo "$target" | sed 's|^/||; s|/|_|g')
    audit_key="${audit_key}_audit"
    echo "Setting up audit monitoring for: $target"
    echo -e "Running /usr/sbin/auditctl -w $target -p wa -k $audit_key...\n"
    /usr/sbin/auditctl -w "$target" -p wa -k "$audit_key"

    echo "Monitoring set up successfully."
    colored_echo green "\nTo view audit logs, run: \nausearch -k $audit_key"
    exit 0
}

## Cleanup function ##
cleanup() {
    echo "Deleting $SERVER_STATUS_DIR..."
    rm -rvf "$SERVER_STATUS_DIR"
    echo -e "\nDeleting getstats script..."
    rm -rvf "$SCRIPT_DIR"/getstats
    echo -e "\nDeleting cronjob..."
    rm -vf /etc/cron.d/getstats
    colored_echo green "\n\nCleanup completed."
    exit 0
}

## Help function ##
print_help() {
    cat <<EOF >&2
Usage:

  -h, --help                             Print this message
  -l, --load-monitoring [OPTIONS]        Monitor system load and other load-related parameters. 
      -o, --override                     Overrides existing monitoring script and cronjob
      -t, --threshold VALUE              Set load threshold for the monitoring script
  -f, --file-monitoring                  Monitor file changes 
  -c, --cleanup                          Delete the script's directories and files
EOF
}

while true; do
    case $1 in
    -h | --help)
        print_help
        exit 0
        ;;
    -l | --load-monitoring)
        shift
        while [[ $# -gt 0 ]]; do
            case $1 in
            --override | -o)
                LOAD_MONITORING_OVERRIDE=true
                shift
                ;;
            --threshold | -t)
                if [[ -z "$2" ]] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
                    echo "Error: Invalid threshold value. Please provide a numeric value."
                    exit 1
                fi
                LOAD_THRESHOLD="$2"
                shift 2
                ;;
            -*)
                echo "Error: Unrecognized option '$1' inside --load-monitoring."
                exit 1
                ;;
            *)
                break
                ;;
            esac
        done

        load_monitoring
        ;;

    -f | --file-monitoring)
        if [[ -z "$2" ]]; then
            echo "Error: Missing argument for -f/--file-monitoring."
            echo "Usage: $0 -f <file_or_dir_to_monitor>"
            exit 1
        fi
        file_monitoring "$2"
        ;;
    -c | --cleanup)
        cleanup
        ;;
    -*)
        echo "$0: error - unrecognized option $1" 1>&2
        print_help
        exit 1
        ;;
    *)
        echo -e "Usage: $0 [OPTION]\nTry 'bash $0 --help' for more information."
        exit 1
        ;;
    esac
done
