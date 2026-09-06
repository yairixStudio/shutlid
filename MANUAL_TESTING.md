# Manual testing on the physical machine

Closed-lid support on Apple Silicon is only claimed once the battery test below
has passed on the target machine. Record results in the table at the end.

Machine under test: MacBook Pro (M4 Pro), macOS 27. Fill in the exact build:
`sw_vers` and `shutlid --version`.

## 0. Setup (once)

```bash
# Build and install
scripts/build.sh
cp -R dist/Shutlid.app /Applications/
sudo "/Applications/Shutlid.app/Contents/MacOS/shutlid" setup
shutlid status
```

Expected after setup: `shutlid status` prints four lines with `Effective:  OFF`
and exits 1. `pmset -g | grep SleepDisabled` prints nothing or `SleepDisabled 0`.

Then open System Settings › General › Login Items & Extensions and record the
name shown for the boot-reset item (it runs `/usr/bin/pmset disablesleep 0` at
boot). Write it here: ______________________

## 1. Battery test (primary, must pass)

1. Disconnect AC. Note the battery percentage: ______ %.
2. Start a timestamped long-running process in Terminal:
   ```bash
   while true; do date >> ~/shutlid-heartbeat.log; sleep 10; done
   ```
3. Start a remotely observable connection: an SSH session from another device
   into this Mac (System Settings › General › Sharing › Remote Login), or
   `python3 -m http.server 8000` and open `http://<this-mac-ip>:8000` from a phone.
4. Run `shutlid on`. Expected: exit 0, `Effective:  ON`, `Auto-off:   in 23h 59m`.
   The menu-bar icon switches to the sun symbol. `pmset -g | grep SleepDisabled`
   prints `SleepDisabled 1`.
5. Close the lid. Wait at least 10 minutes. Note whether the panel stayed lit
   under the lid (look at the gap near the hinge in a dark room) and for how
   long: ______________________
6. From the other device, verify the SSH session or the web server stayed
   reachable the whole time.
7. Open the lid. Verify the heartbeat log has no gap: the entries must be
   10 seconds apart for the whole closed-lid period.
   ```bash
   wc -l ~/shutlid-heartbeat.log      # about 6 lines per minute closed
   tail -3 ~/shutlid-heartbeat.log    # last entry within the last 10 seconds
   ```
8. Run `shutlid off`. Expected: exit 0, `Effective:  OFF`, `SleepDisabled 0`.
   Close the lid; the Mac must sleep within about a minute (the heartbeat log
   stops). Open the lid.
9. Battery percentage now: ______ %.

## 2. AC test

Repeat steps 2 to 8 with the charger connected.

## 3. Auto-off

1. Settings… › Auto-off after: 1 hour. Run `shutlid on`; `status` shows
   `Auto-off:   in 59m`.
2. Leave the Mac (lid open or closed). After one hour: `shutlid status` shows
   `Requested:  OFF`, `Effective:  OFF`, and the log shows the event:
   ```bash
   log show --predicate 'subsystem == "com.yairix.shutlid"' --last 2h --style compact
   ```
   Expected line: `turned off (source: auto-off)`.
3. Also test the CLI override: `shutlid on --for 1` → `Auto-off:   in 59m`.

## 4. Restart

Default setting (After restart: Return to normal sleep):

1. `shutlid on`, confirm `Effective:  ON`.
2. Restart the Mac. Do not open the app or run any command.
3. `pmset -g | grep SleepDisabled` must print nothing or `SleepDisabled 0`.
   `shutlid status` must print `Requested:  OFF` and `Effective:  OFF`.

Restore previous state:

1. Settings… › After restart: Restore previous state; Launch at login: on.
2. `shutlid on`, restart, log in.
3. Within a few seconds of login: `shutlid status` shows `Effective:  ON` with a
   fresh `Auto-off:   in 23h 5xm`. The log shows
   `turned on (source: restore-after-restart, ...)`.
4. Turn both settings back to their defaults afterwards.

## 5. Power mode "Only while connected to power"

1. Settings… › Mode: Only while connected to power. Charger connected.
2. `shutlid on` → `Effective:  ON`. Close the lid.
3. Unplug the charger with the lid closed. The Mac must sleep within about a
   minute (heartbeat log stops). The log shows `turned off (source: power-mode)`.
4. Plug the charger back in. The Mac wakes (lid closed Macs wake on AC), and
   within a few seconds `shutlid status` (from SSH) shows `Effective:  ON`;
   the log shows `turned on (source: power-mode, ...)`.
5. Open the lid, `shutlid off`, set Mode back to Always.

## 6. Quit and uninstall

1. `shutlid on`, then Quit from the menu. `pmset -g | grep SleepDisabled` shows 0.
2. `scripts/uninstall.sh`. Expected: it restores sleep, removes the sudoers
   rule, the boot-reset daemon, the symlink, the app and the preferences, and
   ends with `sudo -n /usr/bin/pmset disablesleep 0` failing (revoked).
3. `sudo -n -l /usr/bin/pmset disablesleep 1` must now fail.

## Results

| Test | Date | Build | Result | Notes |
|---|---|---|---|---|
| 1. Battery, lid closed 10+ min, SSH stayed up, no heartbeat gap | | | | |
| 1. Panel lit under lid? for how long | | | | |
| 1. `off` then lid close sleeps within ~1 min | | | | |
| 2. AC | | | | |
| 3. Auto-off 1h fires and is logged | | | | |
| 4. Restart, default: OFF without opening the app | | | | |
| 4. Restart, restore: ON at login with fresh deadline | | | | |
| 5. Power mode unplug → sleeps, replug → awake | | | | |
| 6. Quit releases; uninstall clean and revoked | | | | |
| Login Items display name of the boot-reset daemon | | | | |
