#!/bin/bash
dest_root="/mnt/backup/root"
dest_home="/mnt/backup/home"
lockfile="/tmp/backup_root.lock"
logfile=""

show_help() {
    local BOLD=$'\033[1m'
    local RESET=$'\033[0m'
    cat <<EOF
Usage: personal_snapshot_utility --root|--home --run|--dry-run [--list-files] [--progress-bar|--progress-file] [--snapshot_suffix=NAME]

Incremental backup with rsync + hard links. Two main targets:
    --root : backup of '/' and saves snapshots in $dest_root/
    --home : backup of '/home' and saves snapshots in $dest_home/

Options:
    -h, --help
        Show this help and exit.
    --root
        Select backup of root system (/).
    --home
        Select backup of /home directory.
    --run
        Actually perform the backup (requires root privileges).
    --dry-run
        Simulate execution without making changes.
    --list-files
        List files that would be copied (only with --dry-run). Useful to grep for specific files or directories. Use sort -h to sort by size.
        Example: ${BOLD}personal_snapshot_utility --home|--root --dry-run --list-files${RESET}
        Exclude paths (works only with --list-files):
            --exclude=VALUE
                Add a path to exclude from the listed results when using --list-files.
                Can be repeated multiple times. VALUE can be:
                    - relative to the home (e.g. .mozilla/)
                    - with tilde (e.g. ~/.cache/mozilla/)
                    - absolute (e.g. /home/you/.mozilla/)
                    - use * as wildcard (e.g. Downloads/*)
                Example: ${BOLD}personal_snapshot_utility --home --dry-run --list-files --exclude=.mozilla/ --exclude=Downloads/*${RESET}
    --snapshot_suffix=NAME
        Adds a suffix to the snapshot name (use with care).
        Example: ${BOLD}personal_snapshot_utility --home --run --snapshot_suffix="MyCopy_01"${RESET}
    --progress-bar
        Show aggregate progress bar (only with --run).
        Example: ${BOLD}personal_snapshot_utility --home --run --progress-bar${RESET}
    --progress-file
        Show each file as it is copied (only with --run).
        Example: ${BOLD}personal_snapshot_utility --home --run --progress-file${RESET}
        --no-color 
            Disable per-folder colorization in --progress-file output.
            Example: ${BOLD}personal_snapshot_utility --home --run --progress-file --no-color${RESET}
EOF
    exit 0
}

dry_run=1
list_files=0
target_type=""
action=""
progress_file=0
progress_bar=0
arg_color=1
no_color_flag=0
cli_file_list_excludes=()

if [ "$#" -eq 0 ]; then
    show_help
fi

for arg in "$@"; do
    case "$arg" in
        --run) action="run" ;;
        --dry-run) action="dry-run" ;;
        --help|-h) show_help ;;
        --list-files) list_files=1 ;;
        --no-color) arg_color=0; no_color_flag=1 ;;
        --snapshot_suffix=*) snapshot_suffix="${arg#*=}"; shift ;;
        --exclude=*) cli_file_list_excludes+=("${arg#*=}"); shift ;;
        --progress-file) progress_file=1 ;;
        --progress-bar) progress_bar=1 ;;
        --root) target_type="root" ;;
        --home) target_type="home" ;;
        *)
            echo "Unknown argument: $arg" >&2
            echo "Use --help to see valid arguments" >&2
            exit 1
            ;;
    esac
done

loading() {
    local action="$1"
    local msg="$2"

    case "$action" in
        start)
            if [ -n "${pid:-}" ]; then
                kill "$pid" 2>/dev/null || true
                wait "$pid" 2>/dev/null || true
            fi

            printf "\e[?25l"
            printf "%s" "$msg"

            {
                while true; do
                    printf "\r%s.  "  "$msg"
                    sleep 0.4
                    printf "\r%s.. "  "$msg"
                    sleep 0.4
                    printf "\r%s..." "$msg"
                    sleep 0.4
                done
            } &
            pid=$!
            ;;
        stop)
            if [ -n "${pid:-}" ]; then
                kill "$pid" 2>/dev/null || true
                wait "$pid" 2>/dev/null || true
                pid=""
            fi
            printf "\e[?25h"
            ;;
    esac
}

if [ -z "$target_type" ]; then
    echo -e "\033[1mError: missing primary argument. Use --root or --home.\033[0m" >&2
    show_help
fi
if [ -z "$action" ]; then
    echo -e "\033[1mError: select --run or --dry-run.\033[0m" >&2
    show_help
fi

if [ "$action" = "run" ]; then
    dry_run=0
else
    dry_run=1
fi

if [ "$dry_run" -eq 0 ]; then
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        echo "Root privilege is needed." >&2
        exit 1
    fi
fi

if [ "$list_files" -eq 1 ] && [ "$dry_run" -eq 0 ]; then
    echo -e "\033[1;31mError: --list-files can only be used with --dry-run.\033[0m" >&2
    show_help
fi

if [ "${#cli_file_list_excludes[@]}" -gt 0 ]; then
    if [ "$list_files" -ne 1 ] || [ "$dry_run" -ne 1 ]; then
        echo -e "\033[1;31mError: --exclude can only be used with --home --dry-run --list-files.\033[0m" >&2
        show_help
    fi
fi

if [ "$progress_file" -eq 1 ] && [ "$dry_run" -eq 1 ]; then
    echo -e "\033[1;31mError: --progress-file can only be used with --run.\033[0m" >&2
    show_help
fi

if [ "$progress_bar" -eq 1 ] && [ "$dry_run" -eq 1 ]; then
    echo -e "\033[1;31mError: --progress-bar can only be used with --run.\033[0m" >&2
    show_help
fi

if [ "$no_color_flag" -eq 1 ] && [ "$progress_file" -ne 1 ]; then
    echo -e "\033[1;31mError: --no-color can only be used with --progress-file.\033[0m" >&2
    show_help
fi

if [ -n "$snapshot_suffix" ] && [ "$dry_run" -eq 1 ]; then
    echo -e "\033[1;31mError: --snapshot_suffix can only be used with --run.\033[0m" >&2
    show_help
fi

exec 200>"$lockfile"

if ! flock -n 200; then
    echo "Another backup instance is running (lock: $lockfile)." >&2
    exit 1
fi

cleanup_trap() {
    if [ "$progress_bar" -eq 1 ] || [ "$dry_run" -eq 1 ]; then
        loading stop 
    fi
    rc=$?
    flock -u 200 || true
    rm -f "$lockfile"

    rm -f "$tmp_out" "$tmp_err"

    if [ -n "${last_signal:-}" ]; then # dry run cancel message
        if [ "${last_signal}" = "INT" ] && [ "${dry_run:-1}" -eq 1 ]; then
            sig_msg="Dry-run canceled."
        fi
    else
        fail_msg="Backup failed with exit code ${rc}. This message shouldn't appear in any circumstance. debug needed."
    fi  

    if [ "${real_run:-0}" -eq 1 ]; then
        if [ -n "${last_signal:-}" ]; then
            if [ "${last_signal}" = "INT" ]; then
                echo "${sig_msg}" | tee -a "${logfile}"
            else
                echo " ${sig_msg}" | tee -a "${logfile}"
            fi
            if [ -n "${snapshot_dir:-}" ] && [ -d "${snapshot_dir}" ]; then
                case "${snapshot_dir}" in
                    "${dest_base}"/*)
                        if [ -t 0 ] && [ -t 1 ]; then
                            echo -en "Remove incomplete snapshot?\n${snapshot_dir}\n[y/N]: "
                            read -r answer
                            if [ "${answer}" = "s" ] || [ "${answer}" = "S" ] || [ "${answer}" = "y" ] || [ "${answer}" = "Y" ]; then
                                echo "Removing incomplete snapshot: ${snapshot_dir}" | tee -a "${logfile}"
                                rm -rf -- "${snapshot_dir}" || true
                            fi
                        fi
                        ;;
                esac
            fi
        else
            if [ "${rc}" -ne 0 ]; then
                echo " ${fail_msg}" | tee -a "${logfile}"
            fi
        fi
    else
        if [ -n "${last_signal:-}" ]; then
            echo " ${sig_msg}" >&2
        else
            if [ "${rc}" -ne 0 ]; then
                echo " Backup (dry-run) failed with exit code ${rc}" >&2
            else
                if [ "${avail_bytes:-0}" -lt "${min_required:-0}" ]; then
                    echo -e "\033[1;91mWarning: Insufficient space for backup! Available: $(human_size "${avail_bytes}"), Required: $(human_size "${rsync_total_bytes:-0}")\033[0m"
                else
                    echo "Dry-run completed successfully"
                fi
            fi
        fi

        if [ -n "${snapshot_dir:-}" ] && [ -d "${snapshot_dir}" ]; then
            case "${snapshot_dir}" in
                "${dest_base}"/*)
                    rm -rf -- "${snapshot_dir}" || true
                    ;;
                *)
                    ;;
            esac
        fi
    fi
}

last_signal=""
trap 'last_signal=INT; exit' INT
trap 'last_signal=TERM; exit' TERM
trap 'cleanup_trap' EXIT

if [ "$target_type" = "root" ]; then
    dest_base="$dest_root"
    source="/"
    name_prefix="root"
else
    dest_base="$dest_home"
    source="/home/"
    name_prefix="home"
fi

excludes_root=(
    /proc
    /sys
    /dev
    /run
    /tmp
    /mnt
    /media
    /lost+found
    /home
    /boot/efi
)

excludes_home=(
    ".config/google-chrome/Default/Service Worker/CacheStorage"
    .cache/mozilla
    .cache/mesa_shader_cache
    .cache/thumbnails
    .cache/google-chrome
)

exclude_logs=(
    "backup_*.log"
)

if [ ! -d "$dest_base" ]; then
    echo "Destination $dest_base not found. Check mount point." >&2
    exit 1
fi
if [ ! -w "$dest_base" ]; then
    echo "Destination $dest_base not writable. Check permissions." >&2
    exit 1
fi

snapshot_found=0
if (shopt -s nullglob 2>/dev/null; set -- "$dest_base/${name_prefix}_"*; [ "$#" -gt 0 ]); then
    for p in "$dest_base/${name_prefix}_"*; do
        if [ -d "$p" ]; then
            snapshot_found=1
            break
        fi
    done
fi

if [ "$snapshot_found" -eq 1 ]; then
    if [ ! -L "$dest_base/last" ] || [ ! -e "$dest_base/last" ]; then
        echo -e "\033[1;91mWarning: Snapshot(s) exist but the symlink '$dest_base/last' is missing or broken. Please fix it before proceeding.\033[0m"
        exit 1
    fi
else
    if [ ! -L "$dest_base/last" ] || [ ! -e "$dest_base/last" ]; then
        if [ "$dry_run" -eq 1 ]; then
            no_snapshots=1
            echo "No previous snapshots found. Performing first backup analysis and availability check."
        else
            echo "No previous snapshots found. Performing first backup."
        fi
        rm -f "$dest_base/last" 2>/dev/null || true
    fi
fi

if [ "$dry_run" -eq 1 ]; then
    snapshot_dir="$dest_base/.${name_prefix}_$(date "+%d-%m-%Y_%H-%M")"
else
    if [ -n "$snapshot_suffix" ]; then
        snapshot_dir="$dest_base/${name_prefix}_$(date "+%d-%m-%Y_%H-%M")_${snapshot_suffix}"
    else
        snapshot_dir="$dest_base/${name_prefix}_$(date "+%d-%m-%Y_%H-%M")"
    fi
fi
mkdir -p "$snapshot_dir"

if [ "$dry_run" -eq 0 ]; then
    logfile="$snapshot_dir/backup_$(date "+%d-%m-%Y_%H-%M").log"
    : >"$logfile"
    real_run=1
else
    real_run=0
fi

log() {
    if [ "${real_run:-0}" -eq 1 ]; then
        printf '%s\n' "$*" | tee -a "$logfile"
    else
        printf '%s\n' "$*"
    fi
}
log_err() {
    if [ "${real_run:-0}" -eq 1 ]; then
        printf '%s\n' "$*" >> "$logfile"
        printf '\033[31m%s\033[0m\n' "$*" >&2
    else
        printf '\033[31m%s\033[0m\n' "$*" >&2
    fi
}

if [ "${dry_run:-1}" -eq 1 ]; then
    if [ "${no_snapshots:-0}" -eq 0 ]; then
        log "Performing dry-run. Use --run to actually copy."
    fi
    loading start "Analysing"
else
    if [ -n "${logfile:-}" ]; then
        log "Performing real backup. Log: ${logfile}"
    else
        log "Performing real backup."
    fi
fi

if [ "${target_type}" = "root" ]; then
    du_excludes=("${excludes_root[@]}")
else
    du_excludes=("${excludes_home[@]}")
fi

du_cmd=(du -sb)
for e in "${du_excludes[@]}"; do
    du_cmd+=(--exclude="$e")
done
du_cmd+=("$source")

rsync_opts=( -aHAX --numeric-ids --delete --delete-after --partial --partial-dir=.rsync-partial --no-compress --itemize-changes --progress --stats --one-file-system )

if [ -d "$dest_base/last" ]; then
    rsync_opts+=( --link-dest="$dest_base/last" )
fi

if [ "${target_type}" = "root" ]; then
    excludes=( "${excludes_root[@]}" )
else
    excludes=( "${excludes_home[@]}" )
fi

excludes+=( "${exclude_logs[@]}" )

for e in "${excludes[@]}"; do
    rsync_opts+=( --exclude="$e" )
done

rsync_opts+=( "$source" "$snapshot_dir" )

human_size() {
    local bytes=${1:-0}
    bytes=${bytes//,/}
    [[ $bytes == *[^0-9]* ]] && bytes=0

    awk -v size="$bytes" '
    BEGIN {
        split("B KiB MiB GiB TiB PiB EiB", unit)
        for (i=1; size>=1024 && i<7; i++) size /= 1024
        if (size == int(size)) printf "%d %s", size, unit[i]
        else printf "%.2f %s", size, unit[i]
    }'
}

count_transferred_lines() {
    local f="$1"
    if [ ! -f "$f" ]; then
        echo 0
        return
    fi

    local transferred=$(grep 'Number of regular files transferred:' "$f" 2>/dev/null | tail -1 | awk '{print $NF}' | tr -d ',.')
    
    if [ -n "$transferred" ] && [ "$transferred" -gt 0 ] 2>/dev/null; then
        echo "$transferred"
        return
    fi

    transferred=$(grep 'Number of created files:' "$f" 2>/dev/null | tail -1 | awk -F'[(:,.]' '{for(i=NF;i>=1;i--) if($i ~ /^[0-9]+$/) {print $i; break}}' | head -1)
    
    if [ -n "$transferred" ] && [ "$transferred" -gt 0 ] 2>/dev/null; then
        echo "$transferred"
        return
    fi

    local n1
    n1=$(awk '($1 ~ /^[0-9]+$/) { count++ } END { if (count>0) print count; else print 0 }' "$f")
    echo "$n1"
}

count_listed_files() {
    local f="$1"
    if [ ! -f "$f" ]; then
        echo 0
        return
    fi
    
    awk '($1 ~ /^[0-9]+$/) { count++ } END { if (count>0) print count; else print 0 }' "$f"
}

summarize_rsync_output() {
        local pre_calculated_count="${2:-}"
        
        if [ -n "$pre_calculated_count" ]; then
            transferred_count="$pre_calculated_count"
        else

            transferred_count=$(count_transferred_lines "$1")
        fi
        
        if [ "${LANG%%.*}" = "pt_BR" ]; then
            transferred_count=$(printf "%'d" "$transferred_count" | sed "s/,/./g")     
        fi

    total_bytes=$(awk '{sum += $1} END{ if (sum>0) printf "%.0f", sum; else print 0 }' "$1")
    
    rsync_total_bytes="$total_bytes"
    min_required=$(( total_bytes + total_bytes / 10 ))

    if [ "${real_run:-0}" -eq 1 ] && [ -n "${logfile:-}" ]; then      
        {
            echo -e "\n----- rsync summary -----"
            echo "Files transfered: $transferred_count"
            echo "Total size transfered: $(human_size "$total_bytes")"
            
            echo "---------------------------"
            echo
        } >> "$logfile"
    else
        plain_summary=$(printf "\n----- rsync summary -----\nFiles to transfer: %s\n" "$transferred_count")
        plain_summary+=$(printf "Total size to transfer: %s\n" "$(human_size "$total_bytes")")
        avail_bytes=$(df --output=avail -B1 "$dest_base" | tail -n1)
        avail_human=$(human_size "$avail_bytes")

        need_red=0
        if [ "${dry_run:-0}" -eq 1 ]; then
            if [ "${min_required:-0}" -gt "${avail_bytes:-0}" ]; then
                need_red=1
            fi
        else
            if [ "${avail_bytes:-0}" -lt "${min_required:-0}" ]; then
                need_red=1
            fi
        fi

        if [ "$need_red" -eq 1 ] && [ -t 1 ]; then
            plain_summary+=$(printf "Available space on destination: \033[1;91m%s\033[0m\n" "$avail_human")
        else
            plain_summary+=$(printf "Available space on destination: %s\n" "$avail_human")
        fi
        plain_summary+=$'---------------------------\n\n'
    fi

    if [ "${real_run:-0}" -eq 1 ] && [ -n "${logfile:-}" ]; then
        printf '%s' "$plain_summary" >>"$logfile" || true
    else
        if [ -t 1 ]; then
            printf -- '\n\n----- rsync summary -----\n'
            printf 'Files to transfer: \033[1m%s\033[0m\n' "$transferred_count"
            printf 'Total size to transfer: \033[1m%s\033[0m\n' "$(human_size "$total_bytes")"
            if [ "$need_red" -eq 1 ] && [ -t 1 ]; then
                printf 'Available space on destination: \033[1;91m%s\033[0m\n' "$avail_human"
            else
                printf 'Available space on destination: \033[1m%s\033[0m\n' "$avail_human"
            fi
            printf 'Location: \033[1m%s\033[0m\n' "$dest_base"
            printf -- '---------------------------\n\n'
        else
            printf '%s' "$plain_summary"
        fi
    fi
}

filter_rsync_output() {
    local skip_enabled=0
    local skip_regex=""
    
    if [ "${#cli_file_list_excludes[@]}" -gt 0 ]; then
        skip_enabled=1
        local skip_user="${SUDO_USER:-${LOGNAME:-${USER:-$(id -un)}}}"
        local -a ignore_paths=()

        for ex in "${cli_file_list_excludes[@]}"; do
            p="$ex"
            if [[ "$p" == "~/"* ]]; then
                p="${p/#~\//$skip_user/}"
            elif [[ "$p" == "/home/$skip_user/"* ]]; then
                p="${p#/home/}"
            elif [[ "$p" == /* ]]; then
                p="${p#/}"
            else
                p="${skip_user}/$p"
            fi
            p="${p#./}"
            p="${p#/}"
            ignore_paths+=("$p")
        done

        for p in "${ignore_paths[@]}"; do
            esc=$(printf '%s' "$p" | sed -e 's/[.^$+?()[\]{}|\\]/\\&/g')
            esc=$(printf '%s' "$esc" | sed -e 's/\*/.*/g')

            if [ "${esc: -1}" != "/" ] && [ "${esc: -2}" != ".*" ]; then
                esc="$esc(/|$)"
            fi

            if [ -z "$skip_regex" ]; then
                skip_regex="^$esc"
            else
                skip_regex="$skip_regex|^$esc"
            fi
        done
        skip_regex="($skip_regex)"
    fi

    awk -v target_type="$target_type" -v skip_enabled="$skip_enabled" -v skip_regex="$skip_regex" '
        function human_readable(bytes) {
            if (bytes == 0) return "0 B"
            units = "B KiB MiB GiB TiB PiB EiB"
            scale = 1024
            i = 1
            while (bytes >= scale && i < 7) {
                bytes = bytes / scale
                i++
            }
            split(units, u, " ")
            if (bytes == int(bytes))
                return sprintf("%d %s", bytes, u[i])
            else
                return sprintf("%.2f %s", bytes, u[i])
        }

        /^[[:space:]]*(Number of files:|Number of created files:|Number of deleted files:|Number of regular files transferred:|Total file size:|Total transferred file size:|Literal data:|Matched data:|File list size:|File list generation time:|File list transfer time:|Total bytes sent:|Total bytes received:|sent [0-9,.]+ bytes|total size is|speedup is|rsync error:|rsync: error:)/ { next }

        ($1 ~ /^[0-9]+$/) {
            size=$1
            name=""
            for (i=2;i<=NF;i++) name = name (i>2?" ":"") $i

            if (skip_enabled == "1" && skip_regex != "") {
                if (name ~ skip_regex) { next }
            }

            hsize = human_readable(size)

            if (target_type == "home") {
                printf "%-9s | /%s/%s\n", hsize, target_type, name
            } else {
                printf "%-9s | /%s\n", hsize, name
            }
            next
        }

        { print }
    ' "$1"
}

if [ "$dry_run" -eq 1 ]; then
    tmp_out=$(mktemp /tmp/backup_root.rsync.XXXXXX)
    if [ "${list_files:-0}" -eq 1 ]; then
        ionice -c3 nice -n 19 rsync "${rsync_opts[@]}" -i --dry-run --out-format="%l %n" >"$tmp_out" 2>&1 || true # dry list
    else
        ionice -c3 nice -n 19 rsync "${rsync_opts[@]}" --dry-run --out-format="%l %n" >"$tmp_out" 2>&1 || true # dry 
    fi
    
    if [ -f "$tmp_out" ]; then
        tmp_new=$(mktemp /tmp/backup_root.rsync.XXXXXX)

        TEMP_FILES=( "$tmp_out" "$tmp_new" )

        awk -v is_tty="$([ -t 1 ] && echo 1 || echo 0)" '
            BEGIN {
                red="\033[91m"
                reset="\033[0m"
                other_error_count = 0
            }

            # Descarta erros de KDE xattr (user.kde.fm.viewproperties)
            /lsetxattr/ {
                next
            }

            /^rsync:/ {
                other_error_count++
                if (is_tty)
                    print red $0 reset
                else
                    print
                next
            }

            /rsync error: some files\/attrs were not transferred/ {
                if (other_error_count > 0) {
                    if (is_tty)
                        print red $0 reset
                    else
                        print
                }
                other_error_count = 0
                next
            }

            /building file list/ { next }
            /files to consider/ { next }

            { print }
        ' "$tmp_out" > "$tmp_new"

        mv "$tmp_new" "$tmp_out"
        trap 'last_signal=INT; exit' INT
    fi   
    
    calculated_count=$(count_transferred_lines "$tmp_out")
    
    if [ "${list_files:-0}" -eq 1 ]; then
        filter_rsync_output "$tmp_out"
    fi
    summarize_rsync_output "$tmp_out" "$calculated_count"
    rm -f "$tmp_out"
    rm -rf "$snapshot_dir"
    exit 0
fi

tmp_out=$(mktemp /tmp/backup_root.rsync.XXXXXX)

calculate_total_files() {
    local rsync_dry_tmp=$(mktemp /tmp/backup_root.rsync.dry.XXXXXX)

    ionice -c3 nice -n 19 rsync "${rsync_opts[@]}" --dry-run --out-format='%l %n' >"$rsync_dry_tmp" 2>&1 || true
   
    local total_files=$(grep 'Number of regular files transferred:' "$rsync_dry_tmp" 2>/dev/null | tail -1 | awk '{print $NF}' | tr -d ',.')
    
    if [ -n "$total_files" ] && [ "$total_files" -gt 0 ] 2>/dev/null; then
        rm -f "$rsync_dry_tmp"
        printf "%s" "$total_files"
        return
    fi
    
    total_files=$(grep 'Number of created files:' "$rsync_dry_tmp" 2>/dev/null | tail -1 | awk -F'[(:,.]' '{for(i=NF;i>=1;i--) if($i ~ /^[0-9]+$/) {print $i; break}}' | head -1)
    
    if [ -n "$total_files" ] && [ "$total_files" -gt 0 ] 2>/dev/null; then
        rm -f "$rsync_dry_tmp"
        printf "%s" "$total_files"
        return
    fi
    
    total_files=$(awk '($1 ~ /^[0-9]+$/) { count++ } END { if (count > 0) print count; else print 0 }' "$rsync_dry_tmp")
    
    rm -f "$rsync_dry_tmp"
    printf "%s" "$total_files"
}

draw_progress_bar_count() {
    local current=$1
    local total=$2
    local width=${3:-40}

    if [ "$total" -le 0 ]; then
        return
    fi

    local percent=$(( (current * 100) / total ))
    local filled=$(( (current * width) / total ))
    local empty=$(( width - filled ))

    local bar="["
    local i=0
    while [ $i -lt $filled ]; do
        bar="${bar}█"
        i=$((i + 1))
    done
    while [ $i -lt $width ]; do
        bar="${bar}░"
        i=$((i + 1))
    done
    bar="${bar}]"

    if [ "${LANG%%.*}" = "pt_BR" ]; then
        local current_fmt=$(printf "%'d" "$current" | sed "s/,/./g")
        local total_fmt=$(printf "%'d" "$total" | sed "s/,/./g")

    else    
        local current_fmt=$(printf "%'d" "$current")
        local total_fmt=$(printf "%'d" "$total")
    fi

    printf "\r%-50s %3d%% (%s / %s files)" "$bar" "$percent" "$current_fmt" "$total_fmt"
}

set +e
if [ "$progress_bar" -eq 1 ]; then

    loading start "Calculating total files to transfer"
    total_files=$(calculate_total_files)
    loading stop

    if [ "$total_files" -le 0 ]; then
        total_files=1
    fi
    
    tmp_err=$(mktemp /tmp/backup_root.rsync.err.XXXXXX)

    echo -e "\nStarting backup." >&2

    ionice -c3 nice -n 19 rsync "${rsync_opts[@]}" --out-format='%l %n' --info=progress2 \
        > >(grep -vE 'xfr#|to-chk=|[0-9]+%|[0-9]+([\\.,][0-9]+)?(B|KB|MB|GB)/s' >"$tmp_out") \
        2> >(grep -vE 'xfr#|to-chk=|[0-9]+%|[0-9]+([\\.,][0-9]+)?(B|KB|MB|GB)/s' >>"$tmp_err") & # real progress bar
    rsync_pid=$!
    
    current_files=0
    
    while kill -0 "$rsync_pid" 2>/dev/null; do
        sleep 0.5
        
        if [ -f "$tmp_out" ]; then
            
            current_files=$(count_transferred_lines "$tmp_out")

            if [ "$current_files" -gt "$total_files" ]; then
                current_files=$total_files
            fi

            draw_progress_bar_count "$current_files" "$total_files"
        fi
    done
    
    wait "$rsync_pid"
    rsync_rc=$?
   
    current_files=$(count_transferred_lines "$tmp_out")
    if [ "$current_files" -gt "$total_files" ]; then
        current_files=$total_files
    fi
    draw_progress_bar_count "$current_files" "$total_files"
    printf "\n"
    
    if [ -f "$tmp_err" ]; then
        grep -vE 'xfr#|to-chk=|[0-9]+%|[0-9]+([\\.,][0-9]+)?(B|KB|MB|GB)/s|^Number of (files|created files|deleted files):|^Total file size:|^Literal data:|^Matched data:|^File list size:|^File list generation time:|^File list transfer time:|^Total bytes (sent|received):|^sent[[:space:]]+[0-9.,]+ bytes|^total size is' "$tmp_err" >> "$tmp_out" 2>/dev/null || true
    fi
    
    rm -f "$tmp_err" || true
elif [ "$progress_file" -eq 1 ]; then
    tmp_err=$(mktemp /tmp/backup_root.rsync.err.XXXXXX)

    ionice -c3 nice -n 19 rsync "${rsync_opts[@]}" --out-format='%l %n' --info=progress2 >"$tmp_out" 2>"$tmp_err" & # real progress file
    rsync_pid=$!
    
    tail -n +1 -F "$tmp_out" 2>/dev/null | awk -v target_type="$target_type" -v arg_color="$arg_color" '
        function human_readable(bytes) {
            if (bytes == 0) return "0 B"
            units = "B KiB MiB GiB TiB PiB"
            scale = 1024
            i = 1
            while (bytes >= scale && i < 7) {
                bytes = bytes / scale
                i++
            }
            split(units, u, " ")
            if (bytes == int(bytes))
                return sprintf("%d %s", bytes, u[i])
            else
                return sprintf("%.2f %s", bytes, u[i])
        }

        function get_color(dir_name,    color_index) {
            if (!(dir_name in dir_colors)) {
                color_index = (dir_count % 6) + 1
                dir_colors[dir_name] = colors[color_index]
                dir_count++
            }
            return dir_colors[dir_name]
        }

        function get_directory(filepath,    parts, dir_parts_count) {
            split(filepath, parts, "/")
            dir_parts_count = length(parts) - 1
            
            if (dir_parts_count >= 1) {
                return parts[dir_parts_count]
            }
            return "/"
        }

        BEGIN {
            current_progress = "0%"
            dir_count = 0
            colors[1] = "\033[38;5;81m"    # cyan/blue
            colors[2] = "\033[38;5;118m"   # green
            colors[3] = "\033[38;5;208m"   # orange
            colors[4] = "\033[38;5;198m"   # magenta/pink
            colors[5] = "\033[38;5;226m"   # yellow
            colors[6] = "\033[38;5;51m"    # bright cyan
            reset = "\033[0m"
        }

        /building file list/ { next }
        /files to consider/ { next }

        {
            if (NF >= 2 && $1 ~ /^[0-9,]+$/ && $2 ~ /^[0-9]+%$/) {
                current_progress = $2
                next
            }
        }

        {
            if (match($0, /to-chk=([0-9]+)\/([0-9]+)/, arr)) {
                rem = arr[1] + 0
                tot = arr[2] + 0
                if (tot > 0) {
                    done = tot - rem
                    pct = int((done * 100) / tot + 0.5)
                    if (pct < 0) pct = 0
                    if (pct > 100) pct = 100
                    current_progress = pct "%"
                } else {
                    current_progress = "0%"
                }
                next
            }
        }

        /[0-9]+%/ {
            for (i=1; i<=NF; i++) {
                if ($i ~ /^[0-9]+%$/) {
                    current_progress = $i
                    break
                }
            }
        }

        ($1 ~ /^[0-9]+$/ && NF >= 2) {
            size = $1
            filename = ""
            for (i=2; i<=NF; i++) {
                filename = filename (i>2 ? " " : "") $i
            }

            current_dir = get_directory(filename)

            if (arg_color) {
                color = get_color(current_dir)
            } else {
                color = ""
            }
            
            hr_size = human_readable(size)
            if (target_type == "home") {
                printf "%-4s |  %-10s | %s/%s/%s%s\n", current_progress, hr_size, color, target_type, filename, reset
            } else {
                printf "%-4s |  %-10s | %s/%s%s\n", current_progress, hr_size, color, filename, reset
            }
            next
        }

        function last_num() {
            for (i=NF; i>=1; i--) {
                if ($i ~ /^[0-9,]+$/) {
                    n = $i
                    gsub(/[^0-9]/, "", n)
                    return n
                }
            }
            return ""
        }

        /^Number of files:/ { next }
        /^Number of created files:/ { next }
        /^Number of deleted files:/ { next }
        /^Total file size:/ { next }
        /^Literal data:/ { next }
        /^Matched data:/ { next }
        /^File list size:/ { next }
        /^File list generation time:/ { next }
        /^File list transfer time:/ { next }
        /^Total bytes sent:/ { next }
        /^Total bytes received:/ { next }
        /^sent[[:space:]]+[0-9.,]+ bytes/ { next }
        /^total size is/ { next }

        /^Number of regular files transferred:/ {
            files_transferred = $NF
            gsub(/[^0-9]/, "", files_transferred)
            next
        }

        /^Total transferred file size:/ {
            s = $NF
            if (s == "bytes") {
                s = $(NF-1)
            }
            gsub(/[^0-9]/, "", s)
            data_transferred = human_readable(s+0)
            print "----- copy summary -----"
            if (files_transferred == "") {
                f = last_num()
            } else {
                f = files_transferred
            }
            printf "Files transferred: \033[1m%s\033[0m\n", f
            printf "Data transferred: \033[1m%s\033[0m\n", data_transferred
            print "---------------------------"
            next
        }

        !/^[[:space:]]/ { print }
    ' &

    tail_pid=$!
    wait "$rsync_pid"
    rsync_rc=$?

    kill "$tail_pid" 2>/dev/null || true
    wait "$tail_pid" 2>/dev/null || true
    tmp_combined=$(mktemp /tmp/backup_root.rsync.combined.XXXXXX)
    cat "$tmp_out" > "$tmp_combined" || true

    if [ -f "$tmp_err" ]; then
        grep -vE 'xfr#|to-chk=|[0-9]+%|[0-9]+([\\.,][0-9]+)?(B|KB|MB|GB)/s|^Number of (files|created files|deleted files):|^Total file size:|^Literal data:|^Matched data:|^File list size:|^File list generation time:|^File list transfer time:|^Total bytes (sent|received):|^sent[[:space:]]+[0-9.,]+ bytes|^total size is' "$tmp_err" >> "$tmp_combined" 2>/dev/null || true
    fi

    if grep -qE 'xfr.|to-chk=|[0-9]+%|[0-9]+([\\.,][0-9]+)?(B|KB|MB|GB)/s|^Number of (files|created files|deleted files):|^Total file size:|^Literal data:|^Matched data:|^File list size:|^File list generation time:|^File list transfer time:|^Total bytes (sent|received):|^sent [0-9,]+ bytes|^total size is' "$tmp_combined" 2>/dev/null; then
        tmp_combined_filtered=$(mktemp /tmp/backup_root.rsync.combined.filtered.XXXXXX)
        grep -vE 'xfr#|to-chk=|[0-9]+%|[0-9]+([\\.,][0-9]+)?(B|KB|MB|GB)/s|^Number of (files|created files|deleted files):|^Total file size:|^Literal data:|^Matched data:|^File list size:|^File list generation time:|^File list transfer time:|^Total bytes (sent|received):|^sent [0-9,]+ bytes|^total size is' "$tmp_combined" > "$tmp_combined_filtered" 2>/dev/null || true
        mv "$tmp_combined_filtered" "$tmp_combined" || true
    fi
    mv "$tmp_combined" "$tmp_out" || true
    rm -f "$tmp_err" || true
else
    ionice -c3 nice -n 19 rsync "${rsync_opts[@]}" --out-format='%l %n' >"$tmp_out" 2>&1 # real normal, no output
    rsync_rc=$?
fi
set -e
summarize_rsync_output "$tmp_out"

if [ "${real_run:-0}" -eq 1 ] && [ -n "$logfile" ]; then
    {
        echo -e "\n----- Transfered files -----"
        grep -v "[0-9]\\+ files\\.\." "$tmp_out" | sort -k2
        echo "----------------------------------------"
    } >> "$logfile"
fi
rm -f "$tmp_out"

if [ "${real_run:-0}" -eq 1 ] && ([ "${rsync_rc:-0}" -eq 0 ] || [ "${rsync_rc:-0}" -eq 24 ]); then # err 24 = some files vanished -> not fatal, expected in some cases
    tmp_link="$dest_base/last_tmp"
    ln -s "$snapshot_dir" "$tmp_link"
    mv -T "$tmp_link" "$dest_base/last"    
    if [[  "$dest_base" == *"root"* ]]; then
        cd "$dest_base/last"
        mkdir -p mnt tmp sys run proc dev home boot/efi || true
    fi  
    if [ $progress_bar -eq 1 ] && [ $dry_run -eq 0 ]; then
        echo -e "\n" 
    fi    
    log "Backup finished and Link updated: $dest_base/last -> $snapshot_dir"  # implement error handling that comprehends other components more than just rsync exit code.
else
    log_err "Backup failed. The link '$dest_base/last' was NOT updated. "
    loading start "Cleaning up incomplete snapshot"
    cp -f -- "$logfile" ${dest_base}/ 2>/dev/null || true
    if [ -n "${snapshot_dir:-}" ] && [ -d "${snapshot_dir}" ]; then
        case "${snapshot_dir}" in
            "${dest_base}"/*)                
                log_basename="$(basename -- "$logfile")"
                cp -f -- "$logfile" "${dest_base}/$log_basename" 2>/dev/null || true
                logfile="${dest_base}/$log_basename"
                rm -rf -- "${snapshot_dir}" || true
                ;;
            *)
                ;;
        esac
    fi
    loading stop    
    log_err "Rsync code ${rsync_rc:-}."
    
fi
