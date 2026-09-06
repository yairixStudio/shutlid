# Manual testing on the physical machine

Closed-lid support on Apple Silicon is only claimed once the battery test below
has passed on the target machine. Record results in the table at the end.

Machine under test: MacBook Pro (M4 Pro), macOS 27. Fill in the exact build:
`sw_vers` and `shutlid --version` (prints `shutlid 1.0.0`).

Reading the log, used throughout (`shutlid log` runs the same command):

```bash
log show --predicate 'subsystem == "com.yairix.shutlid"' --last 1d --style compact
```

If `swift test` was run on this machine, its fake events are in the same log;
go by the timestamps.

## 0. Setup (once)

```bash
scripts/build.sh
cp -R dist/Shutlid.app /Applications/
sudo "/Applications/Shutlid.app/Contents/MacOS/shutlid" setup
shutlid status
```

Expected setup output:

```
installed /Library/LaunchDaemons/com.yairix.shutlid.reset.plist
installed /usr/local/bin/shutlid -> /Applications/Shutlid.app/Contents/MacOS/shutlid
installed /etc/sudoers.d/shutlid
Setup complete.
```

The GUI path is the same install: open Shutlid from /Applications and choose
Turn On; the app asks for the administrator password itself. It refuses with
"Move Shutlid to the Applications folder first." when run from anywhere else.

Expected `shutlid status` after setup, exit code 1:

```
Requested:  OFF
Effective:  OFF
Mode:       always
Auto-off:   24h
```

`pmset -g | grep SleepDisabled` prints nothing or a line ending in `0`.

Then open System Settings › General › Login Items & Extensions and record the
name shown for the boot-reset daemon under "Allow in the Background" (the plist
lists `com.yairix.shutlid` as its associated bundle, so it should appear as
Shutlid). Write it here: ______________________

## 1. Battery test (primary, must pass)

Start with a comfortable charge: low-battery sleep is disabled while keep-awake
is on.

1. Disconnect AC. Note the battery percentage: ______ %.
2. Start a timestamped long-running process in Terminal:
   ```bash
   while true; do date >> ~/shutlid-heartbeat.log; sleep 10; done
   ```
3. Start a remotely observable connection: an SSH session from another device
   into this Mac (System Settings › General › Sharing › Remote Login), or
   `python3 -m http.server 8000` and open `http://<this-mac-ip>:8000` from a phone.
4. Run `shutlid on`. Expected: exit 0 and
   ```
   Requested:  ON
   Effective:  ON
   Mode:       always
   Auto-off:   in 23h 59m
   ```
   The menu-bar icon switches to the filled sun; the menu's first line reads
   `● Keeping awake — auto-off in 23h 59m` and offers Turn Off.
   `pmset -g | grep SleepDisabled` prints a line ending in `1`. The log shows
   `turned on (source: cli, auto-off: 24h)`.
5. Close the lid. Wait at least 10 minutes. Note whether the panel stayed lit
   under the lid (look at the gap near the hinge in a dark room) and for how
   long: ______________________ (the unverified expectation from RESEARCH.md §4
   is that it stays lit until the display-sleep timer, `pmset -g | grep
   displaysleep`, 10 minutes by default on battery).
6. From the other device, verify the SSH session or the web server stayed
   reachable the whole time.
7. Open the lid. Verify the heartbeat log has no gap: the entries must be
   10 seconds apart for the whole closed-lid period.
   ```bash
   wc -l ~/shutlid-heartbeat.log      # about 6 lines per minute closed
   tail -3 ~/shutlid-heartbeat.log    # last entry within the last 10 seconds
   ```
8. Run `shutlid off`. Expected: exit 0, `Effective:  OFF`, `Auto-off:   24h`,
   `SleepDisabled` no longer `1`, log `turned off (source: cli)`.
   Close the lid; the Mac must sleep within about a minute (the heartbeat log
   stops). Open the lid.
9. Battery percentage now: ______ %.

## 2. AC test

Repeat steps 2 to 8 with the charger connected (display-sleep default on AC is
20 minutes, so step 5 may need longer to answer the panel question).

## 3. Auto-off

1. Settings… › Auto-off after: 1 hour. The log shows
   `settings changed: mode=always, autoOff=1h, restoreAfterRestart=false`.
   Run `shutlid on`; the status shows `Auto-off:   in 59m`. Leave the app
   running (it owns the timer; `on` launched it).
2. Leave the Mac (lid open or closed). After one hour: `shutlid status` shows
   `Requested:  OFF`, `Effective:  OFF`, `Auto-off:   1h` and exits 1; the log
   shows `turned off (source: auto-off)`.
3. Also test the CLI override: `shutlid on --for 1` prints `Auto-off:   in 59m`
   and logs `turned on (source: cli, auto-off: 1h)`. Then `shutlid off`.
4. Set Auto-off after back to 24 hours.

## 4. Restart

Default setting (After restart: Return to normal sleep). The app is running
during the restart, so it releases the flag on the way down:

1. `shutlid on`, confirm `Effective:  ON`.
   In the Restart dialog, uncheck "Reopen windows when logging back in" so
   macOS does not relaunch Shutlid itself.
2. Restart the Mac and log in. Do not open the app or run any command yet.
3. `pmset -g | grep SleepDisabled` must not print a line ending in `1`.
   `pgrep -x ShutlidApp` prints nothing. The log from before the restart ends
   with `turned off (source: quit)`.

Boot-reset daemon on its own (the flag persists across a reboot by powerd's
source; this proves the daemon undoes it without the app):

1. `shutlid on`, then `pkill -9 -x ShutlidApp` (a simulated crash: SIGKILL
   skips the release). `pmset -g | grep SleepDisabled` still shows `1`.
2. Restart the Mac and log in. Before opening anything:
   `pgrep -x ShutlidApp` prints nothing and `pmset -g | grep SleepDisabled`
   prints nothing or a line ending in `0`. That is the daemon's work.
3. `shutlid status` now prints `Requested:  ON` and
   `Effective:  OFF (not applied; run 'shutlid on' again)`: the stale request
   is cleared only when the app next launches. `open -a Shutlid`, then
   `shutlid status` shows `Requested:  OFF`, `Effective:  OFF` and the log
   shows `turned off (source: restart-reset)`.

Restore previous state:

1. Settings… › After restart: Restore previous state; Launch at login: on
   (approve it in System Settings if the hint asks).
2. `shutlid on`, restart, log in.
3. Within a few seconds of login: `shutlid status` shows `Effective:  ON` with a
   fresh `Auto-off:   in 23h 59m`, not the deadline from before the restart.
   The log shows `turned on (source: restore-after-restart, auto-off: 24h)`.
4. Turn both settings back to their defaults afterwards.

## 5. Power mode "Only while connected to power"

1. Settings… › Mode: Only while connected to power. Charger connected. The log
   shows `settings changed: mode=onlyOnPower, autoOff=24h, restoreAfterRestart=false`.
2. `shutlid on`, expected `Effective:  ON` and
   `Mode:       only while connected to power`. Close the lid.
3. Unplug the charger with the lid closed. The Mac must sleep within about a
   minute (heartbeat log stops). The log shows `turned off (source: power-mode)`.
4. Plug the charger back in. Whether a sleeping closed-lid Mac wakes on AC is
   not guaranteed; note what happened: ______________________. If it did not
   wake, open the lid. Once awake, within a few seconds `shutlid status` shows
   `Effective:  ON` and the log shows
   `turned on (source: power-mode, auto-off: in 23h ..m)`.
5. Unplug again with the lid open: `shutlid status` prints `Requested:  ON`,
   `Effective:  OFF (on battery; mode: only while connected to power)`, exits 1,
   and the menu's first line reads `◐ On battery — keeps awake when plugged in`.
6. `shutlid off`, set Mode back to Always.

## 6. Quit and uninstall

1. `shutlid on`, then Quit from the menu. `pmset -g | grep SleepDisabled` no
   longer shows `1`; the log shows `turned off (source: quit)`.
2. Make sure Launch at login is off, then run `scripts/uninstall.sh` as your
   normal user (it calls sudo itself and asks for the password once). Expected
   output, steps `1/8 quitting Shutlid` through `8/8 checking that
   password-less pmset access is gone`, then `    revoked` and `done`.
3. Verify nothing is left:
   ```bash
   ls /etc/sudoers.d/shutlid /Library/LaunchDaemons/com.yairix.shutlid.reset.plist \
      /usr/local/bin/shutlid /Applications/Shutlid.app   # all: No such file or directory
   defaults read com.yairix.shutlid.state                # does not exist
   sudo -k -n -l /usr/bin/pmset disablesleep 1           # fails: a password is required
   ```

## Results

| Test | Date | Build | Result | Notes |
|---|---|---|---|---|
| 1. Battery, lid closed 10+ min, SSH stayed up, no heartbeat gap | | | | |
| 1. Panel lit under lid? for how long | | | | |
| 1. `off` then lid close sleeps within ~1 min | | | | |
| 2. AC | | | | |
| 3. Auto-off 1h fires and is logged | | | | |
| 4. Restart, default: OFF without opening the app | | | | |
| 4. Restart after SIGKILL: daemon cleared the flag, app logs restart-reset | | | | |
| 4. Restart, restore: ON at login with fresh deadline | | | | |
| 5. Power mode unplug → sleeps, replug → ON again (woke on AC?) | | | | |
| 6. Quit releases; uninstall clean and revoked | | | | |
| Login Items display name of the boot-reset daemon | | | | |
