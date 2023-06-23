#!/usr/bin/env bash

# set xdg_variables
APP="rte"

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/$APP"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/$APP"

if [ "$1" == "fda" ]; then
  # just exit, hopefully agent will get populated in full disk access setting
  exit 0
fi

if [ "$1" == "init" ]; then
  # handling of client initialization
  if [ "$2" == "--force" ]; then
    # force remove old installs
    rm -fr "$CONFIG_DIR" "$DATA_DIR"
    shift
  fi
  # check if CONFIiG_DIR already exists
  if [ -d "$CONFIG_DIR" ]; then
    echo "$CONFIG_DIR already exists, start with"
    echo "  $0 init --force <url>"
    echo "to reconfigure."
    exit 1
  fi

  mkdir -p "$CONFIG_DIR" "$DATA_DIR"
  chmod 700 "$CONFIG_DIR" "$DATA_DIR"

  echo "downloading defaults"
  rsync --quiet --timeout=5 "$2/defaults" "$CONFIG_DIR"
  if [ $? -ne 0 -a ! -f "$CONFIG_DIR/defaults" ]; then
    echo "can't reach $2 (or no config present), removing $CONFIG_DIR and giving up"
    rm -fr "$CONFIG_DIR" "$DATA_DIR"
    exit 2
  fi

  # initial git pull
  echo "getting the newest version from github and place it in $DATA_DIR"
  cd "$DATA_DIR"
  git clone https://github.com/uwe-schwarz/rte.git 2>&1 | sed 's/^/  /'

  # got main config files, get interval and create timers
  source "$CONFIG_DIR/defaults"

  echo "creating timers with interval=$interval"
  case $(uname) in
    Linux)
      echo "operating system is Linux, using a systemd user timer"
      echo "this creates a timer in ~/.config/systemd/user, maybe this is the wrong directory"
      mkdir -p ~/.config/systemd/user
      cat > ~/.config/systemd/user/rte.service << EOF
[Unit]
Description=rte
After=network.target
ConditionPathExists=$CONFIG_DIR

[Service]
Type=oneshot
ExecStart=$DATA_DIR/rte/rte.sh

[Install]
WantedBy=default.target
EOF
      cat > ~/.config/systemd/user/rte.timer << EOF
[Unit]
Description=Run "rte" every $interval seconds

[Timer]
OnBootSec=30min
OnUnitActiveSec=$interval

[Install]
WantedBy=timers.target
EOF
      systemctl --user daemon-reload
      systemctl --user enable --now "rte.timer"
      echo "systemd timer enabled."
      ;;
    Darwin)
      echo "operating system is macOS, using a fake application and launchd timer"
      mkdir -p ~/Applications
      osacompile -o ~/Applications/rte.app -e 'do shell script "'"$DATA_DIR"'/rte/rte.sh"'
      open -g -j -a ~/Applications/rte.app --args fda
      echo "give full disk access or the needed rights to ~/Applications/rte.app/Contents/MacOS/applet."
      echo "it's probably best to give fda rights, otherwise the errors will get fuzzy do debug later."
      echo "if there is no applet in the list, add ~/Applications/rte.app/Contents/MacOS/applet"
      read
      echo "making LaunchAgent"
      mkdir -p ~/Library/LaunchAgents
      cat > ~/Library/LaunchAgents/com.github.uwe-schwarz.rte.plist << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.github.uwe-schwarz.rte</string>
    <key>ProgramArguments</key>
    <array>
      <string>open</string>
      <string>-g</string>
      <string>-j</string>
      <string>-a</string>
      <string>$HOME/Applications/rte.app</string>
    </array>
    <key>StartInterval</key> 
    <integer>$interval</integer>
</dict>
</plist>
EOF
      launchctl unload ~/Library/LaunchAgents/com.github.uwe-schwarz.rte.plist >/dev/null 2>/dev/null
      launchctl load ~/Library/LaunchAgents/com.github.uwe-schwarz.rte.plist

      echo "don't remove ~/Applications/rte.app"
      ;;
    *)
      echo "unknown system, please create timer yourself: start $DATA_DIR/rte/rte.sh every $interval seconds."
      exit 3
      ;;
  esac

  exit 0
fi

# are there other arguments?
if [ $# -ne 0 ]; then
  echo "start like this for first invocation:"
  echo "$0 init [--force] <url>"
fi

# normal operation

# read defaults
cd "$CONFIG_DIR"
source "$CONFIG_DIR/defaults"

# check for battery power
if [ "$battery" == "no" ]; then
  pmset -g ps | grep -q "AC" || exit 0
fi

# hostname, only till first "."
export h="$(hostname | cut -d. -f1)"

# start time
t="$(date -u +%F-%H.%M.%S)"

# redownload config
rsync --quiet --timeout=5 "$config/defaults" "$CONFIG_DIR"
if [[ $? -ne 0 ]]; then
  # config host not reachable, quit quietly
  exit 0
fi

# variables again
source "$CONFIG_DIR/defaults"

# TODO interval changed handling

# local logfile and basic redirection
logfile="$(mktemp)"
exec >$logfile 2>&1 </dev/null

# make directory for logfile upload
ssh ${config/:*} "mkdir -p \"${config/*:}/logs/$h\""

# first thing update and restart if needed
cd "$DATA_DIR/rte"
git remote update >/dev/null 2>/dev/null
if git status -uno | grep -q "Your branch is behind"; then
  # there are updates, pull and restart
  git status
  git pull
  if [[ -f "$logfile" ]]; then 
    rsync --quiet --timeout=10 "$logfile" "$config/logs/$h/$t.update.log"
    rm -f "$logfile"
  fi
  # restart after upgrade
  exec $0
fi

# no more updates, all base config is ok, redirects done. Starting execution

# create temp file and download hostname-folder
export EXEC_DIR="$(mktemp -d)"
export DATA_DIR

rsync -r "$config/$h" "$EXEC_DIR"
chmod +x "$EXEC_DIR/$h/run"

# run hostname/run command and keep time
secstart="$(date +%s)"
echo "starting: $h/run"

# create $log as file for logging and $result as file for notify results
export log="$(mktemp)"
export result="$(mktemp)"

# run
if [ "$caffeinate" = yes -a "$(uname)" = Darwin ]; then
  caffeinate "$EXEC_DIR/$h/run"
  exit_code=$?
else
  "$EXEC_DIR/$h/run"
  exit_code=$?
fi
cat "$log"

# notify

# try to figure out if we should notify
notify_run=0
if [ "$notify_when" = "always" ]; then
  notify_run=1
elif [ "$notify_when" = "onerror" -a $exit_code -ne 0 ]; then
  notify_run=1
fi

if [ -x "$notify" -a $notify_run -eq 1 ]; then
  if [ -s "$result" ]; then
    echo "notifying: $notify_arg $(head -n 1 "$result")"
    "$notify" "$notify_arg" "$(head -n 1 "$result")"
  else
    echo "notifying: $notify_arg rte: run on $h completed with exit code $exit_code"
    "$notify" "$notify_arg" "rte: run on $h completed with exit code $exit_code"
  fi
fi

# remove temp files and directory
rm -f "$log" "$result"
rm -fr "$EXEC_DIR"

# conclude
secstop="$(date +%s)"
echo "completed: $h/run in $(($secstop-$secstart)) seconds, exit code $exit_code"

# upload logs and exit
rsync --quiet --timeout=10 "$logfile" "$config/logs/$h/$t.log"

# remove log
rm -f "$logfile"
exit 0
