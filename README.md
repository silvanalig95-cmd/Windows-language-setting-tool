# Language Profile

A Windows tool that standardizes language settings on a PC. An admin picks exactly one display
language, one regional format and one or more keyboard layouts. The tool:

- installs what is missing (the display language pack);
- applies the choice to the selected user accounts, the lock/welcome screen (and system accounts)
  and the new-user template;
- removes every other language and keyboard from those places;
- stops Windows from adding layouts back.

> **Status: not yet verified on Windows.** The code was written and statically checked on Linux:
> a PowerShell 5.1 compatibility lint and 75 unit tests of the engine logic pass (`tests/`).
> Nothing has run on Windows yet. Two things still need a VM before the tool can be trusted:
>
> - the registry diff (`tools/Capture-RegistryDiff.ps1`);
> - the acceptance tests in [`tests/VM-TestPlan.md`](tests/VM-TestPlan.md).
>
> **Do not run Apply on a production PC.** The Status tab and the readiness check are read-only.

## Files

| File | Purpose |
|---|---|
| `LanguageProfile.cmd` | Launcher. Double-click for the GUI, or pass parameters for unattended mode. Uses 64-bit Windows PowerShell 5.1 even when started from a 32-bit process (Intune/SCCM). |
| `LanguageProfile.ps1` | The tool. It contains the engine (no UI), the worker that runs inside a target account, the WPF front-end and the CLI. |
| `presets.json` | Presets. IT can add more without touching code. |
| `tools/Capture-RegistryDiff.cmd` / `.ps1` | **VM only.** Diffs the registry before and after the recipe, to confirm which keys Windows writes. Double-click the `.cmd` and pick a scenario; output goes to `C:\Users\Public\Documents\LanguageProfile-Diff`. |
| `tests/Engine.Tests.ps1`, `tests/Lint-PS51.ps1` | Unit tests and static checks. They run in `pwsh` on any OS. |
| `tests/VM-TestPlan.md` | Acceptance tests for the "done means" list. |

Requirements:
- Windows 10 22H2, or Windows 11 23H2/24H2.
- Windows PowerShell 5.1. The tool refuses to run in PowerShell 7, where the International module misbehaves.
- No installs and no external modules.

## Quick start

1. Double-click `LanguageProfile.cmd` and confirm the UAC prompt. Any administrator account works,
   including one that is not the signed-in user (over-the-shoulder credentials).
2. The **Standard** preset is preselected:
   - display language **en-US**;
   - format **de-CH**;
   - country/region **Switzerland (223)**;
   - keyboard **Swiss German 00000807** on en-US (tip `0409:00000807`).
3. Click **Apply standard setup**. This:
   - resets the targets to the default (signed-in user(s), lock screen, new users);
   - runs the readiness check;
   - shows one confirmation with a summary, then applies.

   If something is BLOCKED, nothing is changed and the readiness list says what to do.
4. The result tells you who must sign out and whether a restart is needed.

Tabs:
- **Configure**: preset, fields, targets, options and the live readiness panel.
- **Status**: read-only state of every profile, including hidden layouts, re-add risks and policies.
- **Preview and apply**: exactly what will be installed, set and removed, per target, plus the live log.
- **Restore**: lists the backups.

## Command line (Intune / SCCM / SYSTEM)

```
LanguageProfile.cmd -Preset Standard
LanguageProfile.cmd -Preset Standard -Target AllUsers,LockScreen,NewUsers
LanguageProfile.cmd -Preset Standard -Preview            (readiness + preview, no change)
LanguageProfile.cmd -Preset Standard -Verify             (detection rule: 0 = compliant, 5 = not)
LanguageProfile.cmd -Status [-Json]                      (read-only state of every profile)
LanguageProfile.cmd -Restore Latest                      (or a backup folder path)
LanguageProfile.cmd -DisplayLanguage en-US -RegionalFormat de-CH -GeoId 223 -Keyboard 00000807,00000409
```

| Parameter | Meaning |
|---|---|
| `-Preset <name>` | A preset from `presets.json`. Explicit fields override it. |
| `-DisplayLanguage`, `-RegionalFormat`, `-GeoId`, `-Keyboard` | The profile. The first keyboard is the default. GeoId defaults to the region of the format. |
| `-Target` | Default `SignedIn,LockScreen,NewUsers`. Other values: `AllUsers`, a SID, or an account name. |
| `-KeepLanguageSync` | Do not disable language sync (default: disabled). |
| `-AllowRemoteKeyboardLayout` | Do not set `IgnoreRemoteKeyboardLayout=1` (default: set). |
| `-SetSystemLocale [-SystemLocale xx-XX]` | Also set the system locale for non-Unicode programs. Restart needed. |
| `-UninstallOtherLanguages` | Uninstall all other language packs. The display language being applied is never removed. |
| `-LanguageSource <folder>` | Folder with `Microsoft-Windows-Client-Language-Pack_x64_<tag>.cab` from the Languages and Optional Features ISO. When given, the pack is installed from there (DISM) instead of Windows Update/WSUS. |
| `-ApplyReadyParts` | If something is blocked, apply only the parts that are ready (exit code 4). |
| `-TaskTimeoutMinutes` | How long to wait for the per-user task (default 10). |

**Exit codes**

| Code | Meaning |
|---|---|
| 0 | Done |
| 3010 | Done, restart needed (Intune/SCCM: soft reboot) |
| 2 | Blocked by a missing prerequisite. Nothing was changed. |
| 4 | Partially applied, only with `-ApplyReadyParts`. The output lists what was skipped. |
| 5 | `-Verify`: the PC does not match the profile |
| 1 | Error. The log says how far it got; Restore can undo it. |

**Intune Win32 app:**
- Install command: `LanguageProfile.cmd -Preset Standard -Target AllUsers,LockScreen,NewUsers`
- Detection: a custom script that runs `LanguageProfile.ps1 -Preset Standard -Verify -Target ...`
  and reports success on exit code 0.
- Running as SYSTEM is supported: the targets are always resolved by SID.

## presets.json

```json
{ "presets": [
    { "name": "Standard", "description": "...", "displayLanguage": "en-US", "regionalFormat": "de-CH",
      "geoId": 223, "keyboards": [ "00000807" ] }
] }
```

- Required fields: `name`, `displayLanguage`, `regionalFormat`, `keyboards` (8-hex-digit layout IDs).
- Optional fields: `geoId` (default: the region of the format), `description`, `systemLocale`
  (used when "set system locale" is on; default: the format).
- Invalid presets are skipped with a warning.
- If `Standard` is missing or the file is unreadable, a built-in Standard preset is used, so the
  one-click path always works.

## How it works

### Architecture
- `LanguageProfile.ps1` has four parts:
  - the **engine**: a dynamic module with no UI code;
  - the **worker**: a small script that runs *inside a target account*;
  - the **WPF front-end**;
  - the **CLI**.
- The GUI runs every slow operation in a background runspace that loads the same engine. These are
  the scan, the language-pack install, apply and restore. The UI stays responsive and the log streams live.
- The engine never uses HKCU or `%USERPROFILE%` of the elevated process. Every target is addressed
  by SID. The only code that touches HKCU is the worker, and it refuses to run if its SID is not
  the target's SID.

### How each target is written
| Target | How |
|---|---|
| Signed-in user (owns an `explorer.exe`) | A one-time scheduled task runs the worker as that user (interactive, limited, only when logged on). The tool waits, collects the result and the worker log, then deletes the task and its job folder. |
| User whose profile is loaded without a desktop (e.g. the over-the-shoulder admin) | Written directly into `HKU\<SID>`. |
| User who is not signed in | `NTUSER.DAT` is loaded under `HKU\LanguageProfile_<SID>`, written, then unloaded in `finally` (after `[gc]::Collect()`). Locked or damaged profiles are skipped with a warning. |
| Lock/welcome screen | The worker runs **as SYSTEM**. The SYSTEM account's hive is `HKU\.DEFAULT`, which is the lock screen. Also `Set-SystemPreferredUILanguage` where it exists. |
| System accounts | `HKU\S-1-5-19` and `HKU\S-1-5-20` get an exact copy of `.DEFAULT`'s language keys. |
| New users | The Default profile hive (path from the `Default` value in ProfileList) gets the same exact copy. |

The **recipe** that runs inside an account:
1. `New-WinUserLanguageList <display>`, clear its tips, add `LLLL:KKKKKKKK` for each keyboard.
   LLLL = `'{0:X4}' -f` the display LCID. Display languages with LCID 4096 are rejected.
2. `Set-WinUserLanguageList -Force`
3. `Set-WinDefaultInputMethodOverride <first tip>`
4. `Set-WinUILanguageOverride`
5. `Set-Culture`
6. `Set-WinHomeLocation`
7. Rewrite `Keyboard Layout\Preload` so that only entries resolving (through `Substitutes`) to the
   chosen tips remain, in the chosen order, renumbered 1..n. Unreferenced `Substitutes` are dropped.

   For example, Swiss German on en-US becomes `Preload 1 = d0010409` with `Substitutes d0010409 = 00000807`.
8. Optionally, language sync off.

If `Set-WinUILanguageOverride` fails right after a language pack was installed (because the pack is
active only after a restart), `PreferredUILanguages` is written directly and a warning is logged.

### Lock screen and new users: decision (b), refined
I chose option **(b)**: write `HKU\.DEFAULT` and the Default profile hive directly. I did **not**
copy from the elevated account (option a). Reasons:

1. **Option (a) changes an account that is not a target.** With over-the-shoulder elevation, the
   copy source is the admin's real profile. If that admin uses settings sync (Microsoft account or
   Enterprise State Roaming), the temporary language list can sync to the admin's other devices
   before it is restored. A crash between apply and restore would also leave the admin changed.
2. **The same path works everywhere.** In unattended mode the running account *is* SYSTEM, whose
   hive is `.DEFAULT`, so (a) would behave differently for GUI and CLI. (b) is identical for both,
   and for Windows 10 and 11. It also avoids `control.exe intl.cpl`, which hands the work to
   `rundll32` and returns early.
3. **The tool needs a hive writer anyway**, for users who are not signed in and for the mandatory
   exact mirror of `Preload` and `Substitutes`. With (b), `.DEFAULT` and Default are two more
   targets of the same writer, with real replace behaviour. With (a) the tool would run a copy that
   is known to leave layouts behind and then patch it.

**The refinement.** I did not hand-compute the ~40 values that `Set-Culture` writes (formats, the
User Profile tree, `CachedLanguageName`, and so on). Instead, the official cmdlets run *as SYSTEM*,
so Windows itself writes the exact values into `.DEFAULT`, which is a target anyway. That state is
then verified and copied with replace semantics into:
- `S-1-5-19` and `S-1-5-20`;
- the Default profile;
- users who are not signed in.

If the lock screen is not selected but such a copy is needed, `.DEFAULT` is used as a temporary
reference and restored right afterwards. The readiness panel says so.

The key assumption to confirm in the VM is that the International cmdlets work when run as SYSTEM
from a scheduled task. `tools/Capture-RegistryDiff.ps1 -Scenario RecipeAsSystem` tests exactly that.

### `Install-Language -CopyToSettings`: not used
That switch also copies the language to the device's system locale, input method, speech settings
and system preferred UI language. "Input method" means the language's default keyboard: US for
en-US, which is exactly the classic "US keyboard comes back" symptom. It would also change the
system locale, which is a separate option that is off by default.

So the tool installs with `Install-Language <tag> -ExcludeFeatures` (no basic typing, OCR or speech)
and sets the system UI language, the lock screen and new users explicitly.

The install runs as a background job, with progress and a Cancel button. Cancel stops the wait and
changes nothing else; Windows may still finish the download in the background.

### Display languages offered
- The list is embedded in the script (`$script:DisplayLanguageTable`):
  - the 38 full language packs (Install-Language can install them);
  - about 70 Local Experience Pack (LIP/LXP) languages, each with its required base language;
  - ca-ES, eu-ES, gl-ES, id-ID and vi-VN, which also ship as CABs on Windows 11.
- The table was transcribed from Microsoft's "Available languages for Windows" page, which could
  not be fetched while building the tool. **Please compare it with the page once.**
- "Installed" is the union of:
  - `Win32_OperatingSystem.MUILanguages`;
  - `HKLM\SYSTEM\CurrentControlSet\Control\MUI\UILanguages`;
  - `Get-InstalledLanguage` entries whose `LanguagePacks` is not `None` (if the cmdlet exists);
  - the current UI culture.
- "Full pack" (usable for the welcome screen) means MUILanguages, MUI\UILanguages, or `LpCab` in
  Get-InstalledLanguage. Everything else that is installed counts as LXP only.

## Readiness check
Every item shows **OK**, **AUTOMATIC** (will be added automatically), **WARNING**, **INFO** or
**BLOCKED** with steps. The check is re-evaluated live as choices change.

| Item | Behaviour |
|---|---|
| Admin rights / PowerShell language mode | Must be elevated and in FullLanguage mode. |
| Windows version | Lists capabilities (Install-Language, Set-SystemPreferredUILanguage). Warns on untested builds. |
| Display language pack | **Installed:** OK. **Missing and installable:** AUTOMATIC. **Single-language edition, or LXP-only language:** BLOCKED, with steps for the user (Settings > Time & language > Language & region > Add a language) and for IT (`DISM /Online /Add-Package` with the CAB from the Languages and Optional Features ISO, or `-LanguageSource`). |
| WSUS without a repair source | Warns that the download may fail with **0x800f0954** and names the GPO "Specify settings for optional component installation and component repair" (Computer Configuration > Administrative Templates > System). A real 0x800f0954 during install is shown with this explanation, not as a raw error. |
| Lock-screen suitability | **Full pack:** OK. **LXP only:** on Windows 10 the full pack is added automatically when possible, otherwise BLOCKED for the lock screen. On Windows 11 it is only a warning. |
| Keyboards | The layout ID must exist under `Keyboard Layouts` and its DLL must be present. Otherwise BLOCKED: "install the custom layout first". Also notes that the taskbar shows "ENG" while typing Swiss German. |
| Regional format / GeoId | Must be a specific culture (a built-in format needs no download). |
| Pending restart | BLOCKED if a pack must be installed or removed ("restart first"); otherwise a warning. |
| GPO/Intune policies | Read from `Software\Policies\Microsoft\Control Panel\International` (HKLM and every target), `...\Control Panel\Desktop` (PreferredUILanguages, MultiUILanguageID), `HKLM\SOFTWARE\Policies\Microsoft\MUI\Settings` and Intune's `PolicyManager\current\device\TimeLanguageSettings`. Policies that would override the result are BLOCKED, with the policy path, the GPMC setting name, and who must change it (gpresult / Intune profiles). The tool never changes policies. |
| Targets | Each target shows how it will be written. Task Scheduler must run for signed-in users. |
| Options | Sync, RDP, system locale (restart and legacy-app warning), uninstall (warns about non-selected users who would lose their display language). |
| Optional features | INFO: not required, not installed, not an error. |

If anything is BLOCKED, Apply changes **nothing**. "Apply only the parts that are ready"
(`-ApplyReadyParts`) is a separate, explicitly labelled choice, and it reports exactly what was skipped.

## Why layouts come back, and what the tool does about each cause
| # | Cause | Handling |
|---|---|---|
| 1 | The display language is missing from the language list, so Windows re-adds it **with its default keyboard**. | The list is exactly one entry: the display language with the chosen keyboards attached. Status shows this risk. |
| 2 | Lock-screen layouts are pulled into the session at sign-in. | `.DEFAULT` gets the identical recipe and Preload. Status shows lock-screen layouts a user doesn't have. |
| 3 | RDP/Citrix injects the client's layout. | `HKLM\SYSTEM\CurrentControlSet\Control\Keyboard Layout\IgnoreRemoteKeyboardLayout = 1` (option, on by default). |
| 4 | Settings sync restores old lists. | `...\SettingSync\Groups\Language\Enabled = 0` per target (option, on by default). |
| 5 | Hidden Preload entries. | Preload/Substitutes are rewritten in every target. Status lists hidden entries (Preload entries mapped through Substitutes that are not in the list). |
| 6 | GPO/Intune policies. | Detected, reported and BLOCKED, never fought. |
| 7 | PowerShell traps. | All registry writes use the .NET API, never `New-Item -Force`. `reg.exe` and `icacls.exe` run through a wrapper with a local `$ErrorActionPreference='Continue'` that checks `$LASTEXITCODE`. |
| 8 | Hive handling. | `[gc]::Collect()` and `WaitForPendingFinalizers()` before unloading, unload in `finally` with retries. Loaded hives are used in place. Stale mounts from a crashed run are unloaded at start. The GUI cannot be closed while a hive may be loaded. |

## Registry keys touched
Before any change, every key below is exported **per target** to `%ProgramData%\LanguageProfile\Backups\<timestamp>_apply\`:
- as `.reg` files, for humans;
- as `manifest.json` snapshots, which Restore uses for an exact delete-and-rewrite. Plain `reg import` would only merge.

**In each user-type hive** (selected users, `HKU\.DEFAULT`, `S-1-5-19`, `S-1-5-20`, Default profile), relative to the hive root:

| Key | What | How it is written |
|---|---|---|
| `Control Panel\International` | All values (`Locale`, `LocaleName`, `sShortDate`, ...) | Values replaced. Subkeys such as `Calendars` untouched. |
| `Control Panel\International\User Profile` | `Languages`, `InputMethodOverride`, per-language subkey with tips | Whole key replaced |
| `Control Panel\International\User Profile System Backup` | Same layout | Whole key replaced |
| `Control Panel\International\Geo` | `Nation`, `Name` | Whole key replaced |
| `Control Panel\Desktop` | **Only** `PreferredUILanguages`, `PreferredUILanguagesPending`, `PreviousPreferredUILanguages` | Listed values replaced. Wallpaper and other values are untouched. |
| `Control Panel\Desktop\MuiCached` | `MachinePreferredUILanguages` | Whole key replaced |
| `Keyboard Layout\Preload` | `1..n` | Deleted, recreated, values written |
| `Keyboard Layout\Substitutes` | `d0NNLLLL -> layout` | Deleted, recreated, values written |
| `Software\Microsoft\Windows\CurrentVersion\SettingSync\Groups\Language` | `Enabled = 0` | Value set (option; not in .DEFAULT, S-1-5-19 or S-1-5-20) |

In signed-in users and in `.DEFAULT`, these keys are written by the Windows cmdlets themselves plus
the Preload rewrite. In all other hives they are an exact copy of `.DEFAULT` after the recipe.

**Machine:**

| Item | When |
|---|---|
| `HKLM\SYSTEM\CurrentControlSet\Control\Keyboard Layout\IgnoreRemoteKeyboardLayout = 1` (DWORD) | RDP option (default on) |
| System preferred UI language (`Set-SystemPreferredUILanguage`) | Lock screen selected, cmdlet available |
| System locale (`Set-WinSystemLocale`) | Option, default off |
| Language packs (`Install-Language`, `Add-WindowsPackage`, `Uninstall-Language`) | When needed / option. **Not rolled back by Restore.** |
| Scheduled tasks under `\LanguageProfile\` | One-time worker tasks, deleted after each run |
| `%ProgramData%\LanguageProfile\{Logs,Backups,Jobs}` | Restricted to SYSTEM and Administrators. Job folders also grant the target user read access, and write access to `out\` only. |

**Read only:**
- `ProfileList`;
- `Keyboard Layouts`;
- policy keys;
- Windows Update / servicing policies (WSUS detection);
- reboot-pending keys;
- `MUI\UILanguages`.

The Status tab and the scan briefly load the `NTUSER.DAT` of profiles that are not signed in
(`reg load` / `reg unload`) to read them. They write nothing.

**To be confirmed empirically** (the requirement to diff the registry in a test VM): the table above
is what the tool writes, and it is defined in one place, `$script:LanguageKeySet`. What remains to be
confirmed is whether Windows' recipe also writes keys *outside* this list that profiles which are not
signed in would need. Candidates:
- `Software\Microsoft\CTF\SortOrder` and `CTF\Assemblies` (the input profile order);
- `Software\Microsoft\Windows\CurrentVersion\Internet Settings\International\AcceptLanguage`;
- `Software\Microsoft\Input` (Windows 11).

Run `tools/Capture-RegistryDiff.cmd` in a VM (scenarios Recipe, RecipeAsSystem and CopyToSystem, see
phase 0 of the test plan) and send back the `*_diff.txt`, `*_keys.txt` and `*_transcript.txt` files from
`C:\Users\Public\Documents\LanguageProfile-Diff`. Any key that has
to be added goes into `$script:LanguageKeySet` and this table.

## Backups, Restore, logs
- Backups go to `%ProgramData%\LanguageProfile\Backups\<timestamp>_apply\`: `manifest.json` plus one `.reg` file per key and target.
- **Restore** is available in the Restore tab or with `-Restore Latest|<folder>`:
  - it first backs up the current state;
  - it then writes every key back exactly, per target. It finds the hive again by SID, loading it if needed.
  - Signed-in users must sign out afterwards; restart for the lock screen.
  - **Installed or removed language packs are not rolled back.**
- Logs: `%ProgramData%\LanguageProfile\Logs\LanguageProfile_<time>_<Session|Apply|Restore|Status|...>_<pid>.log`.
  Every run writes one, including the worker logs from inside each account.
- Every operation is idempotent: running the same profile again produces the same state.
- Only one instance can make changes at a time (global mutex).

## Known limitations
- Text-services input methods (Japanese, Chinese and Korean IMEs) are not offered. The keyboard list contains classic layouts (KLIDs) only.
- A short console flash may appear in a signed-in user's session while the one-time task runs.
- While an offline profile's hive is loaded, which takes a few seconds, that user cannot sign in.
- On Windows 10 it is not documented whether the `LanguagePackManagement` module (`Install-Language`) is present. The tool checks at runtime and shows the manual steps if it is not.
- If an execution policy is enforced by GPO (`AllSigned`), `LanguageProfile.ps1` itself won't start: sign it. The per-user worker is unaffected (it is loaded as a script block).
- `Set-WinUserLanguageList` and the other cmdlets running as SYSTEM in session 0 is the central assumption of the lock-screen path. It is phase 0 of the VM test plan.

## Development
```
pwsh -File tests/Lint-PS51.ps1        # parse, PS 5.1 compatibility, ASCII-only, XAML names
pwsh -File tests/Engine.Tests.ps1     # 75 unit tests of the engine (no registry access)
```
