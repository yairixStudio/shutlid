# Research: keeping a MacBook awake with the lid closed

Date: 2026-09-06. Test machine: MacBook Pro (Mac16,8), Apple M4 Pro, macOS 27.0
beta (26A5425a), Xcode 26.6, Swift 6.3. SIP enabled. `sudo` requires a password.

Sources, in order of trust: the IOKit and ServiceManagement headers of the
installed SDK; Apple's open-source `xnu` (`IOPMrootDomain.cpp`,
`RootDomainUserClient.cpp`) and `PowerManagement` (`pmset.m`, `PMSettings.m`,
`PMAssertions.c`, `PMDisplay.m`, `BatteryTimeRemaining.m`) at their current
`main` (xnu-12377 / PowerManagement-1846, the macOS 26 line; this machine runs
xnu-13432, macOS 27 beta); the `pmset(1)` and `caffeinate(8)` man pages on this machine; safe
tests on this machine (nothing that needs root was run); prior art.

## 1. The mechanism

**`pmset disablesleep 1`.** It sets the system-wide power setting
`SleepDisabled`. `powerd` writes it to the kernel as the `SleepDisabled`
property of `IOPMrootDomain`, where it becomes `userDisabledAllSleep`, which the
kernel source calls the "user-space sleep kill switch". It is the first
condition checked in `IOPMrootDomain::checkSystemSleepAllowed()`, in the group
the source annotates as "conditions above pegs the system at full wake". Lid
close goes through `privateSleepSystem(kIOPMSleepReasonClamshell)` and the same
check, so the flag vetoes lid-close sleep, idle sleep and low-battery sleep
alike, on battery or AC, with no display or peripheral attached.

**Documented? No.** `disablesleep` does not appear in `pmset(1)` on this
machine nor in Apple's `pmset.1` source. It exists in `pmset.m`
(`ARG_DISABLESLEEP`) and has been stable across Intel and Apple Silicon for
well over a decade. Prior art relies on it: LidAwake-Mac, Sleepless (reports it
working on macOS 26.3 on battery with the lid closed), AwakeToggle, Helmlet.

**Reading the effective state needs no root.** The `SleepDisabled` property of
`IOPMrootDomain` is always present (`powerd` sets it to false at boot; on this
machine it reads `No`). `pmset -g` prints `SleepDisabled 1` when set.

## 2. Root and authorization

Setting the flag requires root. `pmset disablesleep 1` as a normal user prints
`'pmset' must be run as root...`; `powerd` enforces this, and setting the
kernel property directly is root-only as well.

Options for authorizing once and never per toggle:

| Option | Verdict |
|---|---|
| A. Scoped sudoers rule for two literal `pmset` command lines | **Chosen.** No custom code runs as root; only Apple's `pmset`. One admin authorization at setup. sudo and `sudoers.d` are decades-stable and macOS includes `/etc/sudoers.d` by default. |
| B. `SMAppService` LaunchDaemon + XPC | Rejected. The SDK header states "Apps that contain LaunchDaemons must be notarized", which breaks local and contributor builds; it runs our code as root, needs an XPC listener with client validation, and must be re-registered after every update or move. |
| C. Legacy LaunchDaemon helper + XPC | Rejected. Same custom root code and IPC as B, without B's system UI. |
| D. Admin prompt on every toggle (`osascript … with administrator privileges`) | Rejected for toggling (fails the no-password-per-toggle requirement). Used only to run the one-time setup from the GUI. |
| E. Non-root kernel selector (see §8) | Rejected for reliability. |
| F. `SMJobBless`, `AuthorizationExecuteWithPrivileges` | Deprecated. |

Chosen setup, run once as root (`sudo shutlid setup`, or the same command from
the app through the standard macOS administrator dialog):

1. `/etc/sudoers.d/shutlid` (root:wheel, 0440, validated with `visudo -cf`
   before installing):
   `%admin ALL=(root) NOPASSWD: /usr/bin/pmset disablesleep 1, /usr/bin/pmset disablesleep 0`
   sudoers matches arguments literally, so nothing else is permitted.
2. `/Library/LaunchDaemons/com.yairix.shutlid.reset.plist`: runs
   `/usr/bin/pmset disablesleep 0` once at boot. No resident process.
3. `/usr/local/bin/shutlid`, a symlink to the CLI inside the app bundle.

Afterwards the app and the CLI run `sudo -n /usr/bin/pmset disablesleep 1|0`.
No password is ever seen, stored or piped by this project.

## 3. Network with the lid closed

The system never enters sleep or dark wake, so there is no network transition:
Wi-Fi stays associated exactly as with the lid open. SSH sessions, dev servers
and downloads are unaffected. Physical verification pending (see
MANUAL_TESTING.md).

## 4. Behavior on battery

The kernel check has no power-source condition, so the flag holds on battery.
Consequences to state plainly:

- The Mac will not sleep for any reason until `off`, auto-off or a reboot.
  This includes macOS's low-battery emergency sleep (it takes the same vetoed
  path), so a forgotten session can drain the battery to a hardware power-off.
  The auto-off timer is the safety net.
- The built-in panel may stay lit under the closed lid until the display-sleep
  timer fires (default 10 min on battery, 20 min on AC). To verify physically.
  If confirmed, the fix is `pmset displaysleepnow` (documented, no root) on the
  public `kIOPMMessageClamshellStateChange` event. Not built until verified.

## 5. Reboot, quit, crash, logout, update, uninstall

- **Reboot.** `powerd` stores `SleepDisabled` in
  `/Library/Preferences/com.apple.PowerManagement.plist` and re-applies it at
  startup (`PMActivateSystemPowerSettings` in `PMSettings.m`), so by the source
  the flag persists. Sleepless reports it resets on macOS 26.3. Either way the
  boot-reset LaunchDaemon guarantees normal sleep after any restart without
  opening the app; running `disablesleep 0` when it is already 0 is a no-op.
- **App quit.** The app turns keep-awake off before exiting and logs it.
- **App crash.** The flag stays set and auto-off cannot fire until the app runs
  again (it re-checks the deadline at launch), `shutlid off` is run, or the Mac
  reboots. Documented as the known gap.
- **CLI crash.** Nothing lives in the CLI.
- **Helper crash.** There is no helper.
- **Logout.** The app is terminated by the session; its termination path turns
  keep-awake off. A hard kill leaves the flag until reboot.
- **OS update.** Ends in a reboot, which resets. `sudoers.d` and
  `/Library/LaunchDaemons` live on the data volume and survive updates. If a
  future macOS removes `disablesleep`, `on` fails loudly and `status` reports
  `Effective: OFF`.
- **Uninstall.** `uninstall.sh` restores normal sleep, then removes exactly the
  three installed files, the app, and its preferences.

## 6. Apple Silicon specifics

- `powerd` on arm64 re-evaluates its own clamshell-sleep state on every
  power-source change and forces it during sleep entry. This only matters for
  the rejected non-root selector (§8); `SleepDisabled` is a separate, kernel-
  level veto.
- `checkSystemCanSustainFullWake()` says a closed lid on battery cannot sustain
  full wake, but `userDisabledAllSleep` is evaluated before it and pegs full
  wake. Physical test should confirm processes run normally with the lid closed.
- Defaults on this M4 Pro: battery `sleep 1`, `displaysleep 10`,
  `hibernatemode 3`, `standby 1`. Not touched by this project.
- `AppleClamshellCausesSleep` reads `No` on this machine even with no display
  attached; the property is only refreshed on clamshell events and is not a
  usable indicator. Not used.

## 7. Compatibility risk with future macOS

| Piece | Status | Risk |
|---|---|---|
| `pmset disablesleep` / `SleepDisabled` | Undocumented, stable 15+ years, present in current sources | Apple could remove or gate it. Isolated in one file; failure is reported, never hidden. |
| `sudo`, `/etc/sudoers.d`, launchd plists, `/usr/bin/pmset` | Unix-stable | Negligible. |
| `IOPMrootDomain` `SleepDisabled` property (read) | Same lifetime as the flag | Same as above. |
| `SMAppService.mainApp` login item | Documented, macOS 13+ | Low. |
| `IOPSNotificationCreateRunLoopSource` (AC/battery events) | Documented | Low. |
| macOS "Background Items" UI (13+) | Shows the boot-reset daemon; a user can disable it | If disabled, the boot reset does not run. Documented. |

Supported: macOS 14 and later (SMAppService is 13+; tested on 27 beta).

## 8. Considered and rejected

- **`IOPMAssertion` / `caffeinate -i -d -s`**: assertions influence powerd's
  idle-sleep policy; lid close is a kernel demand sleep that assertions do not
  veto. `PreventSystemSleep` is marked "deprecated, not supported" in the SDK.
  KeepingYouAwake's author confirms closed-lid is unsupported.
- **Clamshell mode** (external display + AC + external input): irrelevant to a
  lid-closed MacBook in a bag.
- **Virtual display** (KeepAwake): fakes clamshell mode; the kernel still only
  ignores the lid when `desktopMode && acAdaptorConnected`, so it fails the
  battery case, and it stacks private display APIs, mouse jiggling and
  assertions on top. Far more machinery for a worse result.
- **`kPMSetClamshellSleepState`** (RootDomainUserClient selector 12, no
  privilege check, used by Amphetamine Enhancer's CDMManager): works without
  root, but it flips `kClamshellSleepDisablePowerd`, a bit `powerd` owns and
  rewrites on its own transitions (desktop mode, lid assertions, power-source
  change on arm64, first update after dark wake). That is the documented cause of
  Amphetamine's "failed closed-display mode sessions". It also still needs an
  idle-sleep assertion and fights a system daemon. Rejected.
- **Setting the kernel property directly**: root-only anyway, and would put
  our own code in the root path instead of Apple's `pmset`.
- **SMAppService daemon + XPC**: see §2.
- **Polling `AppleClamshellState`** (LidAwake-Mac): no polling; the public
  clamshell message exists if a lid event is ever needed.
- **DisplayServices brightness** (LidAwake-Mac): private API.
- **Battery floor / Low Power Mode cutoff** (Sleepless): needs polling or
  battery statistics; out of scope. Auto-off is the safety net. V1.1 candidate.
- **`pmset -b sleep 0`**: idle sleep only.
- **Mac App Store**: the sandbox cannot run `sudo`. Not feasible; Developer ID
  + notarization instead.

## 9. Resulting architecture (Phase 2)

**Components required**

1. `Shutlid.app`: AppKit menu-bar app (`LSUIElement`), no Dock icon, no main
   window. Owns the single auto-off timer, the Settings window, launch at login
   (`SMAppService.mainApp`), and the AC/battery listener for the optional
   power mode.
2. `shutlid` CLI: `on`, `off`, `status`, `setup`. Ships inside the app bundle;
   `/usr/local/bin/shutlid` is a symlink. `on` launches the app if it is not
   running so the auto-off timer exists.
3. `ShutlidCore`: one small library shared by both. `PowerController.swift` is
   the only file that runs `pmset` or touches IOKit. Also: settings
   (`UserDefaults` suite), status text, `os_log` events.
4. Two root-owned data files installed by `setup`: the sudoers rule and the
   boot-reset launchd plist. No code runs as root except Apple's `pmset`.

Resident processes: one (the app), and only while it runs. No daemon, no XPC,
no helper, no IPC beyond a Darwin notification (`notify_post`) the CLI posts so
the app refreshes its icon immediately.

**Components rejected**: XPC service, privileged helper, SMAppService daemon,
database, service layer, dependency injection, networking, updater, analytics,
any Swift package dependency.

**Privilege model**: root only through `sudo -n /usr/bin/pmset disablesleep 1|0`
permitted by the scoped rule. Setup needs one admin authorization. The app and
the CLI never see a password.

**State**: `enabled`, `mode`, `autoOffHours`, `deadline`, `restoreAfterRestart`
in `UserDefaults`. Launch at login is tracked by macOS. Effective state is read
from the kernel every time; nothing reconciles it.

**Expected failure modes**

| Failure | Result |
|---|---|
| Setup not done, `on` called | `sudo -n` refuses; `on` prints how to run setup, exits non-zero. Mac keeps normal sleep. |
| `pmset` fails or `disablesleep` removed by Apple | `on` reports the error; `status` shows `Effective: OFF`. |
| App crash while ON | Flag stays until `off`, next app launch, or reboot. Auto-off does not fire. Documented. |
| App quit / logout | Turns OFF first. |
| Reboot | Boot reset turns OFF. With "restore previous state" on, the app re-enables at login with a fresh deadline. |
| Deadline passes while app not running | Next launch of the app or `status` shows it expired; app turns OFF at launch. |
| Boot-reset daemon disabled by user in System Settings | Flag may persist a reboot; `status` shows reality. Documented. |
| Power mode "only on AC", AC unplugged | Event handler turns the flag OFF, keeps `Requested: ON`; re-applies on replug. |
