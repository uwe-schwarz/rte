#!/usr/bin/env bash

# restic example
# In your run-script just run "$DATA_DIR/rte/restic.sh"
#
# provide these files:
#   - $EXEC_DIR/RESTIC_PASSWORD
#   - $EXEC_DIR/RESTIC_TARGETS
#   - maybe some ssh-config
#
#   RESTIC_PASSWORD just includes a single line with the password to all repos
#
#   RESTIC_TARGETS has the following format:
#     repo,path,exclude-file,sftp-command,path2,path3,…,path9
#   examples:
#     # backup of home dir without any exclusions or special sftp-command
#     sftp:hostname:/backup/user-home,/home/user,,
#     # backup with exclusions and sftp-command
#     sftp:hostname:/backup/user-config,/home/user/.config,exclude-user-config,ssh -F $EXEC_DIR/ssh-config -s hostname sftp
#     # backup as root (add sudo: before repo name)
#     sudo:rclone:host:etc,/etc,,
#     #   (sudo must be possible without password)
#     # multi-path
#     rclone:host:home,/home/user,,/opt,/mnt
#
#   There can be these config options (anywhere in the file):
#     # RESTIC: forget=--keep-hourly 8 --keep-daily 30 --keep-monthly 24 --keep-yearly 5 --group-by host
#     → automatically forget and prune snapshots according to the policy
#       (see https://restic.readthedocs.io/en/latest/060_forget.html)
#
#   Lines starting with # are ignored.
#   Don't include any special chars.
#   Variables get expanded via eval, so be careful.
#
# exit code is 0 on success, 2 if target/password not found, 1 on any other (restic) error
# if $1 exist it gets filled with a line containing path→repo pairs with errors, seperated by |   

# try updating restic, don't do anything if it's not working
restic self-update >/dev/null 2>/dev/null

# if there is a rclone.conf in $EXEC_DIR and RCLONE_CONFIG is not set, just use it
if [ -f "$EXEC_DIR/rclone.conf" -a -z "$RCLONE_CONFIG" ]; then
  export RCLONE_CONFIG="$EXEC_DIR/rclone.conf"
fi

errlog=""
exit_code=0

# targets and password file need to exist
if [ ! -f "$EXEC_DIR/RESTIC_TARGETS" -o ! -f "$EXEC_DIR/RESTIC_PASSWORD" ]; then
  echo "restic: coulnd't find targets or password file"
  if [ -f "$1" ]; then
    echo "restic: coulnd't find targets or password file" >> "$1"
  fi
  exit 2
fi

# auto-forget?
forget=($(awk '/RESTIC:\s*forget=/{sub(/^.*RESTIC:\s*forget=/,""); print}' RESTIC_TARGETS))

# files exist, error log is handled, let's start.

while IFS="," read repo path exclude_file sftp_command path2 path3 path4 path5 path6 path7 path8 path9; do
  if [ -f "$EXEC_DIR/$exclude_file" ]; then
    exclude_file="$EXEC_DIR/$exclude_file"
  else
    exclude_file="/dev/null"
  fi
  sftp_command="$(eval echo $sftp_command)"

  paths=("$path")
  echo -n "backing up $path"
  if [ "$path2" ]; then echo -n ", $path2"; paths+=("$path2"); fi
  if [ "$path3" ]; then echo -n ", $path3"; paths+=("$path3"); fi
  if [ "$path4" ]; then echo -n ", $path4"; paths+=("$path4"); fi
  if [ "$path5" ]; then echo -n ", $path5"; paths+=("$path5"); fi
  if [ "$path6" ]; then echo -n ", $path6"; paths+=("$path6"); fi
  if [ "$path7" ]; then echo -n ", $path7"; paths+=("$path7"); fi
  if [ "$path8" ]; then echo -n ", $path8"; paths+=("$path8"); fi
  if [ "$path9" ]; then echo -n ", $path9"; paths+=("$path9"); fi
  echo " → $repo"

  # run as root?
  if [ "${repo:0:5}" = "sudo:" ]; then
    repo="${repo:5}"
    sudo=("sudo" "-E")
  else
    unset sudo
  fi

  # set arguments for restic
  args=("-r" "$repo")
  args+=("--password-file" "$EXEC_DIR/RESTIC_PASSWORD")
  if [ "$sftp_command" ]; then
    args+=("-osftp.command=$sftp_command")
  fi

  # verbose?
  verbose="${verbose:-2}"

  # check if repo exists
  ${sudo[@]} restic cat config "${args[@]}" >/dev/null 2>/dev/null

  if [ $? -ne 0 ]; then
    echo "$repo has some error, try unlocking"
    ${sudo[@]} restic unlock "${args[@]}"

    # check again
    ${sudo[@]} restic cat config "${args[@]}" >/dev/null 2>/dev/null

    if [ $? -ne 0 ]; then
      echo "$repo doesn't exist yet, try to initialize it"

      # try init
      ${sudo[@]} restic init "${args[@]}"

      if [ $? -ne 0 ]; then
        echo "$repo couldn't be initialized, giving up"
        errlog="$errlog|noinit $repo"
        exit_code=1
        continue
      fi
    fi
  fi

  # ok, looks like a backup is due
  ${sudo[@]} restic backup "${paths[@]}" "${args[@]}" \
    "--verbose=$verbose" \
    "--exclude-file=$exclude_file" | \
      grep --line-buffered -v "^unchanged"

  # and something went wrong
  if [ $? -ne 0 ]; then
    errlog="$errlog|err $path → $repo"
    exit_code=1
  fi

  # forget?
  if [ "${#forget[@]}" -ne 0 ]; then
    ${sudo[@]} restic forget "${args[@]}" "${forget[@]}" --prune
    if [ $? -ne 0 ]; then
      errlog="$errlog|err forget: $repo"
      exit_code=1
    fi
  fi
done < <(grep "^[^#]" "$EXEC_DIR/RESTIC_TARGETS" | sed 's/^ *//;s/ *,/,/g;s/, */,/g;s/ *$//')

if [ -f "$1" -a $exit_code -ne 0 ]; then
  echo "restic: ${errlog:1}" >> "$1"
fi
# all done, exit with $exit_code (1 on error)
exit $exit_code
