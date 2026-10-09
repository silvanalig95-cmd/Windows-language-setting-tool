# VM test plan

Everything here **changes language settings**. Run it only in Hyper-V VMs with checkpoints (or Windows
Sandbox for the read-only parts). Windows Sandbox is not enough for most tests, because it cannot do
language-pack installs, multiple users or restarts reliably.

## VMs
| VM | Install media | Purpose |
|---|---|---|
| W10-EN | Windows 10 22H2 Pro, English (US) | Standard preset on a clean English Windows |
| W10-DE | Windows 10 22H2 Pro, German | en-US missing; Windows 10 copy path |
| W11-DE | Windows 11 24H2 Pro, German | en-US missing; Windows 11 path |
| W11-EN | Windows 11 23H2 Pro, English (US) | Second Windows 11 build |

In every VM:
- Create local users: `alice` (standard user), `bob` (standard user, sign in once so the profile exists, then sign out) and `admin` (administrator).
- Copy the repository to `C:\LP`.
- Take a checkpoint called **clean**.
- In alice's session, **before the tool runs**, add a few "wrong" items: Settings > add de-CH (German Switzerland), the US keyboard, and a German keyboard. Apply to bob the same way. Checkpoint **dirty**.

What to collect after each test (please send these back):
- `C:\ProgramData\LanguageProfile\Logs\*`;
- the output of `C:\LP\LanguageProfile.cmd -Status > C:\status.txt`;
- the output of `C:\LP\LanguageProfile.cmd -Preset Standard -Verify -Target AllUsers,LockScreen,NewUsers > C:\verify.txt`, plus its exit code (`echo %ERRORLEVEL%`).

---

## Phase 0: registry diff (do this first; determines the key list)
On **W10-EN** and **W11-EN**, from the **dirty** checkpoint:
1. Signed in as alice, in a normal PowerShell window:
   `powershell -ExecutionPolicy Bypass -File C:\LP\tools\Capture-RegistryDiff.ps1 -Scenario Recipe`
2. Elevated, as admin:
   `powershell -ExecutionPolicy Bypass -File C:\LP\tools\Capture-RegistryDiff.ps1 -Scenario RecipeAsSystem`

   **Check:** the worker reports `Worker success: True`. This is the central assumption: the
   cmdlets work as SYSTEM.
3. Elevated, in the admin account. Run `-Scenario Recipe` there first, then:
   `...\Capture-RegistryDiff.ps1 -Scenario CopyToSystem`. This captures Microsoft's own copy, for comparison.
4. Windows 11 only: `...\Capture-RegistryDiff.ps1 -Scenario SystemPreferredUILanguage`

Send back all `diff-output\*_diff.txt` and `*_keys.txt`.

## Phase 1: read-only checks (allowed on a normal PC, too)
- [ ] `LanguageProfile.cmd -Status` runs without errors and lists every profile:
  - signed-in users are marked;
  - hidden layouts are shown;
  - re-add risks are shown;
  - policies are shown.
- [ ] `LanguageProfile.cmd -Preset Standard -Preview` shows readiness and preview and changes nothing. Exit code: 0 when ready, 2 when blocked.
- [ ] GUI opens. Standard is preselected and the readiness panel updates when fields change.
- [ ] In PowerShell 7: `pwsh -File LanguageProfile.ps1` refuses to run.

## Phase 2: "Done means"
### 2.1 Standard preset on a clean English Windows, one click (W10-EN, W11-EN; from **dirty**)
1. Sign in as alice. Run `C:\LP\LanguageProfile.cmd` and elevate with the **admin** credentials (over the shoulder).
2. Click **Apply standard setup**, then confirm.

Expected:
- Readiness all OK/automatic.
- Result: Done, sign-out needed for alice, restart needed (lock screen).
- After restart: `-Verify` returns 0 for alice, the lock screen and new users.
- [ ] Settings > Language: only "English (United States)", with only the Swiss German keyboard.
- [ ] Win+Space shows only one entry (ENG, Swiss German).
- [ ] Lock screen: the keyboard indicator shows only Swiss German, and typing in the password box is Swiss German.
- [ ] Formats are de-CH, country is Switzerland.

### 2.2 German Windows without en-US (W10-DE, W11-DE; from **clean**)
1. As alice, elevated with admin: **Apply standard setup**.

Expected:
- Readiness shows "en-US will be added automatically".
- Progress during download, and Cancel works: try it once, the result is "Cancelled, nothing changed".
- After the install, everything is applied. Result: Done, restart needed.
- [ ] After restart: display English, and the same checks as in 2.1.
- [ ] If Install-Language is missing on Windows 10, readiness shows BLOCKED with the Settings and DISM steps, and **nothing is changed** (compare `-Status` before and after; exit code 2 in the CLI).

### 2.3 Simulated WSUS block (W10-DE or W11-DE, from **clean**)
```
reg add HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate /v WUServer /t REG_SZ /d http://wsus.invalid:8530 /f
reg add HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate /v WUStatusServer /t REG_SZ /d http://wsus.invalid:8530 /f
reg add HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU /v UseWUServer /t REG_DWORD /d 1 /f
net stop wuauserv & net start wuauserv
```
Expected:
- [ ] Readiness warns about WSUS / 0x800f0954 before applying.
- [ ] Apply: the install fails and the result shows "The download was blocked by WSUS (0x800f0954)" with the GPO steps, not a raw error. Nothing else was changed; CLI exit code 2.
- If the error code is different (for example 0x8024402c because the server name doesn't resolve), please send the log. The mapping may need that code too.

### 2.4 After Apply + restart: only the chosen items, for every selected user (from **dirty**, after 2.1)
- [ ] alice: Settings, Win+Space and the lock screen show only en-US / Swiss German.
- [ ] Status tab: no hidden layouts and no re-add risks for the selected targets.

### 2.5 New local user created afterwards
1. After 2.1, run `net user carol P@ssw0rd! /add` and sign in as carol.
- [ ] carol has only en-US with Swiss German, formats de-CH, Switzerland. No US keyboard.

### 2.6 Selected user who was not signed in
1. Before 2.1, in Configure, also tick **bob**.
2. After applying, sign in as bob.
- [ ] Same result as alice. bob's profile loads normally: no temporary profile.

### 2.7 Persistence
- [ ] Three sign-out/sign-in cycles for alice and bob, then `-Verify` returns 0. Settings and Win+Space are unchanged.
- [ ] RDP into the VM from a client with a different keyboard (e.g. French or US). In the session, Win+Space still shows only Swiss German. After signing out and in at the console, still only Swiss German.

### 2.8 Different admin than the signed-in user
- 2.1 already uses over-the-shoulder credentials. Repeat it **as SYSTEM** to cover the unattended path:
  `psexec -s C:\LP\LanguageProfile.cmd -Preset Standard -Target AllUsers,LockScreen,NewUsers`
  (or deploy as an Intune Win32 app).
- [ ] Exit code 3010.
- [ ] Everything as above.
- [ ] The admin account's own languages are unchanged unless it was selected.

## Phase 3: safety
- [ ] **Restore** (GUI and `-Restore Latest`) brings `-Status` back to the "dirty" state. Language packs stay installed, and the result says so.
- [ ] Each Apply creates a backup folder with `.reg` files and `manifest.json`.
- [ ] Running Apply twice gives the same result (idempotent).
- [ ] A locked profile is skipped with a warning and the rest is applied. To lock one, open bob's NTUSER.DAT in another process, e.g. with `reg load HKU\x C:\Users\bob\NTUSER.DAT`.
- [ ] A GPO "Restricts the UI language Windows uses for all logged users" set to de-DE makes readiness BLOCKED with the policy path; nothing is changed.
- [ ] "Apply only the parts that are ready" is offered only when something is blocked. It asks for confirmation and reports exactly what was skipped (exit code 4 in the CLI).
