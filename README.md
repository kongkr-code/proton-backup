## Proton Drive Proxmox LXC Backup Script
This script will automate the backup of LXC containers from Proxmox to Proton Drive via the CLI.
It will check for existing backups and skip them, and will delete old backups according to the retention setting.

To be able to login to Proton Drive, there is need for a D-bus Keyring, a password of your choosing, to associate with the Proton Drive login.

## Install system dependencies
Run:
```bash
apt update && apt install -y dbus-user-session gnome-keyring jq curl
``` 

What each one is for: dbus-user-session gives you dbus-run-session (needed to create a proper session for the keyring daemon on a headless server with no desktop). gnome-keyring provides gnome-keyring-daemon, which stores your Proton login session securely. jq is what the backup script uses to parse the JSON file listings from proton-drive. curl is just for downloading the CLI binary in the next step (usually already present on Proxmox).

## Install the Proton Drive CLI itself
Go to proton.me/drive/download on any browser, find the CLI download for Linux, and get the download URL (or use the wrapper repo's install helper if you prefer). 
On your server, download and extract it, then move the binary somewhere in your PATH, e.g.: 
```bash
mv proton-drive /usr/local/bin/proton-drive && chmod +x /usr/local/bin/proton-drive 
```

Verify with: 
```bash
proton-drive --help 
```

It should print the usage text (filesystem list/upload/download/etc.) we've already seen.

## Start a D-Bus session
Run: 
```bash
dbus-run-session -- bash 
```

This drops you into a subshell with a proper D-Bus session active. 
All the remaining setup steps happen inside this same shell — don't exit until told to.

## Create and unlock the keyring 
Inside that shell run: 
```bash
echo -n 'YourChosenPassword' | gnome-keyring-daemon --daemonize --login 
```

Since this is a brand new machine, no keyring file exists yet at ~/.local/share/keyrings/login.keyring (or /root/.local/share/keyrings/login.keyring if you're root). 
This command creates it on the spot, using 'YourChosenPassword' as its permanent unlock password from now on. 
Store that password somewhere safe — it's what goes into KEYRING_PASS in the backup script.

## Log in to Proton Drive
Still in the same shell, run: 
```bash
proton-drive auth login 
```

This starts a browser-based login — it'll print a URL (and possibly a code) to open on any device with a browser. 
Log in with your actual Proton account there. If Proton throws a CAPTCHA at you, the CLI will print instructions for a manual token-copy step — just follow those. Once it succeeds, your session gets saved into the keyring you just created.

## Verify the session actually persisted
Still in the same shell, run: 
```bash
proton-drive filesystem list /my-files 
```
It should print your Drive's root contents without asking you to log in again. If it does ask you to log in again, the session wasn't saved correctly — redo the previous two steps. Once it works, type exit to leave this temporary shell.

## Confirm it works the way cron will use it
Open a completely new terminal (simulating exactly what cron will do later) and run: 
```bash
dbus-run-session -- sh -c "echo -n 'YourChosenPassword' | gnome-keyring-daemon --daemonize --login; proton-drive filesystem list /my-files" 
```

If this also returns your file listing without prompting for login, everything is correctly wired together — you're ready to drop in the backup script itself, put your chosen password into its KEYRING_PASS variable, chmod +x it, and set up the cron job.

## Edit the script
Insert the keyring and set the local backup directory, and you are set to go.

```bash
KEYRING_PASS="YourChosenPassword"
LOCAL_BACKUP_DIR="/your/local/backup"
```

Other options
```bash
# Retention: how many of the newest backup RUNS to keep, per container ID
# (a "run" = the .log + .tar.zst + .tar.zst.notes trio sharing one timestamp)
KEEP_N=2

# Safety guards for the delete step
MIN_LOCAL_FILES=1        # abort delete step if fewer local files than this exist (mount hiccup guard)
MAX_DELETE_RATIO=50      # abort if more than this % of remote files would be deleted in one run
DRY_RUN=false             # set true to log what WOULD be deleted without deleting anything
```

