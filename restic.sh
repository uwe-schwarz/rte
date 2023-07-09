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
#     repo,exclude-file,path1,path2,path3,…,pathn
#   examples:
#     # backup of home dir without any exclusions
#     rclone:host:backup/user-home,,/home/user
#     # backup with exclusions
#     rclone:host:backup/user-config,exclude-user-config,/home/user/.config
#     # backup as root (add sudo: before repo name)
#     sudo:rclone:host:etc,,/etc
#     #   (sudo must be possible without password)
#     # multi-path, local repo
#     /backup/home,exclude-home,/home/user,/opt,/mnt
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
forget=($(awk '/RESTIC:[[:space:]]*forget=/{sub(/^.*RESTIC:[[:space:]]*forget=/,""); print}' "$EXEC_DIR/RESTIC_TARGETS"))

# files exist, error log is handled, let's start.

while IFS="," read repo exclude_file path_all; do
  if [ -f "$EXEC_DIR/$exclude_file" ]; then
    exclude_file="$EXEC_DIR/$exclude_file"
  else
    exclude_file="/dev/null"
  fi

  paths=()
  while read path_element; do
    paths+=("$path_element")
  done < <(tr "," "\n" <<< "$path_all")
  path_echo="$(printf ", %s" "${paths[@]}")"
  path_echo="${path_echo:2}"
  echo "backing up $path_echo → $repo"

  # run as root?
  if [ "${repo:0:5}" = "sudo:" ]; then
    repo="${repo:5}"
    if command -v setcap >/dev/null 2>/dev/null; then
      sudo setcap "CAP_DAC_READ_SEARCH+ep" "$(command -v restic)"
      unset sudo
    else
      sudo=("sudo" "-E")
    fi
  else
    unset sudo
  fi

  # set arguments for restic
  args=("-r" "$repo")
  args+=("--password-file" "$EXEC_DIR/RESTIC_PASSWORD")

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
    errlog="$errlog|err $path_echo → $repo"
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

  # remove capability
  if command -v setcap >/dev/null 2>/dev/null; then
    sudo setcap "CAP_DAC_READ_SEARCH-ep" "$(command -v restic)"
  fi
done < <(grep "^[^#]" "$EXEC_DIR/RESTIC_TARGETS" | sed 's/^ *//;s/ *,/,/g;s/, */,/g;s/ *$//')

if [ -f "$1" -a $exit_code -ne 0 ]; then
  echo "restic: ${errlog:1}" >> "$1"
fi
# all done, exit with $exit_code (1 on error)
exit $exit_code
