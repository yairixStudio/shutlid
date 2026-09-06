#!/bin/bash
# Removes Shutlid completely: restores normal sleep, removes exactly what
# `shutlid setup` installed, the app, and its preferences. Nothing else.
# Works without the app or the CLI present. Asks for your password via sudo.
#
#   scripts/uninstall.sh
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
    echo "error: run this script as your normal user, not with sudo; it calls sudo itself" >&2
    exit 1
fi

plist=/Library/LaunchDaemons/com.yairix.shutlid.reset.plist
sudoers=/etc/sudoers.d/shutlid
link=/usr/local/bin/shutlid

echo "1/8 quitting Shutlid"
# Quit first so the running app cannot re-apply the flag between the next two steps.
pkill -x ShutlidApp 2>/dev/null || true
sleep 1

echo "2/8 restoring normal sleep"
sudo /usr/bin/pmset disablesleep 0

echo "3/8 removing the boot-time reset daemon"
sudo launchctl bootout system/com.yairix.shutlid.reset 2>/dev/null || true
sudo rm -f "$plist"

echo "4/8 removing the sudo rule"
sudo rm -f "$sudoers"
sudo visudo -c

echo "5/8 removing the command-line symlink"
app=/Applications/Shutlid.app
target=$(readlink "$link" 2>/dev/null || true)
case "$target" in
    /*/Shutlid.app/Contents/MacOS/shutlid)
        app=${target%/Contents/MacOS/shutlid}
        sudo rm -f "$link"
        ;;
    "")
        echo "    no symlink at $link"
        ;;
    *)
        echo "    $link points elsewhere ($target); left untouched"
        ;;
esac

echo "6/8 removing $app"
if [ -e "$app" ]; then
    rm -rf "$app" 2>/dev/null || sudo rm -rf "$app"
fi

echo "7/8 removing preferences"
defaults delete com.yairix.shutlid.state 2>/dev/null || true
defaults delete com.yairix.shutlid 2>/dev/null || true

echo "8/8 checking that password-less pmset access is gone"
sudo -k
if sudo -n /usr/bin/pmset disablesleep 0 2>/dev/null; then
    echo "    warning: sudo still allows pmset without a password; check /etc/sudoers.d and /etc/sudoers" >&2
else
    echo "    revoked"
fi

echo "done"
echo "If Launch at login was on, remove Shutlid in System Settings > General > Login Items."
