# rte

remote timed executions

## motivation

I manage devices for my family and therefore need to backup the data. There are
a few obstacles:
- I don't want my own user on those devices, I just don't want to be
  responsible if anything breaks.
- I still want to provide some comfort by backing up essential data.
- Immediate transfer between devices is managed elsewhere (iCloud in my case).
- Backup should just work and I want to get the errors without any interaction
  from my family.

That's the reasons I wrote this script, basically all of this can achieved via
other means. The first version I build was written around [rsync time backup](https://github.com/laurent22/rsync-time-backup/),
but I found out that this isn't supported by [Hetzner Storage Boxes](https://www.hetzner.com/storage/storage-box).
Therefore I switched the backup solution and wanted something even more simple,
so it's just now a pull wahtever is there and execute that.

## config server and connectivity

Config is provided via ssh from somewhere, this should most likely be running
24/7.

The config for the whole system is kept on this system and must be
accessible from the clients. I'm using [Tailscale](https://tailscale.com) with
[SSH integration](https://tailscale.com/tailscale-ssh/) to offer a fairly
simple way to just connect via ssh. SSH access must be possible.

My setup:
```
/backup → symlink to a mountpoint with enough space
/backup/config → directory with all the configs and logs
/backup/config/logs/$hostname → output of backups, including stderr
/backup/config/$hostname/run → script which gets executed
```

## client

Every client needs bash, git, ssh and rsync.

Download `rte.sh` and run `backup.sh nit <url>`. url is the
config-directory-endpoint and must be accessible via rsync:

> user@hostname:/backup/config

The script uses two directories:
- ~/.config/rte
- ~/.local/share/rte

(It tries to respect `XDG_CONFIG_HOME` and `XDG_DATA_HOME`.)

On Linux a `systemd` timer gets created. On macOS a application gets created
and a launchd timer created. This application needs most likely full disk
access.

## config

Everything in /backup/config (see previous chapter) is just simple files, there
is just a single config file. This config gets redownloaded on every run and a
change of location is possible, just keep the old one around long enough for
all clients to pick up the new one.

Config file:

/backup/config/defaults (shell like variables)
```
# config url changes get saved on the next run, keep the old place available for some time
config=user@hostname:/backup/config

# run every x seconds
interval=10800

# run on battery power (macOS only for now)
# battery=no means it *doesn't* run on battery power
battery=no

# use caffeinate (only macOS) to prevent sleep
caffeinate=yes

# notify script
# there is no mechanic to update this to something else.
# you can use the executed script to place another script somewhere, even in
# $DATA_DIR (it's available inside the script).
notify=$DATA_DIR/rte/notify.sh

# notify_arg is the first argument for the notify-script, this can include `$h`
# for the hostname.
notify_arg=topic_$h

# notify_when has this possible values:
# never = never notify, this is the default
# onerror = notify if exit code is not zero
# always = notify on every exit code
notify_when=onerror
```

Then there is an additional directory:

> /backup/config/hostname

you can place anything inside, it gets downloaded (on every run) to the client.
The file `run` inside this directory gets executed. The current directory is
set to the place of `run`, there is also a `$EXEC_DIR` with the temp-directory
and `$log` where log output can be redirected. Stdout and stderr gets also
logged.

If you want to use notifications, you can populate the file `$result`, the
first line gets send to the notify script as second argument.

## log files

log files (simple redirect from stdout/stderr) will get uploaded to
`$config/logs/$hostname/$(date -u +%F-%H.%M.%S).log`. Updates will have a
update.log extenstion.

## caveats

I use this only with tailscale and therefore don't need to handle ssh-keys. It
should just work, but no guarantee.
