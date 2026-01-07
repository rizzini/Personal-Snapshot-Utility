complete -c personal_snapshot_utility -e

complete -c personal_snapshot_utility -f -l root -d "Backup the system root (/)"
complete -c personal_snapshot_utility -f -l home -d "Backup the /home directory"

complete -c personal_snapshot_utility -f -n "__fish_seen_argument --root" -l run -d "Perform the actual backup"
complete -c personal_snapshot_utility -f -n "__fish_seen_argument --home" -l run -d "Perform the actual backup"
complete -c personal_snapshot_utility -f -n "__fish_seen_argument --root" -l dry-run -d "Simulate the backup without copying files"
complete -c personal_snapshot_utility -f -n "__fish_seen_argument --home" -l dry-run -d "Simulate the backup without copying files"

complete -c personal_snapshot_utility -f -n "__fish_seen_argument --root" -l list-files -d "Show list of files (only with --dry-run)"
complete -c personal_snapshot_utility -f -n "__fish_seen_argument --home" -l list-files -d "Show list of files (only with --dry-run)"
complete -c personal_snapshot_utility -f -n "__fish_seen_argument --root" -l progress-bar -d "Show aggregate progress bar (only with --run)"
complete -c personal_snapshot_utility -f -n "__fish_seen_argument --home" -l progress-bar -d "Show aggregate progress bar (only with --run)"
complete -c personal_snapshot_utility -f -n "__fish_seen_argument --root" -l progress-file -d "Show each file as it is copied (only with --run)"
complete -c personal_snapshot_utility -f -n "__fish_seen_argument --home" -l progress-file -d "Show each file as it is copied (only with --run)"
complete -c personal_snapshot_utility -f -n "__fish_seen_argument --root; and not __fish_seen_argument --list-files" -l help -s h -d "Show help and exit"
complete -c personal_snapshot_utility -f -n "__fish_seen_argument --home; and not __fish_seen_argument --list-files" -l help -s h -d "Show help and exit"

complete -c personal_snapshot_utility -f -n "not __fish_seen_argument --root; and not __fish_seen_argument --home" \
    -a "--root --home" -d "Select backup target"

complete -c personal_snapshot_utility -f -n "__fish_seen_argument --root; and not __fish_seen_argument --run; and not __fish_seen_argument --dry-run; and not __fish_seen_argument --list-files" \
    -a "--run --dry-run" -d "Choose execution mode"
complete -c personal_snapshot_utility -f -n "__fish_seen_argument --home; and not __fish_seen_argument --run; and not __fish_seen_argument --dry-run; and not __fish_seen_argument --list-files" \
    -a "--run --dry-run" -d "Choose execution mode"

complete -c personal_snapshot_utility -f -n "__fish_seen_argument --dry-run; and __fish_seen_argument --root; and not __fish_seen_argument --list-files" \
    -a "--list-files" -d "List files that would be copied (dry-run only)"
complete -c personal_snapshot_utility -f -n "__fish_seen_argument --dry-run; and __fish_seen_argument --home; and not __fish_seen_argument --list-files" \
    -a "--list-files" -d "List files that would be copied (dry-run only)"

complete -c personal_snapshot_utility -f -n "__fish_seen_argument --run; and __fish_seen_argument --root; and not __fish_seen_argument --progress-file; and not __fish_seen_argument --progress-bar; and not __fish_seen_argument --list-files" \
    -a "--progress-bar" -d "Show aggregate progress bar (only with --run)"
complete -c personal_snapshot_utility -f -n "__fish_seen_argument --run; and __fish_seen_argument --home; and not __fish_seen_argument --progress-file; and not __fish_seen_argument --progress-bar; and not __fish_seen_argument --list-files" \
    -a "--progress-bar" -d "Show aggregate progress bar (only with --run)"

complete -c personal_snapshot_utility -f -n "__fish_seen_argument --run; and __fish_seen_argument --root; and not __fish_seen_argument --progress-file; and not __fish_seen_argument --progress-bar; and not __fish_seen_argument --list-files" \
    -a "--progress-file" -d "Show each file as it is copied (only with --run)"
complete -c personal_snapshot_utility -f -n "__fish_seen_argument --run; and __fish_seen_argument --home; and not __fish_seen_argument --progress-file; and not __fish_seen_argument --progress-bar; and not __fish_seen_argument --list-files" \
    -a "--progress-file" -d "Show each file as it is copied (only with --run)"

complete -c personal_snapshot_utility -f -n "__fish_seen_argument --run; and __fish_seen_argument --root; and not __fish_seen_argument --snapshot_suffix; and not string match -r -- '--snapshot_suffix=.*' (commandline -opc); and not __fish_seen_argument --list-files" \
    -a "--snapshot_suffix=" -r -d "Add a suffix to the snapshot name (use with --run)"
complete -c personal_snapshot_utility -f -n "__fish_seen_argument --run; and __fish_seen_argument --home; and not __fish_seen_argument --snapshot_suffix; and not string match -r -- '--snapshot_suffix=.*' (commandline -opc); and not __fish_seen_argument --list-files" \
    -a "--snapshot_suffix=" -r -d "Add a suffix to the snapshot name (use with --run)"

complete -c personal_snapshot_utility -f -n "__fish_seen_argument --dry-run; and __fish_seen_argument --home; and __fish_seen_argument --list-files" \
    -a "--exclude=" -r -d "Exclude path from --list-files (repeatable)"

