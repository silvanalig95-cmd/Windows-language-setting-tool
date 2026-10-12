# Language Profile - User guide

For IT staff who set up or fix Windows PCs. This guide explains what the tool is for, how to use it
and what to keep in mind. The technical reference (how it works inside, registry keys, all command-line
parameters) is in [README.md](README.md).

Contents

1. What it is for
2. What it does by default
3. The defaults, and why they fit most users in Switzerland
4. Why the layouts stop coming back
5. Before you start
6. The quick way: "Apply standard setup"
7. Step by step
8. After applying: what the user sees
9. The options
10. Who gets changed
11. Important things to keep in mind
12. Undo: Restore
13. Checking a PC
14. Unattended: Intune / SCCM
15. Troubleshooting
16. FAQ
17. Logs, and what to send when something goes wrong
18. Test status

---

## 1. What it is for

Windows keeps adding keyboard layouts and languages on its own. Typical symptoms:

- A **US keyboard** appears next to Swiss German. Win+Space or Alt+Shift switches to it by accident:
  Y and Z are swapped, special characters are in the wrong place.
- The **lock screen** uses a different keyboard than the desktop, so the password is "wrong" at sign-in.
- After a restart, an update or a Remote Desktop session there are suddenly two or three layouts again.
- Languages nobody asked for (for example English (United Kingdom)) show up in Settings.

Fixing this by hand in Settings doesn't last. Windows keeps the language settings in several places
(the user, the lock screen, the template for new users, hidden backup copies, text-input leftovers) and
restores layouts from them.

**Language Profile sets one defined language setup in all of these places and removes everything
else.** One click for the standard, or step by step with a preview.

Our standard setup (preset **Standard**):

| Setting | Value |
|---|---|
| Display language (menus, Windows interface) | English (United States), en-US |
| Regional format (dates, numbers, currency) | German (Switzerland), de-CH |
| Country/region | Switzerland |
| Keyboard | Swiss German, and nothing else |

Other presets are in `presets.json` (Swiss German UI, Swiss French, English (UK)). IT can add more
without touching the script.

---

## 2. What it does by default

**In one sentence: it sets the chosen display language, format and keyboard for the signed-in user,
the lock screen and every future new user, and removes all other languages and keyboard layouts from
those places.**

In detail, with the default settings:

- **Signed-in user(s):** the language list becomes exactly one language (the display language) with
  exactly the chosen keyboard(s). Every other language and keyboard is removed. Format and
  country/region are set.
- **Lock/welcome screen** (and the built-in system accounts): the same setup. The keyboard you type the
  password with at the lock screen is the same as on the desktop.
- **New users:** the template for new accounts (the Default profile) gets the same setup. Anyone who
  signs in to this PC for the first time starts with the standard.
- **Other language packs are uninstalled from the PC**, for example a leftover German (Germany) or
  English (UK) display language. Before you apply, an orange box lists exactly which ones. You can
  switch this off.
- **Language settings sync is switched off** for these accounts, so an old language list doesn't come
  back from the cloud.
- **Remote Desktop / Citrix can no longer add the client's keyboard** to this PC.
- **Hidden copies are cleaned up**: the keyboard preload list, Windows' backup of the language list
  and leftovers of removed languages. These are where layouts usually come back from.
- **A missing display language pack is installed** automatically (download through Windows Update).
- **A backup is made first** of everything that will be changed, so it can be restored.

What it does **not** do:

- It does not change accounts you didn't select (for example other people who used the PC before).
  The exception: uninstalled language packs are gone for everybody on the PC.
- It does not change group policies or Intune settings. If a policy enforces a language, the tool
  reports it and stops. It does not fight policies.
- It changes nothing outside the language settings. The exact list of registry keys is in README.md
  ("Registry keys touched").
- It does not lock the settings. A user can still add a keyboard in Settings on purpose. Section 11
  explains what to do then.

---

## 3. The defaults, and why they fit most users in Switzerland

The defaults are chosen so that **for most PCs in Switzerland you don't have to change anything**:
start the tool, click "Apply standard setup", done. Change something only for the exceptions in the
last column.

**The profile** (preset Standard):

| Setting | Default | Why it fits most users | Change it when |
|---|---|---|---|
| Display language | English (United States) | One interface language for everybody: menus, screenshots, instructions and support look the same on every PC, and most help articles and admin tools use the English names. en-US is a full language pack, so it also works on the lock screen. | Someone really needs a German or French Windows interface. Use the preset "Swiss German UI" or "Swiss French". |
| Regional format | German (Switzerland) | Swiss conventions in every program, whatever the interface language: dates like 12.10.2026, 24-hour time, the Swiss thousands separator, CHF, weeks starting on Monday. That is what people expect in Excel and Outlook. | Rarely. French- or Italian-speaking colleagues can pick French (Switzerland) or Italian (Switzerland): same Swiss conventions, day and month names in their language. |
| Country/region | Switzerland | Matches where the PC is used (region-dependent content and defaults in Windows and apps). | Practically never. |
| Keyboard | Swiss German, and only this one | The layout printed on Swiss (QWERTZ) keyboards. With a single layout there is nothing to switch to by accident: no more Y/Z swaps, and the lock-screen password is typed exactly as on the desktop. | Colleagues who type with the Swiss French layout (é, è, à on the keys instead of ü, ö, ä) get "Swiss French" as their keyboard. Someone who needs a second layout (for example US for a developer) gets it added as the second keyboard. |

**Who is changed and the options:**

| Setting | Default | Why it fits most PCs | Change it when |
|---|---|---|---|
| Apply to: the signed-in user, the lock screen, new users | Ticked | The person using the PC, the screen they sign in on, and everyone who signs in later. Those are exactly the places layouts come back from. | Leave them ticked for a normal setup. |
| Apply to: other existing accounts | Not ticked | People who aren't there are not changed without being asked. | Shared or pool PCs: tick the other accounts too. |
| Uninstall other language packs | On | Leftover display languages, for example German (Germany) or English (UK) from the original Windows image, are used by nobody on most PCs. Removing them leaves exactly one Windows language on the PC, so nothing can switch back to them. | Someone on this PC works with another Windows display language. |
| Disable language sync | On | An old language list can't come back from another PC through the user's account. | Hardly ever. |
| Block Remote Desktop keyboard injection | On | Remote Desktop / Citrix clients can't add their own keyboard to this PC. | People connect to this PC by Remote Desktop from laptops with a non-Swiss keyboard and need their own layout in the session. |
| Set the system locale for non-Unicode programs | Off | Modern programs don't need it. Changing it needs a restart and can garble old programs. | An old program shows garbled umlauts. |

**In short:** for a normal PC in Switzerland, "Apply standard setup" with all defaults is the right
choice. The step-by-step way (section 7) is for the exceptions above.

---

## 4. Why the layouts stop coming back

Windows re-adds layouts from several sources. The tool handles each one:

| Where the extra layout comes from | What the tool does |
|---|---|
| The display language is not in the user's language list. Windows adds it back **with its default keyboard**: US for English. This is the most common cause of "the US keyboard is back". | The display language is always in the list, with only the chosen keyboard attached. |
| The lock screen has other layouts. Windows carries them into the user's session at sign-in. | The lock screen gets the identical setup. |
| Hidden entries in the keyboard "preload" list. | Rewritten so that only the chosen keyboards remain. |
| Windows' backup copy of the language list. Windows can restore the list from it. | Overwritten with the new list. |
| Leftovers of removed languages in the text-input settings. | Removed. |
| Settings sync restores an old list from another PC. | Language sync switched off. |
| Remote Desktop / Citrix sends the client's keyboard. | Blocked. |
| New accounts start with Windows' defaults. | The template for new users is set too. |

The **Status** tab shows these risks per account (badge **RE-ADD RISK**), before and after applying.

---

## 5. Before you start

- **Windows:** Windows 10 22H2, or Windows 11 23H2 / 24H2 / 25H2.
- **An administrator account.** It does not have to be the signed-in user. The user stays signed in and
  you type your admin credentials into the prompt ("over the shoulder").
- **The user should be signed in** if their account should be changed. Accounts that are not signed in
  can be ticked too (section 10).
- **Ask the user to save their work.** They have to sign out afterwards, usually the PC restarts.
- **Installing a display language** (only if it is missing) needs Windows Update. On WSUS-only PCs this
  can fail; see section 15. It takes 10 minutes or more.
- **Where to start it from:** a local folder or the network folder. Double-click `LanguageProfile.cmd`.
  Do **not** use "Run as administrator" on a mapped network drive: the admin account can't see the
  user's drive mappings. A normal double-click works; the tool takes care of it.

---

## 6. The quick way: "Apply standard setup"

1. Double-click `LanguageProfile.cmd`.
2. Enter the admin credentials in the Windows prompt. A small window says "Starting Language Profile..."
   until the tool opens (a few seconds).
3. Wait until the scan is finished: the moving bar at the bottom right disappears and the green
   **Apply standard setup** button becomes clickable.
4. Click **Apply standard setup** (top right).
5. Read the confirmation. It lists who is changed and which language packs are uninstalled. Click **Yes**.
6. Wait for the result. Don't close the window while it runs.
7. If a restart is needed, an orange **RESTART REQUIRED** window says why (see step 4 in section 7).
   **Restart later** is the default; **Restart now** must be clicked on purpose. If no restart is
   needed, the user signs out and in again.

"Apply standard setup" always uses the Standard preset with the default options and the default
targets: the signed-in user(s), the lock screen and new users. Changes you made on the Configure tab are
reset first.

If something is **BLOCKED** (red), nothing is changed, and the readiness list says what to do.

---

## 7. Step by step

Use this to check everything before applying, or to change something: another keyboard, another
account, an option.

The bar under the preset shows where you are, with a one-line hint for the next step:

    1 Choose settings  >  2 Preview changes  >  3 Apply  >  4 Sign out / restart

Finished steps are green, the current one is blue. Click a step to jump to its tab.

### Step 1: Choose settings (Configure tab)

- **Preset** (top): Standard is preselected. Choosing another preset fills in all fields; every field can
  still be changed.
- **Left column:** display language, regional format, country/region, keyboard layouts.
  - Keyboards: search on the left, **Add >** moves it to "Selected". The **first** keyboard is the
    default. **Up** / **Down** change the order.
  - The display language list says for each language whether it is installed, will be installed, or
    must be installed manually.
- **Right column:**
  - **Apply to**: which accounts are changed (section 10).
  - **Options** (section 9), including the orange "Uninstall other language packs" box.
  - **Readiness**: a live check of this PC. It updates whenever you change something.
- **Bottom right:** **Next: Preview changes**. Nothing is changed yet.

Readiness badges:

| Badge | Meaning |
|---|---|
| OK | Fine, nothing to do. |
| AUTOMATIC | Missing, the tool adds it (for example the language pack). |
| WARNING | Works, but read it (for example which language packs are uninstalled). |
| INFO | Just information. |
| BLOCKED | Can't be applied. The item says why and what to do. Nothing is changed while something is blocked. |

### Step 2: Preview changes (Preview and apply tab)

The preview lists per account exactly what happens: **SET**, **REMOVE**, **INSTALL**, **UNCHANGED**.

- **< Back to settings** goes back to step 1.
- **Apply these changes** (blue, right) starts step 3.
- If parts are blocked, an orange **Apply ONLY the parts that are ready** button appears. It is a
  deliberate choice: the blocked parts stay unchanged and the PC is not fully standardized. The result
  lists what was skipped.

### Step 3: Apply

- A confirmation shows a summary: languages, keyboards, accounts, language packs to uninstall.
- During the run: progress bar and live log. **Cancel download** works only while a language pack is
  downloading.
- Don't close the window. The tool refuses to close while it is working, so that no user profile stays
  half-written.

### Step 4: Sign out / restart

The result says what is still needed:

- **Restart the PC** when the lock screen was changed or language packs were installed or removed. An
  orange **RESTART REQUIRED** window shows why and has two buttons:
  - **Restart later** (default): Enter, Esc and closing the window all choose it. Everything stays
    open; the change is saved and completes at the next restart.
  - **Restart now**: restarts immediately and **closes all open programs without saving**. Click it
    only when the user has saved their work.

  If you choose later, an orange bar stays at the top of the tool ("RESTART REQUIRED to finish ...")
  with a **Restart now...** button. That button asks again, with No as the default.
- **Sign out and in** for signed-in users whose display language changed.
- "Done. Nothing else to do." when nothing else is needed.

Until the restart, the lock screen and the language packs still show the old state. The user's own
language list and keyboards are already changed.

---

## 8. After applying: what the user sees

After the restart or sign-in:

- **Settings > Time & language > Language & region:** only *English (United States)*. Under its
  options, only the *Swiss German* keyboard.
- **Win+Space** shows a single entry. Nothing to switch to by accident.
- **The taskbar shows "ENG".** This is expected. It shows the *language*, not the keyboard. The keyboard
  is Swiss German: click the indicator and it shows English (United States) with the Swiss German
  keyboard.
- **Lock screen:** the password is typed in Swiss German.
- **Formats:** Swiss dates (12.10.2026), numbers and currency. Country/region: Switzerland.
- Programs that were open during the change may keep the old keyboard until they are restarted.

---

## 9. The options

| Option | Default | What it does / when to change it |
|---|---|---|
| Disable language sync for the targets | On | Stops Windows settings sync (Microsoft account / Enterprise State Roaming) from bringing back an old language list. Leave on. |
| Block Remote Desktop keyboard injection | On | RDP/Citrix clients can no longer add their keyboard to sessions on this PC. **Applies to the whole PC.** Side effect: someone who connects by Remote Desktop from a laptop with a different keyboard (for example US) types with this PC's Swiss German layout. Switch off only if that is a problem. |
| Set the system locale for non-Unicode programs | Off | Only for old programs that show garbled umlauts. Needs a restart. Leave off unless such a program needs it. |
| **Uninstall other language packs** | **On** | Removes every other installed *display language* (translated Windows interface) from the **whole PC, for all users**. The orange box lists exactly which ones. The display language being applied is never removed. Needs a restart. **Restore does not bring them back.** Untick it if someone else on this PC uses another display language. Even when it is off, Apply still removes the other languages from the language lists of the selected accounts. |
| Language pack source folder | Empty | For PCs without Windows Update (WSUS-only, offline): a folder with the language pack `.cab` from Microsoft's "Languages and Optional Features" ISO. Leave empty normally. |

"Apply standard setup" resets all options to these defaults. Why these defaults fit most PCs, and when
to change them: section 3.

---

## 10. Who gets changed ("Apply to")

| Entry | Ticked by default | Notes |
|---|---|---|
| Signed-in user(s) (marked SIGNED IN) | Yes | Changed inside their session. The display language becomes active after sign-out and sign-in. |
| Other accounts on this PC (not signed in) | No | Tick them to change them too. Active at their next sign-in. Takes a few seconds per account; that account can't sign in during those seconds. |
| The admin account you elevated with | No | Marked "this is the elevated account running the tool". Your own admin profile is only changed if you tick it. |
| Lock/welcome screen and system accounts | Yes | Needs a restart to show. |
| New user accounts (Default profile) | Yes | Affects accounts created or first signed in after this. |

**Re-scan PC** reads the accounts again, for example after a user signed in.

---

## 11. Important things to keep in mind

1. **It replaces, it doesn't add.** Everything not chosen is removed from the selected accounts. If a
   user needs a second keyboard (for example French (Switzerland), or US for a developer), add it in
   step 1 **before** applying. Several keyboards are fine; the first one is the default.
2. **Language packs are removed for the whole PC** (when the option is on). Other users of the PC whose
   display language is removed fall back to the remaining one. The readiness list names them. Restore
   does not reinstall packs.
3. **A restart is part of it.** The lock screen and installed or removed language packs show only after a
   restart. The tool never restarts on its own or by pressing Enter: you choose "Restart now" or restart
   later yourself. Plan it with the user.
4. **Policies win.** If a GPO or Intune policy enforces a language, readiness shows **BLOCKED** with the
   policy name and who has to change it. The tool never changes policies.
5. **Managed devices:** security software or AppLocker can stop the step that runs inside the user's
   session. The tool then writes the settings directly into the user's profile. They are still applied,
   but become active only after sign-out and sign-in. The result shows a warning with the reason. This is
   not an error.
6. **Language pack downloads** need Windows Update. On WSUS-only PCs they can fail (section 15).
7. **One run at a time** per PC. A second window, or an Intune run at the same time, is refused.
8. **Running it twice is safe.** The same profile gives the same result. Nothing piles up.
9. **The settings are not locked.** A user can still add a keyboard in Settings on purpose. Run the tool
   again, or let Intune re-apply it (section 14).
10. **Big Windows feature updates** have not been tested yet. After one, check the PC on the Status tab.
11. **Backups and logs** are in `C:\ProgramData\LanguageProfile`. Only administrators can open that
    folder, because the files contain user names.

---

## 12. Undo: Restore

Every Apply first backs up all registry keys it changes.

1. Open the **Restore** tab.
2. Select the backup (date, time, what was applied) and click **Restore selected backup**.
3. Signed-in users sign out and in; restart for the lock screen.

- Restore puts the language settings back exactly as they were before that run. It first makes a backup
  of the current state, so a restore can be undone too.
- **Installed or removed language packs are not rolled back.** The keys are restored; a removed pack
  must be added again in Settings if needed.
- Command line: `LanguageProfile.cmd -Restore Latest`

---

## 13. Checking a PC

Read-only, changes nothing:

- **Status tab:** for every account on the PC: languages, keyboards, formats, hidden layouts, re-add
  risks and language policies. The lock screen and the new-user template are listed too.
- **Readiness** on the Configure tab: what would happen and whether anything is blocked.
- Command line:

      LanguageProfile.cmd -Status
      LanguageProfile.cmd -Preset Standard -Preview
      LanguageProfile.cmd -Preset Standard -Verify

  `-Verify` checks whether the PC matches the profile: exit code **0** = matches, **5** = doesn't.

---

## 14. Unattended: Intune / SCCM

The same tool runs without a window when parameters are given, also as SYSTEM:

    LanguageProfile.cmd -Preset Standard -Target AllUsers,LockScreen,NewUsers

- The command line uses the same defaults as the window, including uninstalling the other language
  packs. Add `-KeepOtherLanguages` to keep them.
- Detection rule: `-Preset Standard -Verify` with the same targets. Exit code 0 = compliant. With a
  required assignment, Intune applies the profile again when a PC no longer matches.
- Exit codes:

| Code | Meaning |
|---|---|
| 0 | Done |
| 3010 | Done, restart needed |
| 2 | Blocked by a missing prerequisite. Nothing was changed. |
| 4 | Partly applied (only with `-ApplyReadyParts`) |
| 5 | `-Verify`: the PC does not match |
| 1 | Error. The log says how far it got. |

All parameters and details: README.md, "Command line".

---

## 15. Troubleshooting

| You see | Meaning | What to do |
|---|---|---|
| Nothing happens after the admin prompt, or "stopped before its window opened" | The elevated part couldn't start. | Look at the newest log (section 17). As a workaround, copy the folder to the local disk (for example `C:\LP`) and start it from there. |
| "could not be started from the network folder: ... was changed after it was copied" | A file changed between the copy and the admin prompt. | Start the tool again. |
| "Language Profile is already running on this PC" | Another window or an Intune/SCCM run is active. | Wait until it has finished. |
| BLOCKED: "A restart is pending - restart first" | Windows waits for a restart (often after updates). Installing or removing language packs on top of that is unreliable. | Restart, then run the tool again. |
| BLOCKED: display language pack missing / "install manually" | The language can't be installed automatically (single-language Windows edition, or a language that only exists as an add-on). | Follow the steps shown in the item, or choose another display language. |
| Install fails with **0x800f0954** | WSUS blocks the download from Windows Update. | The message names the GPO "Specify settings for optional component installation and component repair". Or use the "Language pack source folder" option with the ISO. |
| BLOCKED: a policy enforces a language | A GPO or Intune profile sets the language. | Whoever owns the policy must change it. The item shows the policy path (`gpresult /h report.html` helps). |
| Result warning: "written directly into the profile - active after sign-out and sign-in" | The step inside the user's session couldn't run (security software, AppLocker). | Nothing. The settings are written; the user signs out and in. |
| "Other language packs cannot be uninstalled automatically on this Windows version" | Older Windows 10 without the needed command. | Everything else is applied. Remove the pack in Settings if needed. |
| Windows "uninstall" of a pack is refused | Windows doesn't remove the language it was installed with. | Reported, not an error. The language is still removed from the language lists. |
| An account is "skipped" | Its profile is locked or damaged. | The rest is applied. Try again when that user is signed out. |
| A keyboard is back after some time | Something re-added it. | Open the Status tab: the RE-ADD RISK lines show the source. Run the tool again. Please report it (section 17). |

---

## 16. FAQ

**Why does the taskbar say "ENG" when I type Swiss German?**
It shows the display language, not the keyboard. The keyboard is Swiss German. This is the same with a
manual setup.

**Can a user keep a second keyboard?**
Yes. Add it in step 1 before applying. The first keyboard in the list is the default.

**Does it touch anything else on the PC?**
No. Only the language settings: the registry keys listed in README.md, plus language packs when that
option is on. No policies, no other settings.

**Is it safe to run twice, or on a PC that is already standard?**
Yes. Already-correct settings show as UNCHANGED, and the result is the same.

**What happens to users who are not signed in?**
Nothing, unless you tick them under "Apply to". New users get the standard automatically, through the
new-user template.

**Do I have to be the signed-in user?**
No. Any administrator account works over the shoulder. The tool always changes the selected accounts,
never the admin account by accident.

**Can I undo it?**
Yes, on the Restore tab, except for uninstalled language packs.

**Does the user lose anything?**
Their other languages and keyboards on this PC, by design. No files, no other settings.

---

## 17. Logs, and what to send when something goes wrong

- Logs: `C:\ProgramData\LanguageProfile\Logs` (admin only). Every run writes one: `..._Session_...` for
  the window, `..._Apply_...` for each Apply, plus Restore/Status/Verify runs.
- In the tool: **Open log** on the Preview and apply tab opens the current one.
- Backups: `C:\ProgramData\LanguageProfile\Backups`.

When you report a problem, please send:

1. the newest `..._Apply_...` and `..._Session_...` logs;
2. a screenshot of the result or the error;
3. the output of `LanguageProfile.cmd -Status` (run it in an admin command prompt and save it with
   `> C:\status.txt`).

---

## 18. Test status

- Tested on a Windows 11 Enterprise 25H2 company device: the status and preview, the lock screen and new
  users, and removing a leftover English (UK) language.
- The step inside a signed-in user's session can be blocked on managed devices. The fallback for that
  case (section 11, point 5) is new and still being tested.
- Windows 10 22H2, starting from a network folder and the new step bar are not tested on a real PC yet.
- The full test list is in `tests/VM-TestPlan.md`.

Feedback and problem reports are welcome. Please include the logs (section 17).
