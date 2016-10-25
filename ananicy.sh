#!/bin/bash
################################################################################
# Ananicy - is Another auto nice daemon, with community rules support
# Configs are placed under /etc/ananicy.d/

################################################################################
# Define some fuctions
INFO(){ echo -n "INFO: "; echo "$@" ;}
WARN(){ echo -n "WARN: "; echo "$@" ;}
ERRO(){ echo -n "ERRO: "; echo -n "$@" ; echo " Abort!"; exit 1;}

################################################################################
# Check DIR_CONFIGS
DIR_CONFIGS=/etc/ananicy.d/
INFO "Check $DIR_CONFIGS dir"
[ -d "$DIR_CONFIGS" ] || ERRO "Config dir $DIR_CONFIGS doesn't exist!"

################################################################################
# Load all rule file names
INFO "Search rules"
CONFIGS=( $(find -P $DIR_CONFIGS -name "*.rules" -type f) )
[ "0" != "${#CONFIGS[@]}" ] || ERRO "Config dir: $DIR_CONFIGS are empty!"

################################################################################
# Return specified line of file, ignore comments
read_line(){
    FILE="$1" NUM=$2  # Read line | remove comments | remove unsafe symbols
    sed "${NUM}q;d" $FILE | cut -d'#' -f1 | tr -d '()`$'
}

################################################################################
# Dedup rules
declare -A RULE_CACHE_TMP

for config in "${CONFIGS[@]}"; do
    LINE_COUNT=$(wc -l < "$config")
    for line_number in $(seq 1 $LINE_COUNT); do
        LINE="$(read_line $config $line_number)"
        [ -z "$LINE" ] && continue
        for COLUMN in $LINE; do
            case "$COLUMN" in
                NAME=*)
                    NAME="${COLUMN//NAME=/}"
                    [ -z "$NAME" ] && \
                        ERRO "$config:$line_number NAME are empty!"
                    RULE_CACHE_TMP["$NAME"]="$LINE"
                ;;
            esac
        done
    done
done

unset CONFIGS
################################################################################
# Compile rules
INFO "Compile rule files"
RULE_CACHE=()
for LINE in "${RULE_CACHE_TMP[@]}"; do
    case "$LINE" in
        *NAME=*)
            case "$LINE" in
                *NICE=*)    : ;;
                *IOCLASS=*) : ;;
                *IONICE=*)  : ;;
                *) LINE="" ;;
            esac
        ;;
        *) LINE="";
    esac
    [ -z "$LINE" ] || RULE_CACHE=( "${RULE_CACHE[@]}" "$LINE" )
done
unset RULE_CACHE_TMP

[ "0" == "${#RULE_CACHE[@]}" ] && ERRO "No rule is enabled!"

################################################################################
# Show cached information
show_cache(){
    INFO "Dump compiled rules"
    {
        for cache_line in "${RULE_CACHE[@]}"; do
            echo "$cache_line"
        done
    } | sort | column -t
}

trap "{ show_cache; }" SIGUSR1

nice_of_pid(){
    read -r stat < /proc/$1/stat
    # 19 column in stat is a nice
    column_19(){ echo ${19}; }
    column_19 $stat
}

################################################################################
# Nice handler for process name
wrapper_renice(){
    export NAME="$1" NICE="$2"
    [ -z $NICE ] && return
    for pid in $( pgrep -w "$NAME" ); do
        CURRENT_NICE=$(nice_of_pid $pid)
        if [ "${CURRENT_NICE}" != "$NICE" ]; then
            renice -n $NICE -p $pid &> /dev/null && \
                INFO "Process $NAME cpu nice: $NICE"
        fi
    done
}

################################################################################
# IONice handler for process name
declare -A ionice_cache
wrapper_ionice(){
    export NAME="$1" IOCLASS="$2" IONICE="$3"
    [ "$IOCLASS" == "NULL" ] && [ -z "$IONICE" ] && return

    for pid in $( pgrep -w "$NAME" ); do
        if [ "$IOCLASS" != "NULL" ]; then
            if [ "${ionice_cache[${NAME}_${pid}_ioclass]}" != "$IOCLASS" ]; then
                ionice -c "$IOCLASS" -p "$pid" && \
                    ionice_cache[${NAME}_${pid}_ioclass]="$IOCLASS" && \
                        INFO "Process $NAME ioclass: $IOCLASS"
            fi
        fi
        if [ ! -z "$IONICE" ]; then
            if [ "${ionice_cache[${NAME}_${pid}_ionice]}" != "$IONICE" ]; then
                ionice -n "$IONICE" -p "$pid" && \
                    ionice_cache[${NAME}_${pid}_ionice]="$IONICE" && \
                        INFO "Process $NAME ionice: $IONICE"
            fi
        fi
    done
}

check_root_rights(){ [ "$UID" == "0" ] || ERRO "Script must be runned as root!"; }

main_pid_get(){
    PIDS=( $(pgrep ananicy | grep -v $$) )
    [ -z "${PIDS[0]}" ] && ERRO "Can't find running Ananicy"
    echo "${PIDS[@]}"
}

check_schedulers(){
    for disk_path in /sys/class/block/*; do
        disk_name=$(basename $disk_path)
        scheduler_path="$disk_path/queue/scheduler"
        [ ! -f $scheduler_path ] && continue
        grep -q '\[cfq\]' $scheduler_path || \
            WARN "Disk $disk_name not used cfq scheduler IOCLASS/IONICE will not work on it!"
    done
}

show_help(){
    echo "$0 start - start daemon"
    echo "$0 dump rules cache - daemon will dump rules cache to stdout"
    echo "$0 dump rules parsed - generate and dump rules cache to stdout"
}

main_process(){
    for cache_line in "${RULE_CACHE[@]}"; do
        NAME="" NICE="" IOCLASS="NULL" IONICE=""
        for COLUMN in $cache_line; do
            case "$COLUMN" in
                NAME=*)    NAME="${COLUMN//NAME=/}"         ;;
                NICE=*)    NICE="${COLUMN//NICE=/}"         ;;
                IONICE=*)  IONICE="${COLUMN//IONICE=/}"     ;;
                IOCLASS=*) IOCLASS="${COLUMN//IOCLASS=/}"   ;;
            esac
        done
        if [ ! -z "$NAME" ]; then
            wrapper_renice "$NAME" "$NICE"
            wrapper_ionice "$NAME" "$IOCLASS" "$IONICE"
        fi
    done
}

################################################################################
# Main process
case $1 in
    start)
        check_root_rights
        check_schedulers
        INFO "Start main process"
        RUN_FREQ=15
        while true; do
            main_process
            sleep $RUN_FREQ
        done
    ;;
    dump)
        case "$2" in
            rules)
                case "$3" in
                    cache)
                        check_root_rights
                        for pid in $(main_pid_get); do
                            [ -d /proc/$pid ] && \
                                kill -s SIGUSR1 $pid
                        done
                    ;;
                    parsed) show_cache ;;
                    *) show_help ;;
                esac
            ;;
            *) show_help ;;
        esac
    ;;
    *) show_help ;;
esac
