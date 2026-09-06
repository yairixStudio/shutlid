# Shutlid

Shutlid keeps a MacBook running with the lid closed: processes, SSH sessions,
dev servers and downloads carry on as if the lid were open, on battery or on
AC, with no external display or peripheral attached. The scenario it is built
for is a MacBook closed and in a bag while a long job (an AI coding agent, a
build, a transfer) finishes. It is for developers who run such jobs, and for
the local agents that run them: a menu-bar switch for people, a three-command
CLI for agents. It does one thing and turns itself off after 24 hours unless
told otherwise.

Status: the physical closed-lid test on battery ([MANUAL_TESTING.md](MANUAL_TESTING.md))
has not been run yet on the M4; until it passes, closed-lid support is a design
claim backed by the kernel source, not a verified one.

How it works and what was rejected: [RESEARCH.md](RESEARCH.md).

## Install

1. Download `Shutlid-<version>.dmg` from
   [Releases](https://github.com/yairixStudio/shutlid/releases), or build it
   yourself (see [Build](#build)).
2. Move `Shutlid.app` to `/Applications`. Setup links the command line to the
   app's location, so the app must already be where it will stay.
3. Open Shutlid and choose **Turn On** from the menu-bar icon. The first time,
   Shutlid asks for a one-time administrator authorization through the standard
   macOS dialog and installs the three items listed under
   [What setup installs](#what-setup-installs). Or run the same setup yourself:

```sh
sudo "/Applications/Shutlid.app/Contents/MacOS/shutlid" setup
```

If macOS refuses to open an unsigned build, right-click the app and choose
Open (or allow it under System Settings › Privacy & Security). Move a
downloaded app with the Finder: an app copied with `cp` or unzipped straight
into `/Applications` keeps its quarantine flag, macOS then runs a temporary
copy of it, and setup refuses that copy. Dragging it out of the folder and
back in with the Finder clears the condition.

After setup, `shutlid` is on your `PATH` and neither the app nor the CLI ever
asks for a password again.

## Menu bar

The icon shows one of three states; the first menu line spells it out.

- `● Keeping awake — auto-off in 23h 12m` (sun icon): sleep is prevented. Reads `— no auto-off` when Auto-off is Never, and `— auto-off expired` if the deadline passed while the app was not running. Menu offers **Turn Off**.
- `◐ On battery — keeps awake when plugged in` (dim sun): requested, but the mode is "only while connected to power" and the Mac is on battery. Menu offers **Turn Off**.
- `○ Normal sleep` (moon): macOS sleeps as usual. Menu offers **Turn On**.

**Settings…** has exactly four rows; every change is saved at once.

- **Mode**: Always (default) / Only while connected to power.
- **Auto-off after**: 1, 4, 8 or 24 hours (default) / Never. Changing it while on restarts the countdown.
- **After restart**: Return to normal sleep (default) / Restore previous state. Restore happens when Shutlid next launches, so pair it with Launch at login.
- **Launch at login**: on / off, managed by macOS (System Settings › General › Login Items).

**Quit** returns the Mac to normal sleep before the app exits.

## CLI

```
shutlid on [--for <hours>]   keep the Mac awake, lid closed or not (--for: 1-720, overrides Auto-off)
shutlid off                  return to normal sleep
shutlid status               show what was requested and what macOS is actually doing
shutlid setup                one-time install of the privileged rule (run as root, see --help)
shutlid log                  show the last day of Shutlid events from the unified log
shutlid --version            print the version
shutlid --help               print this help
```

`status` prints exactly four lines. Before anything is turned on:

```
$ shutlid status
Requested:  OFF
Effective:  OFF
Mode:       always
Auto-off:   24h
```

After `shutlid on`:

```
Requested:  ON
Effective:  ON
Mode:       always
Auto-off:   in 23h 59m
```

`Requested` is what was asked for; `Effective` is what the kernel is doing
right now, read fresh every time. When they differ, the second line says why:
`Effective:  OFF (on battery; mode: only while connected to power)`,
`Effective:  OFF (not applied; run 'shutlid on' again)` or
`Effective:  ON (turn-off failed; run: sudo pmset disablesleep 0)`.

| Command | 0 | 1 | 2 |
|---|---|---|---|
| `on`, `off` | done | error | setup required |
| `status` | keeping awake (`Effective: ON`) | normal sleep (`Effective: OFF`) | |
| `setup` | done | error (as root) | refused before starting (not run as root; the message says what to do) |
| others | done | error | |

`on`, `off` and `status` refuse to run as root (`sudo shutlid on` would set the
flag under root's own preferences with nothing to turn it off). Results go to
stdout, errors to stderr.

## AI agents

The CLI is the agent interface. No GUI automation, no password prompts after
setup:

```
User:  Keep my Mac awake, I'm closing the lid.
Agent: shutlid on
...
User:  You can let it sleep now.
Agent: shutlid off
```

Two things an agent should know:

- `on` exits 0 when the request was recorded and applied where the mode
  allows. Read `status` (or its exit code) for the effective state.
- `on` launches Shutlid.app in the background, because the app owns the single
  auto-off timer. If the app cannot be launched and an auto-off is set, `on`
  turns the flag back off and exits 1 rather than leave the Mac awake with no
  deadline.

## Safety

A closed MacBook in a bag has nowhere to shed heat, and on battery it will run
until the battery is empty: while keep-awake is on, macOS's low-battery
emergency sleep is disabled along with every other kind of sleep. Do not leave
a closed, working laptop somewhere insulated.

The safety net is auto-off: 24 hours by default, adjustable in Settings…
(1h / 4h / 8h / 24h / Never) or per call with `shutlid on --for <hours>`.
Turning on again resets the countdown; `status` shows the remaining time.
Auto-off is enforced by the menu-bar app, which the CLI launches for that
reason. The flag is a macOS system setting, not something the app holds: if the
app is killed or crashes, the Mac stays awake and auto-off cannot fire until
`shutlid off`, the app runs again, or a reboot (see
[Security model](#security-model)).

## What setup installs

Setup runs once as root and installs exactly three things. It is re-runnable.

1. `/etc/sudoers.d/shutlid` (root:wheel, 0440, checked with `visudo -cf`
   before it is put in place), containing one line:

   ```
   %admin ALL=(root) NOPASSWD: /usr/bin/pmset disablesleep 1, /usr/bin/pmset disablesleep 0
   ```

   sudo matches arguments literally, so nothing else is permitted.

2. `/Library/LaunchDaemons/com.yairix.shutlid.reset.plist`, a launchd job
   that runs `/usr/bin/pmset disablesleep 0` once at every boot and then
   exits. No process stays resident. Loading it during setup runs the reset
   once, so running setup while keep-awake is on turns it off.

3. `/usr/local/bin/shutlid`, a symlink to
   `/Applications/Shutlid.app/Contents/MacOS/shutlid`.

macOS lists the boot-reset job under System Settings › General › Login Items &
Extensions › Allow in the Background. If it is switched off there, the boot
reset does not run and a keep-awake left on may survive a restart; `status`
still reports reality.

## Security model

- **The flag is a system setting, not something the app holds.** Shutlid sets
  the `SleepDisabled` power setting through `pmset`. It survives the app
  quitting or crashing and, by powerd's source, it persists across a reboot;
  the boot-reset daemon undoes it at every boot either way. The app clears it
  when you quit or when auto-off fires; a crash or a hard kill leaves it set.
- **After setup, any program running under an admin account on this Mac can
  toggle sleep prevention without a password.** The rule covers two literal
  commands and nothing else, so it cannot be used to gain root or run anything
  else, but it does let any process keep the Mac awake or let it sleep. If
  that is not acceptable on your machine, do not install Shutlid.
- **Resetting always works.** `shutlid off`, `sudo pmset disablesleep 0` or a
  reboot returns the Mac to normal sleep, whether or not the app is running.
- After setup, no custom code runs as root; the only privileged command is
  Apple's `/usr/bin/pmset`. The one exception is setup itself: `shutlid setup`
  runs as root once to write the three files listed above. The app and the CLI
  call
  `sudo -k -n /usr/bin/pmset disablesleep 1|0` (`-k` ignores cached
  credentials so the call succeeds only through the installed rule). Passwords
  are never seen, stored or piped; the one-time setup uses the standard macOS
  administrator dialog. The CLI refuses to run `on`, `off` or `status` as
  root.

## Privacy

Shutlid collects nothing, transmits nothing, opens no network connection and
has no accounts, analytics, telemetry or identifiers. Its only stored state is
a handful of preferences in the UserDefaults suite `com.yairix.shutlid.state`.

## Log

Events go to Apple's unified log:

```sh
log show --predicate 'subsystem == "com.yairix.shutlid"' --last 1d --style compact
```

`shutlid log` runs that command. The entries are:

- `turned on (source: cli|gui|restore-after-restart|power-mode, auto-off: 24h)`; `auto-off:` is `never` or `in 3h 10m` as appropriate, with `, waiting for power` added when the request waits for AC.
- `turned off (source: gui|cli|auto-off|power-mode|restart-reset|quit)`.
- `settings changed: mode=always, autoOff=24h, restoreAfterRestart=false`.
- `power operation failed: <detail>` (error level).

Nothing else is logged. Note that `swift test` drives the same code against a
fake power controller, so a test run writes fake `turned on` / `turned off`
entries into this log.

## Uninstall

Dragging the app to the Trash does not undo setup. Run this from a clone of the
repo as your normal user (it calls `sudo` itself):

```sh
scripts/uninstall.sh
```

It quits the app, restores normal sleep (`pmset disablesleep 0`), removes the
boot-reset daemon, the sudoers rule and the symlink, deletes the app and its
preferences, and checks that password-less `pmset` access is gone. It touches
nothing else and works even if the app is already gone. If Launch at login was
on, remove Shutlid under System Settings › General › Login Items afterwards.

The DMG does not include the script. Without a clone, the same steps by hand:

```sh
pkill -x ShutlidApp
sudo pmset disablesleep 0
sudo launchctl bootout system/com.yairix.shutlid.reset
sudo rm -f /Library/LaunchDaemons/com.yairix.shutlid.reset.plist /etc/sudoers.d/shutlid /usr/local/bin/shutlid
rm -rf /Applications/Shutlid.app
defaults delete com.yairix.shutlid.state
```

## Supported macOS

macOS 14 or later, Apple Silicon only. Built and unit-tested on macOS 27 beta
on a MacBook Pro (M4 Pro). Verified there against the real kernel flag: setup,
`shutlid on` (`SleepDisabled 1`, app launched, auto-off armed), `shutlid off`
(`SleepDisabled 0`), `status` and the log entries. The physical closed-lid test
on battery, which is what would justify a claim of closed-lid support, is
written up in [MANUAL_TESTING.md](MANUAL_TESTING.md) and has not been run yet.

## Known limitations

- If the app crashes or is killed hard while on, the flag stays set and
  auto-off cannot fire until the app runs again, `shutlid off` is run, or the
  Mac restarts.
- The built-in display may stay lit under the closed lid until the
  display-sleep timer fires (10 minutes on battery by default). Unverified;
  see [RESEARCH.md §4](RESEARCH.md).
- Moving `Shutlid.app` breaks the `/usr/local/bin/shutlid` symlink; run setup
  again from the new location and re-enable Launch at login.
- Not feasible for the Mac App Store: the sandbox cannot run `sudo`.
- `pmset disablesleep` is undocumented. It has been stable for over a decade,
  but Apple could change it. Everything that touches it is in one file,
  `Sources/ShutlidCore/PowerController.swift`; a failure shows in `status`.

## Build

Swift Package Manager only, no Xcode project, no dependencies.

```sh
swift build            # debug build of the CLI, the app binary and the library
swift test             # ShutlidCore tests (writes fake events into the log; see Log)
scripts/build.sh       # release build, assembles and signs dist/Shutlid.app
```

Only `scripts/build.sh` produces a runnable app bundle; setup and Launch at
login need the binaries inside `dist/Shutlid.app`, so use that for anything
beyond unit tests.

`scripts/build.sh` takes `--dmg` (also writes `dist/Shutlid-<version>.dmg`)
and `--notarize` (submits to Apple and staples). Environment:

- `SIGN_IDENTITY`: codesign identity; default `-` (ad hoc, local use only). `--notarize` needs a Developer ID here.
- `NOTARY_PROFILE`: `notarytool` keychain profile for `--notarize`; default `shutlid`.
- `SWIFT_BUILD_ARGS`: extra arguments for `swift build`.

The app binary is `Contents/MacOS/ShutlidApp` (process name `ShutlidApp`,
shown as Shutlid); the CLI is `Contents/MacOS/shutlid` next to it.

## License

MIT. See [LICENSE](LICENSE).
