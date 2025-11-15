#!/bin/bash
dest_root="/mnt/data/Backup/root"
dest_home="/mnt/data/Backup/home"
lockfile="/tmp/backup_root.lock"
logfile=""

show_help() {
    cat <<EOF
Usage: $0 --root|--home --run|--dry-run [--list-files] [--progress-bar|--progress-file]

Incremental backup using rsync + hard links. There are two primary targets:
    --root    : backs up '/' and saves snapshots in $dest_root/
    --home    : backs up '/home' and saves snapshots in $dest_home/

Options:
        -h, --help
            Show this help and exit.
        --root
            Select backup of the system root (/).
        --home
            Select backup of the /home directory.
        --run
            Perform the actual backup (must be provided as the secondary option).
        --dry-run
            Simulate execution without making changes (must be provided as the secondary option).
        --snapshot_suffix
            Specify the name of the snapshot. The string is appended to the snapshot folder as suffix. Use carefully.
            Ex.: personal_snapshot_utility --home --run --snapshot_suffix="MySnapshot_01"
        --list-files
            Show the list of files that would be copied (optional, only with --dry-run).
        --progress-bar
            Show an overall progress display (only with --run).
        --progress-file
            Show each file as it is copied (only with --run).

Notes:
        - Snapshots are created in ${dest_root}/root_DD-MM-YYYY_HH-MM/ or
            ${dest_home}/home_DD-MM-YYYY_HH-MM/ depending on the target.
        - A symbolic link 'last' inside each destination points to the latest snapshot.
        - Logs are saved inside the snapshot folder when --run is used.
        - The --progress option displays each file as: /source -> /destination
EOF
    exit 0
}

dry_run=1
list_files=0
target_type=""
action=""
progress_file=0
progress_bar=0

if [ "$#" -eq 0 ]; then
    show_help
fi

for arg in "$@"; do
    case "$arg" in
        --run) action="run" ;;
        --dry-run) action="dry-run" ;;
        --help|-h) show_help ;;
        --list-files) list_files=1 ;;
        --snapshot_suffix=*) snapshot_suffix="${arg#*=}"; shift ;;
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
    echo -e "\033[1mError: --list-files can only be used with --dry-run.\033[0m" >&2
    show_help
fi

if [ "$progress_file" -eq 1 ] && [ "$dry_run" -eq 1 ]; then
    echo -e "\033[1mError: --progress-file can only be used with --run.\033[0m" >&2
    show_help
fi

if [ "$progress_bar" -eq 1 ] && [ "$dry_run" -eq 1 ]; then
    echo -e "\033[1mError: --progress-bar can only be used with --run.\033[0m" >&2
    show_help
fi

if [ -n "$snapshot_suffix" ] && [ "$dry_run" -eq 1 ]; then
    echo -e "\033[1mError: --snapshot_suffix can only be used with --run.\033[0m" >&2
    show_help
fi

exec 200>"$lockfile"

if ! flock -n 200; then
    echo "Another backup instance is running (lock: $lockfile)." >&2
    exit 1
fi

cleanup_trap() {
    rc=$?
    flock -u 200 || true

    rm -f "$tmp_out" "$tmp_err"

    if [ -n "${last_signal:-}" ]; then
        if [ "${last_signal}" = "INT" ] && [ "${list_files:-0}" -eq 1 ]; then
            sig_msg="Dry-run canceled."
        else
            printf "\n----------------------------------------"
        fi
    else
        ok_msg="Backup completed successfully"
        fail_msg="Backup failed with exit code ${rc}"
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
                            else
                                echo " Incomplete snapshot kept: ${snapshot_dir}" | tee -a "${logfile}"
                            fi
                        else
                            echo "Non-interactive terminal - keeping snapshot: ${snapshot_dir}" | tee -a "${logfile}"
                        fi
                        ;;
                    *)
                        echo "WARNING: Snapshot ${snapshot_dir} is outside base directory ${dest_base}, will not be removed" | tee -a "${logfile}"
                        ;;
                esac
            fi
        else
            if [ "${rc}" -ne 0 ]; then
                echo " ${fail_msg}" | tee -a "${logfile}"
            else
                echo " ${ok_msg}" | tee -a "${logfile}"
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
        printf '%s\n' "$*" | tee -a "$logfile" >&2
    else
        printf '%s\n' "$*" >&2
    fi
}

if [ "${dry_run:-1}" -eq 1 ]; then
    log "Performing dry-run. Use --run to actually copy."
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

for e in "${excludes[@]}"; do
    rsync_opts+=( --exclude="$e" )
done

rsync_opts+=( "$source" "$snapshot_dir" )

human_size() {
    if command -v numfmt >/dev/null 2>&1; then
        numfmt --to=iec --suffix=B --format="%.2f" "$1" 2>/dev/null || printf "%s B" "$1"
    else
        echo 'numfmt missing..'
    fi
}

summarize_rsync_output() {
    transferred_count=$(wc -l < "$1")

    total_bytes=$(awk '{sum += $1} END{ if (sum>0) printf "%.0f", sum; else print 0 }' "$1")
    
    has_bytes=$(awk -v n="$total_bytes" 'BEGIN{print (n > 0) ? 1 : 0}')
    rsync_total_bytes="$total_bytes"
    min_required=$(( total_bytes + total_bytes / 10 ))

    if [ "${real_run:-0}" -eq 1 ] && [ -n "${logfile:-}" ]; then
        avail_bytes=$(df --output=avail -B1 "$dest_base" | tail -n1)
        avail_human=$(human_size "$avail_bytes")
        
        {
            echo -e "\n----- rsync summary -----"
            echo "Files to transfer: $transferred_count"
            if [ "$has_bytes" -eq 1 ]; then
                echo "Total size to transfer: $(human_size "$total_bytes")"
            else
                echo "Total size to transfer: 0 bytes"
            fi
            echo "Espaço disponível no destino: $avail_human"
            echo "---------------------------"
            echo
        } >> "$logfile"
    else
        plain_summary=$(printf "\n----- rsync summary -----\nFiles to transfer: %s\n" "$transferred_count")
        if [ "$has_bytes" -eq 1 ]; then
            plain_summary+=$(printf "Total size to transfer: %s\n" "$(human_size "$total_bytes")")
        else
            plain_summary+=$(printf "Total size to transfer: 0 bytes\n")
        fi
        
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
            printf '\n'
            printf -- '----- rsync summary -----\n'
            printf 'Files to transfer: \033[1m%s\033[0m\n' "$transferred_count"
            if [ "$has_bytes" -eq 1 ]; then
                printf 'Total size to transfer: \033[1m%s\033[0m\n' "$(human_size "$total_bytes")"
            else
                printf 'Total size to transfer: \033[1m0 bytes\033[0m\n'
            fi
            if [ "$need_red" -eq 1 ] && [ -t 1 ]; then
                printf 'Available space on destination: \033[1;91m%s\033[0m\n' "$avail_human"
            else
                printf 'Available space on destination: \033[1m%s\033[0m\n' "$avail_human"
            fi
            printf -- '---------------------------\n\n'
        else
            printf '%s' "$plain_summary"
        fi
    fi
}

filter_rsync_output() {
    if [ "$list_files" -eq 1 ]; then
        output=$(awk '
            function human_readable(bytes) {
                if (bytes == 0) return "0 B"
                units = "B KB MB GB TB PB"
                scale = 1024
                i = 1
                while (bytes >= scale && i < 7) {
                    bytes = bytes / scale
                    i++
                }
                split(units, u, " ")
                return sprintf("%.2f %s", bytes, u[i])
            }
            ($1 ~ /^[0-9]+$/) {
                size=$1
                name=""
                for (i=2;i<=NF;i++) name = name (i>2?" ":"") $i
                hsize = human_readable(size)
                print hsize "  /" name
            }
        ' "$1") # dry list
        echo "$output"
    else
        output=$(grep -vE '(^[[:space:]]*(Number of files:|Number of created files:|Number of deleted files:|Number of regular files transferred:|Total file size:|Total transferred file size:|Literal data:|Matched data:|File list size:|File list generation time:|File list transfer time:|Total bytes sent:|Total bytes received:|sent |speedup|total size is|\[.*\].*))' "$1" || true)

    fi
}

if [ "$dry_run" -eq 1 ]; then
    tmp_out=$(mktemp /tmp/backup_root.rsync.XXXXXX)
    if [ "$list_files" -eq 1 ]; then
        ionice -c3 nice -n 19 rsync "${rsync_opts[@]}" -i --dry-run --out-format="%l %n" >"$tmp_out" 2>&1 || true # dry list
    else
        ionice -c3 nice -n 19 rsync "${rsync_opts[@]}" --dry-run --out-format="%l %n" >"$tmp_out" 2>&1 || true # dry 
    fi
    if [ -f "$tmp_out" ]; then
        tmp_new=$(mktemp /tmp/backup_root.rsync.XXXXXX)

        TEMP_FILES=( "$tmp_out" "$tmp_new" )

        cleanup_temps() {
            last_signal=INT
            rm -f "${TEMP_FILES[@]}"
            trap - INT
            kill -INT $$
        }
        trap cleanup_temps_trap INT
    
        awk -v is_tty="$([ -t 1 ] && echo 1 || echo 0)" '
            BEGIN {
                red="\033[91m"
                reset="\033[0m"
                kde_error_count = 0
                other_error_count = 0
            }

            /^rsync: \[generator\] copy_xattrs: lsetxattr\(.*"user\\.kde\\.fm\\.viewproperties#1"\)/ {
                kde_error_count++
                next
            }

            /^rsync:/ && !/copy_xattrs: lsetxattr.*user\\.kde\\.fm\\.viewproperties/ {
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
                kde_error_count = 0
                other_error_count = 0
                next
            }

            /error:/ && !(/user\\.kde\\.fm\\.viewproperties/) {
                if (is_tty)
                    print red $0 reset
                else
                    print
                next
            }

            /building file list/ { next }
            /files to consider/ { next }

            { print }
        ' "$tmp_out" > "$tmp_new"

        mv "$tmp_new" "$tmp_out"
        trap 'last_signal=INT; exit' INT
    fi
    filter_rsync_output "$tmp_out"
    summarize_rsync_output "$tmp_out"
    rm -f "$tmp_out"
    rm -rf "$snapshot_dir"
    exit 0
fi

tmp_out=$(mktemp /tmp/backup_root.rsync.XXXXXX)

calculate_total_bytes() {
    local rsync_dry_tmp=$(mktemp /tmp/backup_root.rsync.dry.XXXXXX)
    
    ionice -c3 nice -n 19 rsync "${rsync_opts[@]}" --dry-run --out-format='%l %n' >"$rsync_dry_tmp" 2>&1 || true
    
    # Count number of files (lines where first field is a number)
    local total_files=$(awk '($1 ~ /^[0-9]+$/) { count++ } END { if (count > 0) print count; else print 0 }' "$rsync_dry_tmp")

    rm -f "$rsync_dry_tmp"
    printf "%s" "$total_files"
}

draw_progress_bar() {
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
    
    printf "\r%-50s %3d%% (%s / %s)" \
        "$bar" \
        "$percent" \
        "$(human_size "$current")" \
        "$(human_size "$total")"
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

    # Format numbers with thousand separator (dot)
    local current_fmt=$(printf "%'d" "$current" | sed "s/,/./g")
    local total_fmt=$(printf "%'d" "$total" | sed "s/,/./g")

    printf "\r%-50s %3d%% (%s / %s files)" \
        "$bar" \
        "$percent" \
        "$current_fmt" \
        "$total_fmt"
}

set +e
if [ "$progress_bar" -eq 1 ]; then
    log "Starting backup with progress bar..."
    total_files=$(calculate_total_bytes)

    if [ "$total_files" -le 0 ]; then
        total_files=1
    fi
    
    tmp_err=$(mktemp /tmp/backup_root.rsync.err.XXXXXX)
    
    ionice -c3 nice -n 19 rsync "${rsync_opts[@]}" --out-format='%l %n' --info=progress2 >"$tmp_out" 2>"$tmp_err" &
    rsync_pid=$!
    
    current_files=0
    
    while kill -0 "$rsync_pid" 2>/dev/null; do
        sleep 0.5
        
        if [ -f "$tmp_out" ]; then
            # count files seen so far (lines starting with size)
            current_files=$(awk '($1 ~ /^[0-9]+$/) { count++ } END { if (count > 0) print count; else print 0 }' "$tmp_out")

            if [ "$current_files" -gt "$total_files" ]; then
                current_files=$total_files
            fi

            draw_progress_bar_count "$current_files" "$total_files"
        fi
    done
    
    wait "$rsync_pid"
    rsync_rc=$?
    
    current_files=$(awk '($1 ~ /^[0-9]+$/) { count++ } END { if (count > 0) print count; else print 0 }' "$tmp_out")
    if [ "$current_files" -gt "$total_files" ]; then
        current_files=$total_files
    fi
    draw_progress_bar_count "$current_files" "$total_files"
    printf "\n"
    
    if [ -f "$tmp_err" ]; then
        grep -vE 'xfr#|to-chk=|[0-9]+%|[0-9]+([\\.,][0-9]+)?(B|KB|MB|GB)/s' "$tmp_err" >> "$tmp_out" 2>/dev/null || true
    fi
    
    rm -f "$tmp_err" || true
elif [ "$progress_file" -eq 1 ]; then
    tmp_err=$(mktemp /tmp/backup_root.rsync.err.XXXXXX)

    ionice -c3 nice -n 19 rsync "${rsync_opts[@]}" --out-format='%l %n' --info=progress2 >"$tmp_out" 2>"$tmp_err" & # real progress
    rsync_pid=$!
    
    tail -n +1 -F "$tmp_out" 2>/dev/null | awk '
        function human_readable(bytes) {
            if (bytes == 0) return "0 B"
            units = "B KB MB GB TB PB"
            scale = 1024
            i = 1
            while (bytes >= scale && i < 7) {
                bytes = bytes / scale
                i++
            }
            split(units, u, " ")
            return sprintf("%.2f %s", bytes, u[i])
        }

        BEGIN {
            current_progress = "0%"
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

            hr_size = human_readable(size)
            printf "%-4s |  %-10s | /%s\n", current_progress, hr_size, filename
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
        grep -vE 'xfr#|to-chk=|[0-9]+%|[0-9]+([\\.,][0-9]+)?(B|KB|MB|GB)/s' "$tmp_err" >> "$tmp_combined" 2>/dev/null || true
    fi

    if grep -qE 'xfr#|to-chk=|[0-9]+%|[0-9]+([\\.,][0-9]+)?(B|KB|MB|GB)/s' "$tmp_combined" 2>/dev/null; then
        tmp_combined_filtered=$(mktemp /tmp/backup_root.rsync.combined.filtered.XXXXXX)
        grep -vE 'xfr#|to-chk=|[0-9]+%|[0-9]+([\\.,][0-9]+)?(B|KB|MB|GB)/s' "$tmp_combined" > "$tmp_combined_filtered" 2>/dev/null || true
        mv "$tmp_combined_filtered" "$tmp_combined" || true
    fi
    mv "$tmp_combined" "$tmp_out" || true
    rm -f "$tmp_err" || true
else
    ionice -c3 nice -n 19 rsync "${rsync_opts[@]}" --out-format='%l %n' >"$tmp_out" 2>&1 # real
    rsync_rc=$?
fi
set -e
summarize_rsync_output "$tmp_out"
echo -e "\n"

if [ "${real_run:-0}" -eq 1 ] && [ -n "$logfile" ]; then
    {
        echo -e "\n----- Transfered files -----"
        grep -v "[0-9]\\+ files\\.\." "$tmp_out" | sort -k2
        echo "----------------------------------------"
    } >> "$logfile"
fi
rm -f "$tmp_out"

if [ "${real_run:-0}" -eq 1 ] && [ "${rsync_rc:-0}" -eq 0 ]; then
    tmp_link="$dest_base/last_tmp"
    ln -s "$snapshot_dir" "$tmp_link"
    mv -T "$tmp_link" "$dest_base/last"
    log "Link updated: $dest_base/last -> $snapshot_dir"
else
    log_err "Rsync failed (code ${rsync_rc:-}) - the link '$dest_base/last' was NOT updated."
fi
if [[  "$dest_base" != *"home"* ]]; then
    cd "$dest_base/last"
    mkdir -p mnt tmp sys run proc dev home boot/efi || true
fi
log "Backup finished and link updated: $dest_base/last -> $snapshot_dir"
exit 0
