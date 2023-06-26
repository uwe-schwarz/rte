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
#     repo,path,exclude-file,sftp-command
#   examples:
#     # backup of home dir without any exclusions or special sftp-command
#     sftp:hostname:/backup/user-home,/home/user,,
#     # backup with exclusions and sftp-command
#     sftp:hostname:/backup/user-config,/home/user/.config,exclude-user-config,ssh -F $EXEC_DIR/ssh-config -s hostname sftp
#
#   Lines starting with # are ignored.
#   Don't include any special chars.
#   Variables get expanded via eval, so be careful.
#
# exit code is 0 on success, 2 if target/password not found, 1 on any other (restic) error
# if $1 exist it gets filled with a line containing path→repo pairs with errors, seperated by |   

errlog=""
exit_code=0

# targets and password file need to exist
if [ ! -f "$EXEC_DIR/RESTIC_TARGETS" -o ! -f "$EXEC_DIR/RESTIC_PASSWORD" ]; then
  echo "restic: coulnd't find targets or password file"
  echo "restic: coulnd't find targets or password file" > "$errlog"
  exit 2
fi

# files exist, error log is handled, let's start.

while IFS="," read repo path exclude_file sftp_command; do
  if [ -f "$EXEC_DIR/$exclude_file" ]; then
    exclude_file="$EXEC_DIR/$exclude_file"
  else
    exclude_file="/dev/null"
  fi
  sftp_command="$(eval echo $sftp_command)"

  echo "backing up $path → $repo"

  # check if repo exists
  restic cat config \
    -r "$repo" \
    --password-file "$EXEC_DIR/RESTIC_PASSWORD" \
    "$(if [ -n "$sftp_command" ]; then echo "-osftp.command=$sftp_command"; fi)" >/dev/null 2>/dev/null

  if [ $? -ne 0 ]; then
    echo "$repo doesn't exist yet, try to initialize it"

    # try init
    restic init \
      -r "$repo" \
      --password-file "$EXEC_DIR/RESTIC_PASSWORD" \
      "$(if [ -n "$sftp_command" ]; then echo "-osftp.command=$sftp_command"; fi)"

    if [ $? -ne 0 ]; then
      echo "$repo couldn't be initialized, giving up"
      errlog="$errlog|noinit $repo"
      exit_code=1
      continue
    fi
  fi

  # ok, looks like a backup is due
  restic backup "$path" \
    -r "$repo" \
    --verbose=2 \
    --password-file "$EXEC_DIR/RESTIC_PASSWORD" \
    -osftp.command="$sftp_command" \
    --exclude-file="$exclude_file" | \
      grep --line-buffered -v "^unchanged"

  # and something went wrong
  if [ $? -ne 0 ]; then
    errlog="$errlog|err $path → $repo"
    exit_code=1
  fi
done < <(grep "^[^#]" "$EXEC_DIR/RESTIC_TARGETS" | sed 's/^ *//;s/ *,/,/g;s/, */,/g;s/ *$//')

if [ -f "$1" -a $exit_code -ne 0 ]; then
  echo "${errlog:1}" > "$1"
fi
# all done, exit with $exit_code (1 on error)
exit $exit_code
