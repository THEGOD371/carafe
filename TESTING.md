# Manual test plan — milestone 1 (project skeleton + dependency installer)

These are the manual steps to verify before moving on to the bottles
milestone. Stop at the first failure and report what you see.

## 0. Prerequisites

- macOS 14+ on Apple Silicon (Carafe targets that explicitly).
- Xcode 15 or later installed (full Xcode, not just Command Line Tools).
- `xcodegen` installed:

  ```bash
  brew install xcodegen
  ```

## 1. Generate the Xcode project

```bash
cd "/Users/rubensandher/Documents/windows to mac convertor"
xcodegen generate
open Carafe.xcodeproj
```

**Expected:**
- `Carafe.xcodeproj` is created in the project root.
- Opening it in Xcode shows a `Carafe` target with source groups
  `App/`, `Core/`, `Onboarding/`, `Resources/`.
- No red files; no missing references.

## 2. Set signing

1. In Xcode, select the **Carafe** target → **Signing & Capabilities**.
2. Set **Team** to your personal Apple ID team (or any team you have).
3. Make sure **Signing Certificate** is "Apple Development".

Hardened Runtime is already on in `project.yml`. Don't toggle sandboxing
on — Carafe needs to shell out to brew/wine and that breaks under the
sandbox.

## 3. Build & run

In Xcode, hit ⌘R.

**Expected:**
- The app builds with no errors.
- A window titled **Carafe** opens at 900×600.
- You see the welcome screen with a wineglass icon, four bullets,
  and a **Get started** button.

## 4. Welcome → dependency installer flow

Click **Get started**.

**Expected:**
- The view transitions to the dependency installer.
- A spinner runs briefly while the four checkers run in parallel.
- After ~1 second the four rows show their detected state:
  - **Rosetta 2** — installed if `/Library/Apple/usr/share/rosetta/rosetta`
    exists; "Not installed" otherwise.
  - **Xcode Command Line Tools** — installed if `xcode-select -p`
    returns a valid path.
  - **Homebrew** — installed if `/opt/homebrew/bin/brew` exists.
  - **Apple Game Porting Toolkit** — installed only if `brew list
    --versions game-porting-toolkit` returns a row.

Verify the displayed state matches reality by running those probes in
Terminal yourself.

## 5. Log pane

Look at the right-side log pane:

- It should show one info line per checker with the result.
- **Copy** copies the log to the clipboard (paste somewhere to confirm).
- **Export…** writes a `.log` file under
  `~/Library/Application Support/Carafe/logs/` and reveals it in Finder.
- **Clear** empties the pane.

## 6. Re-check button

Click **Re-check all**.

**Expected:** all rows briefly show the spinner, then return to the
same state. Log gets four new info lines.

## 7. Auto-install — Rosetta

Only run this if Rosetta isn't already installed.

Click **Install** on the Rosetta row.

**Expected:**
- A macOS authorization dialog appears (Touch ID / password).
- After authenticating, the row shows the spinner.
- Log shows "Requesting administrator privileges to install Rosetta…"
- Process can take a few minutes on a fresh install.
- On success: row turns green with a checkmark.
- Cancelling the auth dialog: row returns to "Not installed."

## 8. Auto-install — Xcode CLT

Only if CLT isn't already installed.

Click **Install** on the **Xcode Command Line Tools** row.

**Expected:**
- The standard macOS CLT installer dialog appears.
- You click **Install** in that system dialog (not in Carafe).
- The Carafe row keeps polling until CLT becomes available
  (log shows "…still waiting for Command Line Tools.").
- When installation finishes, the row goes green.

## 9. Manual install — Homebrew

Click **How to install** on the **Homebrew** row.

**Expected:**
- The row expands and shows the canonical install command and three
  buttons: **Copy**, **Open Terminal**, **I've installed it — re-check**.
- **Copy** puts the curl-bash command on the clipboard.
- **Open Terminal** launches Terminal.app.
- After installing brew there, clicking the re-check button updates
  the row to green.
- The **Documentation** link opens https://brew.sh.

## 10. Auto-install — GPTK (via the Gcenx cask)

Only run this once Homebrew is installed.

> **Why not Apple's formula?** Apple's `apple/apple/game-porting-toolkit`
> depends on `openssl@1.1`, which Homebrew disabled on 2024-10-24. The
> formula has been broken for end users since then. The community fix
> is **Gcenx's pre-built cask** — see `GPTKChecker.swift` for the
> rationale block.

Click **Install** on the **Apple Game Porting Toolkit** row.

**Expected (happy path):**
- Log streams `brew tap gcenx/wine` then
  `brew install --cask gcenx/wine/game-porting-toolkit` (note: no
  `--no-quarantine` flag — Homebrew 5.1.14 removed it).
- Cask download is ~1 GB. Row stays in spinner.
- The cask installs `Game Porting Toolkit.app` to `/Applications/`
  and symlinks `wine64`, `wine64-preloader`, `wineserver` into
  `/opt/homebrew/bin/`. The cask's own postflight strips quarantine
  and ad-hoc codesigns the bundle.
- After brew finishes, Carafe runs
  `xattr -dr com.apple.quarantine "/Applications/Game Porting Toolkit.app"`
  as a safety net. Log shows either "Quarantine attribute cleared."
  or a benign "no such xattr" treated as already-clean.
- Carafe then verifies the .app exists AND
  `/opt/homebrew/bin/wine64` exists and is executable.
- On success: row turns green with version `cask 3.0-2` (or newer);
  log ends with "GPTK install verified."
- From Terminal:
  ```bash
  /opt/homebrew/bin/brew list --cask --versions game-porting-toolkit
  /opt/homebrew/bin/wine64 --version
  xattr "/Applications/Game Porting Toolkit.app"   # should print nothing
  ```
  The first two should succeed. The third should be empty (no
  quarantine attr left).

**If you see the openssl@1.1 error again:**
- The install command in the log must reference `gcenx/wine/...`, not
  `apple/apple/...`. If it doesn't, something's wrong in
  `GPTKChecker.install(log:)` — there's a specific stderr scanner
  that surfaces this loudly.

**If you see the `--no-quarantine` rejection again:**
- Means a future edit reintroduced the flag. Carafe will throw a
  specific "check GPTKChecker.swift for a regression" error.

**Installed-with-warning outcome:**
- If `brew install` succeeds AND the .app + wine64 symlink verify,
  but `xattr` reports a non-benign failure (e.g., managed Mac with
  MDM-locked quarantine):
  - Row goes green (status: installed) — *not* failed.
  - Log shows `⚠️ xattr post-step warning: ...` followed by the
    fallback note: "If the wine binaries get blocked on first launch,
    right-click → Open the .app in Finder."
- Verify by trying to launch the .app from `/Applications` once; if
  Gatekeeper blocks, right-click → Open → "Open" in the dialog. After
  that, Gatekeeper trusts it for future launches.

**Expected (auto-install fails for any other reason):**
- Row goes red.
- A "Manual install" block appears under the row with three numbered
  steps (tap, install, xattr) plus a fourth step explaining the
  right-click → Open Gatekeeper fallback.
- Each command has its own **Copy** button; a **Copy all commands**
  button at the bottom copies all three lines at once.
- **Open Terminal** button launches Terminal.
- Run the commands manually, then click **I've installed it — re-check**.

> **Heads-up:** brittle string matches in `GPTKChecker.install(log:)`
> are tagged with `FRAGILITY:` comments. Two specific ones to watch:
> the openssl@1.1 sanity check (Apple-formula regression detector)
> and the `--no-quarantine` rejection check (flag-regression
> detector). If Gcenx moves the tap, both the auto-install command
> and the manual fallback steps need updating.

## 10a. Skip for now — degraded mode

If you don't want to install GPTK right now (e.g., you're developing
other features and just need onboarding to complete):

1. On any missing/failed row, click the **⋯** (ellipsis) menu next
   to the Install button.
2. Choose **Skip for now**.

**Expected:**
- The row dims (~55% opacity) and the icon turns into a gray minus
  symbol.
- The status text reads "Skipped — features that depend on this will
  be unavailable."
- A yellow banner appears above the footer listing every skipped dep,
  with an **Unskip all** button.
- The **Continue** button becomes enabled (gated on
  installed-or-skipped, not just installed).
- The footer status reads "Ready to continue in degraded mode."

Click **Continue**. The post-onboarding placeholder loads as usual.

**Persistence check:**
- Quit Carafe (⌘Q) and relaunch.
- The skipped state is persisted under
  `UserDefaults` key `carafe.skippedDependencies` (an array of
  dependency IDs).
- From Terminal:
  ```bash
  defaults read dev.carafe.Carafe carafe.skippedDependencies
  ```
  should print the IDs you skipped (e.g., `("gptk")`).
- When you later open the onboarding flow again (via "Reset
  onboarding (debug)" on the placeholder screen), the same deps
  should still appear as skipped.

To clear skip state from the UI: open the row's Unskip button, or
click **Unskip all** in the banner.

## 11. Continue gate

The **Continue** button stays disabled until every row is either green
**or** skipped (see step 10a).

When all four are installed (or skipped):

- Click **Continue**.
- The window switches to the post-onboarding placeholder
  ("Carafe is ready. Library, bottles, and install flow ship in the
  next milestone.").
- Relaunch the app — it should skip straight to the placeholder.
- Click **Reset onboarding (debug)** — it should return to the welcome
  screen, and the next launch starts at welcome again.

## 12. Spot-check on-disk state

```bash
ls -la "$HOME/Library/Application Support/Carafe/"
```

**Expected:**
- A `Carafe/` directory.
- A `Bottles/` subdirectory (empty — created eagerly by `AppState`).
- A `logs/` subdirectory if you exported logs.

## What to report back

1. Whether each step matched the expected behaviour.
2. Any rough edges in the UI (alignment, copy that didn't work, etc.).
3. The exact GPTK install outcome from step 10 — happy path, openssl
   sanity check fired, or generic failure with the fallback block.
4. Whether the skip-for-now flow felt right, or if the menu placement
   / banner copy needs work.
5. Anything else that surprised you.

---

# Milestone 2 — Bottle CRUD

These steps assume milestone 1 passed and onboarding is complete
(or skipped). They cover the library view, the bottle lifecycle, and
the documented edge cases.

## B1. Generate + build

If you re-pulled or `project.yml` changed:

```bash
xcodegen generate
```

Build & run. After onboarding (or the post-onboarding placeholder
becomes the new library), you should land on an empty library view.

## B2. Empty state

**Expected:**
- Centred wineglass icon, the heading "No bottles yet", a short
  description, and a **Create your first bottle** button.
- The toolbar has a circular **Refresh** button on the left and a
  **+ New Bottle** button on the right.
- The gear menu (right side of toolbar) exposes
  "Reset onboarding (debug)".

## B3. Create a bottle (happy path)

Click **New Bottle** (toolbar) OR **Create your first bottle** (empty
state).

**Expected sheet:**
- Title "New bottle" with a wineglass icon.
- Three fields: **Name** (text), **Windows version** (picker, default
  Windows 10), **Wine build** (picker, disabled — pre-populated with
  the detected `wine64 --version` token from the GPTK install).
- Footer: "Initialization takes about 30 seconds." + Cancel / Create.
- Create disabled until name is non-empty.

Enter `Test Bottle 1`, leave Windows version on Windows 10, click
**Create**.

**Expected:**
- Sheet dismisses.
- An operation sheet opens with title "Creating "Test Bottle 1"".
- Stage label updates through:
  `Creating folder…` → `Initializing prefix (this may take 30 seconds or more)…` → `Applying Windows version…` → `Writing metadata…` → `Done.`
- The log pane fills with wineboot output (the wine debug stream from
  GPTK is verbose — fixmes, warnings, etc. Expected.)
- After ~30-60 seconds, the spinner is replaced by a green checkmark
  and the **Close** button becomes prominent.
- Click **Close**.
- The library now shows one row with the new bottle's name,
  wine version, Windows 10, "Never" for last used, and a size that
  fills in within a second or two ("…" briefly while it computes).

**Verify on disk:**

```bash
ls -la "$HOME/Library/Application Support/Carafe/Bottles/"
# Expect: one UUID-named subfolder containing metadata.json + the
# wine prefix (drive_c/, system.reg, user.reg, etc.)

cat "$HOME/Library/Application Support/Carafe/Bottles/<uuid>/metadata.json"
# Expect: pretty-printed JSON with schemaVersion: 1, the name you
# typed, ISO-8601 createdAt, etc.
```

## B4. Sort columns

Click each column header. The list re-sorts. Click again — direction
flips.

**Expected sortability:**
- **Name** (alphabetical)
- **Wine** (alphabetical)
- **Windows** (alphabetical by display name)
- **Last used** (chronological — bottles never launched group at the
  bottom under "Never" via `Date.distantPast`)
- **Size** (numeric — bytes; nil treated as 0 for sort, "…" for
  display)

## B5. Rename (metadata only)

Right-click the row → **Rename…**. An alert appears with a text
field pre-filled with the current name.

Change to `Renamed Bottle`, click **Rename**.

**Expected:**
- The row updates immediately.
- On disk, the **folder name is unchanged** (still a UUID).
- `metadata.json` inside has the new name.
- Confirm:

  ```bash
  ls "$HOME/Library/Application Support/Carafe/Bottles/"
  # Same UUID folder as before.
  cat "$HOME/Library/Application Support/Carafe/Bottles/<uuid>/metadata.json" | grep name
  # "name" : "Renamed Bottle"
  ```

> Why the folder stays a UUID: wine prefixes embed absolute paths in
> the registry. Renaming the folder would silently break every
> install inside.

## B6. Duplicate

Right-click → **Duplicate…**. Alert prompts for the new name,
seeded with `<original> Copy`.

Accept the suggestion, click **Duplicate**.

**Expected:**
- Operation sheet opens.
- Stage: `Shutting down any running wine processes in the source bottle…`
- Then: `Copying prefix files…` with a real progress bar showing
  bytes copied / total bytes + a percentage.
- The "stage" label below the title updates with `Copying: <relative path>`
  for the current file. Wine prefixes have lots of small files; the
  label changes rapidly.
- For a fresh bottle this is ~150 MB so it completes in 1-5 seconds.
  For a bottle with games installed, expect minutes and watch the
  progress bar actually move.
- On completion: green checkmark, Close button.
- New row appears in the library.

## B7. Show in Finder

Right-click → **Show in Finder**. Finder opens with the UUID folder
selected.

## B8. Open Wine Configuration

Right-click → **Open Wine Configuration**.

**Expected:**
- `winecfg` launches as a separate GUI window after a couple of
  seconds (wine is starting from cold).
- The window is the standard Wine config dialog. Carafe doesn't
  wait for you to close it; you can keep using Carafe in parallel.

Close winecfg when done.

## B9. Delete to Trash

Right-click → **Move to Trash…**.

**Expected:**
- A confirmation dialog appears with the bottle name in the title and
  the message "The bottle will be moved to the Trash so you can
  recover it later."
- Click **Move to Trash**.
- The row disappears from the library.
- Check Finder's Trash — the UUID folder should be there.
- Putting it back from Trash: drag it back to
  `~/Library/Application Support/Carafe/Bottles/`, then click
  **Refresh** in Carafe's toolbar. The bottle reappears.

## B10. Edge case — externally deleted folder

While Carafe is running:

```bash
rm -rf "$HOME/Library/Application Support/Carafe/Bottles/<some-uuid>"
```

In Carafe, click **Refresh**.

**Expected:** the row disappears cleanly. No error, no crash.

## B11. Edge case — corrupt metadata

Pick a bottle. With Carafe running:

```bash
echo 'this is not json' > "$HOME/Library/Application Support/Carafe/Bottles/<uuid>/metadata.json"
```

Refresh.

**Expected:**
- The row is replaced with a "corrupted" entry: the bottle's
  folder name (UUID) appears in the **Name** column with an orange
  warning triangle next to it (hover for the parse-error reason);
  Wine, Windows, and Size show "—"; row text is dimmed.
- Right-click → context menu shows only **Repair**, **Show in
  Finder**, **Move to Trash**.
- Click **Repair**. A fresh `metadata.json` is generated using the
  folder UUID, name "Repaired bottle <prefix>", Windows 10 default.
- Refresh — the row becomes a normal valid bottle.

## B12. Edge case — missing metadata

```bash
rm "$HOME/Library/Application Support/Carafe/Bottles/<uuid>/metadata.json"
```

Refresh. Same corrupted behaviour as B11 but the reason text reads
"metadata.json is missing".

## B13. Edge case — wineboot fails partway

Hard to simulate cleanly, but two ways:

**(a) Force-quit the operation:** while a create is in flight, ⌘Q
Carafe. On relaunch, the half-init folder will appear as a
corrupted bottle (no metadata.json was written). Repair it or Trash
it.

**(b) Break the wine path:** temporarily move the GPTK app aside:
```bash
sudo mv "/Applications/Game Porting Toolkit.app" "/Applications/Game Porting Toolkit.app.bak"
```
Try to create a new bottle. Expected: the operation sheet shows
"failed" with the error from `BottleError.wineNotInstalled`. The
half-created folder gets trashed automatically (check Trash).

Don't forget to:
```bash
sudo mv "/Applications/Game Porting Toolkit.app.bak" "/Applications/Game Porting Toolkit.app"
```

## B14. Name collision

Try to create a second bottle with the same name as an existing one.

**Expected:**
- The error alert at the top level fires with
  "A bottle named "X" already exists."
- No half-created folder on disk.

(Same check applies to rename and duplicate.)

## What to report back

1. Which steps passed.
2. Specifically — what does the duplicate progress feel like? Smooth
   updates, or jittery? Does the per-file path label update at a
   sensible rate, or so fast it's noise?
3. Whether winecfg actually launches (this is the first time we shell
   into the bundled wine GUI, so it's a real check that the
   environment + binary resolution work).
4. Any crashes, hangs, or `lastError` alerts that fired with messages
   that didn't make sense.
5. Whether the corrupted-bottle treatment is the right call (we could
   alternatively just hide them — let me know what feels right).

---

# Milestone 3 — Run an Executable

These steps assume the bottle CRUD milestone passed and you have at
least one valid bottle in the library.

## R0. Get a test executable

The safest first-test exe is **PuTTY** — it's tiny (~1.6 MB), a
single self-contained binary, has worked on Wine for ~20 years, and
opens a clear GUI window so you can tell at a glance whether the
launch succeeded.

Download:

```bash
mkdir -p ~/Downloads/carafe-tests
curl -L -o ~/Downloads/carafe-tests/putty.exe \
  https://the.earth.li/~sgtatham/putty/latest/w64/putty.exe
file ~/Downloads/carafe-tests/putty.exe
# Expect: "PE32+ executable (GUI) x86-64, for MS Windows..."
```

Optional second test: any other free Windows app you trust. Avoid
games on the first pass — they exercise the renderer, audio, and a
dozen DLLs simultaneously, which is too many things to debug at once.

## R1. Open the Launch sheet from the toolbar

In Carafe, select a bottle in the library, then click the
**▶ Run Executable** button in the toolbar.

**Expected:**
- A sheet opens titled "Run an executable" with sub-header "In bottle: <name>".
- The **Bottle** dropdown is pre-selected to the one you had selected
  in the table.
- The **Executable** row reads "No file selected".
- The **Run** button is disabled, with the footer hint "Pick an
  executable first."

Cancel out.

## R2. Open the Launch sheet from the context menu

Right-click a bottle row → **Run Executable…**.

**Expected:** same sheet, scoped to that bottle.

## R3. Pick the test exe

Click **Choose…**. NSOpenPanel opens, filtered to .exe / .msi.

Navigate to `~/Downloads/carafe-tests/putty.exe` and select it.

**Expected:**
- The path appears in the Executable row.
- The Run button enables.
- No form error.

## R4. Non-PE rejection

Cancel out, then create a fake exe:

```bash
echo "this is not really an exe" > ~/Downloads/carafe-tests/fake.exe
```

Reopen the Launch sheet, click Choose…, pick `fake.exe`.

**Expected:**
- A red error appears below the form:
  "fake.exe doesn't look like a Windows executable (no MZ header)."
- The Executable row stays at "No file selected" — bad picks are
  rejected, not silently accepted.

## R5. Bottle-busy block

Start a duplicate of any bottle (right-click → Duplicate…). While the
operation sheet is showing progress, try to open the Launch sheet
from the toolbar.

**Expected:**
- Sheet opens but the Run button stays disabled, with footer hint
  "A bottle operation is in progress. Wait for it to finish."

Let the duplicate finish (or close that sheet).

## R6. Launch the test exe (happy path)

Reopen Launch, pick `putty.exe`, leave arguments blank, click **Run**.

**Expected:**
- The sheet flips into running mode: status bar with exe name, a
  green dot, elapsed-time counter, and a big log pane.
- Log starts with a few `info` lines from Carafe:
  ```
  Launching putty.exe in bottle "<name>"
  Working directory: /Users/.../carafe-tests
  Running (pid <NNN>).
  ```
- Then comes wine's own logging — a flurry of `err:` and `warn:`
  lines as wine spins up. (We set WINEDEBUG=fixme-all so the bulk
  of the `fixme:` noise is suppressed, but errors and warnings still
  pass through; that's intentional.)
- After ~3-10 seconds: **a PuTTY window appears** as a real macOS
  window. That's the proof point.

## R7. Stop button

Without closing PuTTY, click **Stop** in the Carafe sheet.

**Expected:**
- Log line: `Stop requested by user.`
- Within ~2 seconds, the PuTTY window closes.
- The status icon turns gray (stopped); the row reads
  "Stopped by user".
- The elapsed counter freezes.
- Stop button disappears; Restart and Close (no longer "Stop & Close")
  become available.

Verify there's no orphaned wineserver:

```bash
ps aux | grep -i wineserver | grep -v grep
```

Should print nothing. If it does, that's a regression — note the PID
and the prefix path in your report.

## R8. Restart with same params

Click **Restart**.

**Expected:**
- Log gains a new "Launching…" block but the previous log lines stay
  visible above (we don't auto-clear — easier to compare runs).
- A new PuTTY window opens.

Close PuTTY normally (the window's red dot, or File → Exit).

**Expected:**
- Status icon turns green checkmark.
- Status reads "Exited cleanly".
- Log shows `Process exited with code 0.`

## R9. Exit code surfacing

Restart, then this time force-quit PuTTY from outside — e.g., right-
click PuTTY in the Dock → Quit, OR:

```bash
pkill -KILL -f putty.exe
```

**Expected:**
- Status icon turns orange exclamation.
- Status reads "Exited with code <non-zero>".
- The last several lines of wine's stderr appear in the log (the
  `err:` messages around the crash).

## R10. Missing exe at run-time

Restart, then delete the exe while the form is open:

```bash
rm ~/Downloads/carafe-tests/putty.exe
```

Click Run.

**Expected:**
- Status flips to red "Failed" with reason:
  "File not found: /Users/.../putty.exe"

Re-download for the rest of the tests:

```bash
curl -L -o ~/Downloads/carafe-tests/putty.exe \
  https://the.earth.li/~sgtatham/putty/latest/w64/putty.exe
```

## R11. Close-while-running cleanup

Launch PuTTY again. While it's running, click **Stop & Close** in
Carafe.

**Expected:**
- PuTTY window closes within ~2 seconds.
- Carafe sheet dismisses.
- `ps aux | grep wineserver` is empty.
- `ls "$HOME/Library/Application Support/Carafe/Bottles/<uuid>/"`
  shows the prefix intact (we don't touch it on stop — only the
  running processes get killed).

## R12. Arguments parsing

Reopen Launch, pick putty.exe, type into Launch arguments:

```
-load "Default Settings"
```

Click Run.

**Expected:**
- The log's "Arguments:" line shows: `-load Default Settings`
- (Whitespace splitting is naive; quoted segments stay together.)

PuTTY may or may not honour that flag — the point is to verify args
flow through to wine. Close PuTTY when done.

## R13. Environment disclosure

In the form (with a bottle selected), click "Resolved environment".

**Expected:**
- The block expands and lists key=value pairs in monospaced font.
- Confirms WINEPREFIX points at the bottle, WINEMSYNC=1,
  WINEDEBUG=fixme-all, MTL_HUD_ENABLED=0, PATH includes /opt/homebrew/bin.
- DLL overrides / per-bottle env vars (empty for a fresh bottle)
  would appear here as they're added in the per-game config milestone.

## R14. DLL-missing surface (optional)

If you have an exe that depends on a Visual C++ runtime DLL that
isn't installed in the bottle (some games packaged for win10+
expect vcruntime140.dll, msvcp140.dll, etc.), launching it should:

- Fail with a non-zero exit code.
- Show wine's `err:module:import_dll` lines in the log clearly.

We'll add winetricks-based runtime installation in a later milestone;
for now this is "we surface the error readably" not "we fix it".

## What to report back

1. R6 — did the PuTTY window actually appear, and how long did it
   take? (First wine launch in a fresh prefix is slow because it
   builds caches.)
2. R7 — did Stop kill the process within 2 seconds, or did it need
   the wineserver-kill fallback? (Log line tells you.)
3. R11 — anything left in `ps aux | grep wineserver` after closing?
4. Any unexpected behaviour around restart, args parsing, or the
   log pane's auto-scroll / colours.
5. Stuff you wish the UI did but doesn't.

---

# Milestone 4 — Library View with Cover Art

This milestone is large. Before building, **re-run xcodegen**:

```bash
cd "/Users/rubensandher/Documents/windows to mac convertor"
xcodegen generate
open Carafe.xcodeproj
```

(Close any Xcode window on the old project first.) New files this
milestone:

- `Carafe/Core/Library/Game.swift`
- `Carafe/Core/Library/GameLibrary.swift`
- `Carafe/Core/Library/CarafeKeychain.swift`
- `Carafe/Core/Library/SteamGridDBClient.swift`
- `Carafe/Library/CoverArtView.swift`
- `Carafe/Library/RunningSessionView.swift` (extracted from LaunchExeSheet)
- `Carafe/Library/LaunchGameSheet.swift`
- `Carafe/Library/GameFormSheet.swift`
- `Carafe/Library/CoverArtPickerSheet.swift`
- `Carafe/Library/LibraryGridView.swift`
- `Carafe/Library/APIKeysSheet.swift`
- `Carafe/App/MainShell.swift`

## L0. First launch — new shell

Build & run. After onboarding, you should land on the **new** main
shell:

**Expected:**
- A sidebar on the left with two items: **Library** (selected by
  default) and **Bottles**.
- Main pane shows the Library grid's empty state with a wineglass-on-
  stack icon, "No games yet" heading, and an "Add your first game"
  button.
- If you have no valid bottles, the button is disabled and an orange
  note says "You'll need at least one bottle first — switch to the
  Bottles tab in the sidebar."
- Click the gear icon (top-right of the detail pane). It opens a menu
  with **API Keys…** and **Reset onboarding (debug)**.

## L1. Get a SteamGridDB API key

Click gear → **API Keys…**. The sheet opens.

**Expected sheet:**
- Title "API Keys", section "SteamGridDB"
- A secure-entry field for the key
- "Test", "Save", and (if a key is already stored) "Clear stored key" buttons
- A "How to get a free key" disclosure with five numbered steps

Follow the steps in the disclosure:

1. Open **https://www.steamgriddb.com** in your browser.
2. Sign in (Discord / Google / Steam — your call).
3. Click your avatar → **Preferences**.
4. Open the **API** tab in the sidebar.
5. Click **Generate API Key**, copy it.

Back in Carafe, paste the key into the field. Click **Test**.

**Expected:**
- "Validating…" appears next to the buttons for ~1 second.
- Resolves to a green "Valid" label.

Click **Save**.

**Expected:**
- "Stored" badge appears next to the SteamGridDB heading.
- The text field clears (we never re-display the saved key — only
  show that one exists).

**Verify Keychain storage from Terminal:**

```bash
security find-generic-password -s "dev.carafe.Carafe" -a "steamgriddb-api-key"
```

Should print account info but NOT the password (without `-w` and an
auth prompt). The point is that it exists.

## L2. Switch sidebar to Bottles, then back

Click **Bottles** in the sidebar.

**Expected:**
- Detail pane swaps to the bottle table from the previous milestone.
- All your existing bottles still there (Library and Bottles share
  the same data — switching is just UI).

Click **Library** to return.

## L3. Add a game

You need at least one bottle with PuTTY (or any test exe) installed.
Easiest path: copy `~/Downloads/carafe-tests/putty.exe` into a bottle's
`drive_c/`:

```bash
BOTTLE_ID=$(ls ~/Library/Application\ Support/Carafe/Bottles/ | head -1)
cp ~/Downloads/carafe-tests/putty.exe \
   ~/Library/Application\ Support/Carafe/Bottles/$BOTTLE_ID/drive_c/
```

In Carafe, click **Add Game** (toolbar, top-right).

**Expected sheet:**
- Title "Add game", icon + plus
- Cover art row showing a placeholder (initials of the placeholder
  name "?") on a coloured gradient
- Name (empty), Bottle (auto-selected), Executable (No file selected),
  Launch arguments fields

Click **Choose…** next to Executable.

**Expected:**
- NSOpenPanel opens defaulted to the selected bottle's `drive_c/`.
- File filter shows only `.exe` and `.msi`.

Navigate to `putty.exe` (the one you just copied), select it.

**Expected:**
- Path appears in the Executable row.
- Name auto-fills to "Putty" (or similar — `GameLibrary.suggestedName`
  splits CamelCase / hyphens / underscores and title-cases).
- The cover art placeholder updates to show "P" on a new colour.

Change the name to **PuTTY**. Click **Add to Library**.

**Expected:**
- Sheet dismisses.
- A tile appears in the library grid with the PuTTY placeholder
  cover, name "PuTTY", and subline "Never played".

## L4. Choose cover art

Right-click the PuTTY tile → **Edit…**.

**Expected:**
- GameFormSheet opens in edit mode with all fields pre-filled.

In the Cover art row, click **Choose cover art…**.

**Expected:**
- CoverArtPickerSheet opens.
- The search field is pre-filled with "PuTTY".
- A search is kicked off automatically — within ~1 second, matches
  appear in the left column.
- For "PuTTY" you'll likely get few/no useful matches (it's not a
  game) — that's a useful test of the empty state. Try searching
  for something well-known like "Half-Life" or "Portal".

Click a match in the left column.

**Expected:**
- "Loading covers…" briefly.
- Right pane fills with a grid of portrait cover thumbnails.

Click any thumbnail.

**Expected:**
- Brief "downloading" state.
- Sheet dismisses.
- The cover art row in GameFormSheet now shows the downloaded image
  instead of the placeholder.

Click **Save changes**.

**Expected:**
- Sheet dismisses.
- The tile in the library grid now shows the real cover art.

**Verify caching:**

```bash
ls ~/Library/Application\ Support/Carafe/CoverArt/
```

Should contain a file named `<uuid>.jpg` (or .png) matching the
game's id from `library.json`.

## L5. Launch via tile click

Hover over the PuTTY tile.

**Expected:**
- Cover dims and a glassy **Play** button appears over the centre.

Click the tile (anywhere — not just the Play button).

**Expected:**
- LaunchGameSheet opens.
- Header reads "PuTTY" with sub-line "Bottle: <bottle name>".
- The session starts immediately — no exe-picker, no form.
- After cold-start, a PuTTY window appears.

Close PuTTY normally (window's red dot or File → Exit).

**Expected:**
- Status icon turns green checkmark, "Exited cleanly".
- Click **Close**.
- Back in the grid, the PuTTY tile's subline now reads "Played a few
  seconds ago" (or similar relative time).

## L6. Play time accumulates

Launch PuTTY again, leave it for ~30 seconds, close it.

**Expected:**
- The session was tracked. From Terminal:
  ```bash
  cat ~/Library/Application\ Support/Carafe/library.json \
    | python3 -m json.tool
  ```
- `totalPlaytime` should be the sum across both sessions (in
  seconds; wall-clock includes the cold-start time).
- `lastPlayedAt` updated to the latest run.

## L7. No API key — graceful degradation

Open API Keys → Clear stored key. Confirm "Stored" badge disappears.

Try to add a new game and click **Choose cover art…** on the cover row.

**Expected:**
- CoverArtPickerSheet opens but shows a "Set up a SteamGridDB API key"
  centred state instead of the search UI.
- Adding the game without picking cover art works — the placeholder
  is fine.

Restore the key afterward.

## L8. Edit name + args round-trip

Right-click PuTTY tile → **Edit…**. Change name to "Putty Test", set
arguments to `-load "Default Settings"`. Save.

**Expected:**
- Tile renames immediately.
- Re-launch — the LaunchGameSheet's log "Arguments:" line should now
  include the args.

## L9. Show in Finder

Right-click → **Show in Finder**. Finder opens with the exe file
selected.

## L10. Edge case — exe missing

Move the exe aside while Carafe is running:

```bash
mv ~/Library/Application\ Support/Carafe/Bottles/$BOTTLE_ID/drive_c/putty.exe \
   ~/Library/Application\ Support/Carafe/Bottles/$BOTTLE_ID/drive_c/putty.exe.bak
```

In the grid, the tile should refresh on next render (resize the
window if it doesn't update).

**Expected:**
- An orange "Exe missing" badge appears on the cover, top-left.
- Subline reads "Exe not found".
- Click the tile — nothing happens (clicks ignored for non-ok status).
- Right-click → context menu now includes **Relocate exe…**.
- Click Relocate exe…, navigate back to `putty.exe.bak`, select.
  (Or restore the original name with `mv` first then Relocate.)

Restore:
```bash
mv ~/Library/Application\ Support/Carafe/Bottles/$BOTTLE_ID/drive_c/putty.exe.bak \
   ~/Library/Application\ Support/Carafe/Bottles/$BOTTLE_ID/drive_c/putty.exe
```

## L11. Edge case — bottle deleted

In the Bottles tab, right-click the bottle holding PuTTY → Move to Trash.
Confirm.

Switch back to Library.

**Expected:**
- PuTTY tile shows a red "Bottle missing" badge.
- Context menu offers **Remap to another bottle…**
- Pick it → sheet opens with the remaining valid bottles.
- Choose one, click Remap.
- Tile updates (may still show "Exe missing" if the exe isn't in the
  new bottle; that's the expected next-step in recovery).

Drag the deleted bottle out of Trash if you want to restore.

## L12. Remove from Library (non-destructive)

Right-click PuTTY tile → **Remove from Library**.

**Expected:**
- Confirmation dialog with the right message: "This only removes the
  library entry. The bottle and the exe stay on disk."
- Click Remove from Library.
- Tile disappears.
- From Terminal:
  ```bash
  ls ~/Library/Application\ Support/Carafe/Bottles/$BOTTLE_ID/drive_c/putty.exe
  ```
  Exe is still there. The bottle and exe were NOT deleted.

## L13. Rate limit / network failure (optional)

Disconnect from the network. Try to add cover art via the picker.

**Expected:**
- A red inline error appears above the search results panel:
  something like "Network error: The Internet connection appears to
  be offline." The picker doesn't crash.

Reconnect.

## L14. SteamGridDB 401

Open API Keys → paste a garbage string → Test.

**Expected:**
- Red "SteamGridDB rejected the API key (401). Check that it's pasted
  correctly." next to the buttons.
- The currently-stored key is NOT overwritten (we only save on the
  Save button, and Save is enabled regardless — the user can still
  knowingly save a bad key).

## What to report back

1. L4 — does the SteamGridDB search + cover picker actually work end
   to end? (This is the most network-dependent piece; we've never
   exercised it before.)
2. L5 — does single-click on a tile feel right, or does it trigger
   accidental launches? (Steam single-clicks too, but our hover
   overlay might invite an extra click sometimes.)
3. L6 — does the play time math come out reasonable in
   `library.json`? Wall-clock including cold start is intentional;
   confirm it's not way off.
4. L10/L11 — do the orphan recovery flows feel obvious?
5. Anything that's slow, ugly, or surprising.

---

# Milestone 5 — Component Installer + Local Cover Art

Re-run xcodegen before ⌘B:

```bash
cd "/Users/rubensandher/Documents/windows to mac convertor"
xcodegen generate
open Carafe.xcodeproj
```

New files this milestone:

- `Carafe/Core/Components/WinetricksComponent.swift`
- `Carafe/Core/Components/WinetricksRunner.swift`
- `Carafe/Library/ComponentsSheet.swift`

Existing bottles' metadata.json files are forward-compatible — the
new `installedComponents` field is optional on decode. Confirm by
opening any existing bottle's metadata.json after this milestone
ships and checking the JSON is unchanged until the next time the
bottle is written (e.g., after a rename).

## C1. winetricks detection (not installed)

Right-click any bottle in the Bottles tab → **Install Components…**.

**Expected (if winetricks isn't installed):**
- Sheet opens with header "Install components" + sub-line "In bottle: <name>".
- The body shows the "winetricks isn't installed yet" state with a
  copyable `brew install winetricks` block and an **Install via
  Homebrew** button.

## C2. Install winetricks via Homebrew

Click **Install via Homebrew**.

**Expected:**
- The body flips to a streaming log pane.
- You see `brew install winetricks` output: tap update, dependency
  resolution, download of `winetricks` (~50 KB shell script + a few
  Perl deps), final install path.
- Total time ~30 seconds.
- On success, the sheet flips to the picker view (see C3).
- On failure, you stay on the "winetricks missing" state with the
  error appended to the log; can retry.

Verify from Terminal:
```bash
which winetricks    # /opt/homebrew/bin/winetricks
winetricks --version
```

## C3. The picker

**Expected:**
- A search field at top.
- Sections grouped by category in this order: Visual C++ runtimes,
  .NET Framework, DirectX shims, Media, Fonts, Gaming libraries.
- Each row: checkbox, display name, monospaced `(verb)`, approximate
  size, summary text below.
- Footer: "Pick one or more components to install." + Cancel + Run.

Type "vcrun" into the filter.

**Expected:**
- Only Visual C++ rows remain visible; other categories collapse out
  of view.

Clear the filter. Select **VC++ 2015–2019** (vcrun2019),
**d3dcompiler_47**, and **Microsoft Core Fonts** (corefonts).

**Expected:**
- Footer updates to "Install 3 components".

## C4. Run the install

Click **Install 3 components**.

**Expected:**
- Sheet flips to the installing view.
- Left pane: step list with each component, status icon (pending
  circle → spinner when running → green check or red X).
- Right pane: streaming log, top header reads "Installing
  vcrun2019…" (or whichever is current).
- Log starts with `[1/3] VC++ 2015–2019 — vcrun2019`, then a torrent
  of winetricks output: downloads from MS CDN, wine init noise,
  registry writes.
- Each verb takes 30 s – 3 min depending on size. vcrun2019 + corefonts
  + d3dcompiler_47 should total ~5 minutes on a fresh bottle.
- On success, step icon turns green; we move to the next verb.
- On failure (which happens — see C5), step turns red with the
  failure reason. The batch continues to the next verb.

When all done:

**Expected:**
- Header badge in the title bar reads
  "<N> installed, <M> failed" (matching the actual results).
- Footer shows **Close** + (if anything failed) **Retry failed (N)**.

## C5. Verb failure is expected — confirm graceful handling

Microsoft retires download URLs constantly. Pick a likely-flaky one
to stress-test the failure path. **xna40** is a good candidate
historically.

Run a new install with just `xna40` selected.

If it succeeds, great — try `dotnet35sp1` or `wmp11` instead;
something will fail eventually.

**Expected (failure path):**
- Step icon turns red.
- Step row shows a short failure reason (e.g., "winetricks exited
  with code 1").
- Log pane contains the actual error from winetricks/wine.
- After the batch ends, **Retry failed** appears. Clicking it
  re-runs just the failed verbs.

## C6. Installed badges persist

Close the sheet. Re-open Install Components on the same bottle.

**Expected:**
- The verbs you successfully installed (vcrun2019, etc.) now show a
  green **Installed** badge next to their names.
- They remain selectable — re-selecting and running will reinstall
  (winetricks accepts this and just re-applies).

Verify on disk:
```bash
cat "$HOME/Library/Application Support/Carafe/Bottles/<bottle-uuid>/metadata.json" \
  | python3 -m json.tool
```
Should show an `installedComponents` array including the verbs that
succeeded.

## C7. Bottle duplicate carries components

In the Bottles tab, duplicate the bottle. Open Install Components on
the new copy.

**Expected:**
- The same green Installed badges appear on the duplicate, because
  the prefix files were copied AND the `installedComponents` array
  was carried over in metadata.

## C8. Game tile context-menu route

In the library, right-click a game tile → **Install Components in
bottle…**.

**Expected:**
- ComponentsSheet opens for that game's bottle (same as if you'd
  used the Bottles tab).

## C9. Local cover art — Use local image button

Have a JPEG / PNG ready (e.g. download any image to Downloads).

In a game's Edit form, click **Use local image…** in the cover art
row.

**Expected:**
- NSOpenPanel filtered to image types.
- Pick an image.
- The cover preview thumbnail in the form updates immediately.
- Save changes — the tile shows your image.

Verify the original image is untouched (we copy, not move):
```bash
ls -la ~/Downloads/your-image.jpg
ls ~/Library/Application\ Support/Carafe/CoverArt/
```
The original is still in Downloads; a copy exists under CoverArt
named `<game-id>.<ext>`.

## C10. Local cover art — drag and drop

From Finder, drag an image file directly onto a game tile in the
library grid.

**Expected:**
- While dragging over the tile, a dashed blue border appears around
  the cover with a "Drop image to set cover" badge overlay.
- On drop, the tile's cover updates immediately.

Try also from a browser: drag an image off a web page. Some browsers
provide the dragged image as a file URL (works), others provide it
as image data only (won't work in v1 — drop will be ignored). Finder
drag-drop is the reliable path.

## C11. Existing bottles still load

Bottles created before this milestone don't have `installedComponents`
in their metadata.json. Open one in the Bottles tab.

**Expected:**
- Loads cleanly with no errors.
- Install Components → picker shows zero Installed badges (expected;
  we don't have a ledger for pre-milestone installs).
- After running an install through Carafe, the badge persists going
  forward.

## What to report back

1. C2 — does brew install winetricks complete cleanly? It's tiny but
   may pull a few deps.
2. C4 — how long did vcrun2019 take? It's the "default install
   everyone needs" so its UX matters.
3. C5 — does the failure surfacing feel honest about why? winetricks
   error messages can be cryptic; we just show stderr tail.
4. C7 — does the duplicate carry components correctly?
5. C10 — drag-drop from Finder + browser. Any drag source that
   doesn't work where you'd expect?
6. Any UI roughness — picker scrolling, step list cramped, log pane
   too narrow, etc.

---

# Milestone 6 — 32-bit fix + per-game compat config + Gaming Essentials

Re-run xcodegen first:

```bash
cd "/Users/rubensandher/Documents/windows to mac convertor"
xcodegen generate
open Carafe.xcodeproj
```

New files this milestone:

- `Carafe/Core/Runtime/CompatibilityConfig.swift`
- `Carafe/Library/CompatConfigSheet.swift`

Updated files of note: PEValidator.swift (architecture detection),
Bottle.swift (`compatDefaults` field, backward-compat optional in
metadata), Game.swift (`compatOverrides` field, optional),
RunSession.swift (now takes a `ResolvedConfig`), ComponentsSheet.swift
(Gaming Essentials card + Extras section + warning row for `dxvk`).

Existing bottles and library entries load unchanged — both new fields
are optional in the persisted JSON.

---

## Part 1 — 32-bit blocking

### M1. Get a 32-bit exe to test against

PuTTY ships a 32-bit Windows build alongside the 64-bit one:

```bash
mkdir -p ~/Downloads/carafe-tests
curl -L -o ~/Downloads/carafe-tests/putty32.exe \
  https://the.earth.li/~sgtatham/putty/latest/w32/putty.exe
file ~/Downloads/carafe-tests/putty32.exe
# Expect: "PE32 executable (GUI) Intel 80386, for MS Windows..."
```

(`putty.exe` from the milestone-3 tests is already x86_64; keep it
for the contrast.)

### M2. Block in Run Executable flow

From a bottle's context menu → **Run Executable…** → **Choose…** →
pick `putty32.exe`.

**Expected:**
- The form's inline error reads:
  "putty32.exe is 32-bit (x86). Game Porting Toolkit only supports
  64-bit (x86_64) apps."
- The Executable row stays at "No file selected" — bad picks are
  rejected up front.

Pick `putty.exe` (the 64-bit one) instead — accepted, no error.

### M3. Block in Add Game flow

From the library → **Add Game** → **Choose…** → `putty32.exe`.

**Expected:**
- Same inline error as M2, but in the GameFormSheet.
- The Executable row stays blank.

Pick `putty.exe` (64-bit) — accepted.

### M4. Architecture badge

With `putty.exe` (64-bit) selected in the Add / Edit Game form:

**Expected:**
- Below the executable row, a green "✓ 64-bit (x86_64)" label.

Pick `putty32.exe` (you can navigate around the rejection by editing
the path manually — or just inspect after picking a real 32-bit
binary if you have one Carafe shouldn't block… actually no, Carafe
blocks all 32-bit picks now, so this label only shows for valid 64-bit).

### M5. Catch a 32-bit at launch time (defence-in-depth)

The above blocks at pick time. What if a 64-bit exe gets renamed /
overwritten with a 32-bit one between adding and launching?

```bash
# Add a 64-bit exe first (M3 already covered this).
# Then sabotage:
cp ~/Downloads/carafe-tests/putty32.exe \
   "$(grep -A1 '"exePath"' ~/Library/Application\ Support/Carafe/library.json \
      | grep '"path"' | head -1 | sed 's/.*"path" : "\([^"]*\)".*/\1/')"
```

(Or just rename `putty.exe` → `putty.exe.bak`, copy the 32-bit one in
its place.)

Click the tile to launch.

**Expected:**
- The LaunchGameSheet shows the RunningSessionView in a red "Failed"
  state.
- Status reads: "is a 32-bit (x86) executable. Apple's Game Porting
  Toolkit only supports 64-bit (x86_64) apps — this won't run."
- Followed by: "Look for a 64-bit build of the game or app; many
  titles ship both."

This is the friendly version of the previously cryptic
ShellExecuteEx error.

---

## Part 2 / 3 — per-game compatibility config

### M6. Open the editor

Right-click any game tile → **Compatibility…**.

**Expected sheet:**
- Title "Compatibility — <game name>"
- Sub-line "Inherits from bottle: <bottle name>"
- Four sections in cards:
  1. **Graphics** — Backend, Metal HUD, Retina
  2. **Compatibility** — Windows version, Sync primitive
  3. **Advanced** — Launch arguments, DLL overrides
  4. **Environment** — Environment variables
- Footer: Reset all to inherit (destructive), Cancel, Save

Every setting initially reads "Inheriting from bottle: <value>"
because a fresh game has no overrides.

### M7. Override / Inherit dance

In the **Graphics** section, click **Override** on Backend.

**Expected:**
- The inherited text disappears, replaced by a Picker showing the
  current value.
- Below the Picker: "Inherit from bottle (D3DMetal (recommended))"
  as a small button (the ↺ Inherit affordance).

Change the Picker to **DXVK (advanced)**.

**Expected:**
- A yellow inline warning appears: "Install the `dxvk` winetricks
  verb in this bottle first, otherwise DXVK has nothing to load."
- The settings summary description below the Picker updates.

Click **Inherit from bottle (D3DMetal (recommended))**.

**Expected:**
- The override is removed; row goes back to the "Inheriting from
  bottle: D3DMetal (recommended)" state.
- The summary / warning disappear.

### M8. Toggle inheritance (Metal HUD)

In Graphics, the Metal HUD row shows a Toggle.

Flip it to On.

**Expected:**
- The "Inheriting from bottle: Off" line is replaced by the small
  "Inherit from bottle (Off)" button.

Click that small button.

**Expected:**
- Override removed; the row reverts to the inherit state with the
  bottle's value shown.

### M9. Windows version override

In Compatibility, click **Override** on Windows version. Set to
**Windows 7**.

Save the sheet.

Launch the game. Watch the log pane.

**Expected:**
- Early log shows: `Setting Windows version to Windows 7…`
- Then the wine reg-add output.
- Then the actual launch.

(Adds ~1–3 seconds to launch on warm wineserver. Documented overhead.)

Confirm from Terminal during the run:
```bash
WINEPREFIX=~/Library/Application\ Support/Carafe/Bottles/<bottle-uuid> \
  /opt/homebrew/bin/wine64 reg query 'HKCU\Software\Wine' /v Version
# Expect: Version  REG_SZ  win7
```

### M10. DLL overrides editor

Open Compatibility → Advanced. Tick **Override bottle's** next to
DLL overrides.

**Expected:**
- A small list editor appears with an Add button.
- Click Add → a blank `dll = mode` row appears.

Type `d3d11` in the key field and `n` in the value field. Save.

Re-open Compatibility, confirm the row persisted. Verify on disk:

```bash
python3 -c "
import json
with open('$HOME/Library/Application Support/Carafe/library.json') as f:
    print(json.dumps(json.load(f), indent=2))
" | grep -A5 compatOverrides
```

Should contain a `dllOverrides: {"d3d11": "n"}` block under the
game's `compatOverrides`.

### M11. Custom env vars

Same dance in the Environment section. Add `DXVK_HUD = fps`. Save.

Launch the game. In the log, expand "Resolved environment" (the
LaunchGameSheet doesn't display this currently — but you can verify
it propagated by:

```bash
# While the game is running:
ps eww | grep wine64 | grep DXVK_HUD
```

Should show `DXVK_HUD=fps` in the env strings on the wine process.

### M12. Reset all to inherit

In the Compat sheet, click **Reset all to inherit**.

**Expected:**
- Every section reverts to its inherit state in one go.
- Save → `compatOverrides` is removed entirely from the game's
  library.json entry (we persist nil when `isAllInherit` is true,
  keeping the file tidy).

Verify:
```bash
grep -A2 compatOverrides ~/Library/Application\ Support/Carafe/library.json
# Expect: no match (key removed)
```

### M13. Bottle defaults flow through to a fresh game

Add a new game in the same bottle. Open its Compatibility sheet.

**Expected:**
- Every row shows "Inheriting from bottle: <bottle's default>".
- No overrides set.

This confirms the layering: bottle's `compatDefaults` is what every
new game sees until it overrides.

---

## Part 4 — Gaming Essentials + warnings

### M14. Gaming Essentials card

Open Install Components on any bottle (Bottles tab → right-click →
Install Components…).

**Expected:**
- At the top of the picker view, before the categories, a gradient
  card titled **"Gaming Essentials"** with a sparkles icon.
- Three pill labels inside the card: `vcrun2019`, `d3dcompiler_47`,
  `corefonts`. Each shows ✓ if already installed in this bottle.
- A prominent **Install Gaming Essentials** button on the right.
- Beneath the card, a header **"Extras"** with sub-text "Only install
  if a specific game needs it. Installing speculatively slows things
  down and can cause conflicts."

### M15. One-click install

On a fresh bottle (none of the three essentials installed yet), click
**Install Gaming Essentials**.

**Expected:**
- Picker phase ends immediately; installing phase begins.
- The step list shows the three verbs in order.
- They install sequentially (~5 minutes total on first install).

When done, click Close. Re-open Components.

**Expected:**
- The card's three pills all show ✓.
- The button label changes to **Reinstall Essentials**.

### M16. dxvk warning is loud

Scroll to **DirectX shims** in the picker.

**Expected:**
- The `dxvk (DXVK (prefix-wide))` row has an orange "Caution"
  capsule next to its name.
- Below the row's summary, an orange triangle warning line:
  "May conflict with GPTK's D3DMetal default. Only install if a
  specific game needs DXVK — and then enable it on that game's
  Compatibility sheet."

No other rows have this warning — only `dxvk`.

### M17. Filter behaviour with Essentials card

In the picker, type "vcrun" in the filter.

**Expected:**
- The Gaming Essentials card and Extras header **disappear** (we
  only show them when the filter is empty — the bundle UI is for
  fresh browsing, not search).
- Only Visual C++ rows remain in the categories.

Clear the filter → card returns.

---

## What to report back

1. **M2/M3/M5** — does the 32-bit message land as a clear friendly
   error (form-inline OR launch-failed surface), not the cryptic
   ShellExecuteEx?
2. **M9** — Windows version override actually takes effect (the
   `wine reg query` step confirms it)? How much does the per-launch
   `setWindowsVersion` slow things down on your machine?
3. **M10/M11** — DLL overrides + custom env round-trip through
   library.json cleanly?
4. **M12** — does "Reset all to inherit" actually remove the
   `compatOverrides` key (not just blank it out)?
5. **M15** — Gaming Essentials button vs picking the three verbs
   manually — feels right?
6. **M16** — dxvk warning visible enough? Want it scarier?
7. Anything overwhelming in the Compat sheet — too many controls per
   section, unclear inheritance affordance, etc.

---

# Milestone 7 — Steam Integration

Re-run xcodegen first:

```bash
cd "/Users/rubensandher/Documents/windows to mac convertor"
xcodegen generate
open Carafe.xcodeproj
```

New files this milestone:

- `Carafe/Core/Steam/SteamVDFParser.swift`
- `Carafe/Core/Steam/SteamLibraryScanner.swift`
- `Carafe/Core/Steam/SteamInstaller.swift`
- `Carafe/Library/InstallSteamSheet.swift`
- `Carafe/Library/AddSteamGameSheet.swift`

Plus `Game.steamAppID` (optional, backward-compat) and a new toolbar
Menu in the Library view.

## S0. Prerequisites

You need:
- A bottle with the milestone-6 known-good defaults (Windows 10,
  MSYNC, D3DMetal). New bottles already get this.
- A Steam account.
- Around 5–10 GB free disk space (Steam ~500 MB + the smallest game
  you'll install).

For the "small free game to test with" question: I recommend
**Half-Life** if you own it (3 GB, runs trivially under wine) — or
any small single-player game in your library. Avoid anything with
EAC/Vanguard/Battleye on the first pass. **Cave Story+** is also
extremely bulletproof if you own it.

## S1. Open the Steam menu

In the Library tab, look at the toolbar.

**Expected:**
- A new **Steam** menu (gamecontroller icon) sits next to **Add Game**.
- Opening it shows two items:
  - **Add Steam Game…** (disabled, because no bottle has Steam yet)
  - **Install Steam in Bottle…** (enabled if you have any bottle)
- Below them, if you have bottles but none with Steam, a caption:
  "No bottle has Steam yet — start with Install Steam."

Click **Install Steam in Bottle…**.

## S2. The Install Steam sheet

**Expected:**
- Title "Install Steam".
- Sub-line "Pick a bottle to install Steam's Windows client into."
- **What this does** card with three bullets.
- **Bottle** picker showing your existing bottles.
- **Plan** card listing the four steps with the right "skip / new"
  notes:
  - Visual C++ 2022 runtime — `~25 MB, ~3 min` (or "already installed
    — will skip" if you ran the Gaming Essentials in M5)
  - Download SteamSetup.exe — `~3 MB` (or "cached — will skip")
  - Run installer (silent) — `~30 s`
  - Verify Steam.exe — `<1 s`

Pick a fresh bottle. Click **Install Steam**.

## S3. Run the install pipeline

**Expected:**
- Sheet flips into the running view.
- Left pane: 4-step list. The current step shows a spinner; completed
  ones turn green; failed ones turn red.
- Right pane: streaming log.

The expected timing on a clean bottle:
- vcrun2022: ~3 minutes (real winetricks install).
- Download: ~1–10 seconds depending on network.
- Run installer: ~20–40 seconds (silent NSIS install).
- Verify: instant.

If you've installed Gaming Essentials earlier in this bottle, the
vcrun2022 step is "skipped" with a gray arrow icon. If the installer
is already cached from a previous run, Download is similarly skipped.

Total time on a warm machine: ~30 seconds.
Total time on a fresh bottle: ~4–5 minutes.

**Verify on disk:**

```bash
ls "$HOME/Library/Application Support/Carafe/Bottles/<bottle-uuid>/drive_c/Program Files (x86)/Steam/Steam.exe"
# Expect: file exists, ~4 MB

ls "$HOME/Library/Application Support/Carafe/Downloads/SteamSetup.exe"
# Expect: file exists, ~3 MB (cached for reuse)

# Bottle metadata should now list vcrun2022 as installed:
grep -A1 installedComponents \
  "$HOME/Library/Application Support/Carafe/Bottles/<bottle-uuid>/metadata.json"
```

## S4. Launch Steam to sign in

In the install sheet, after success, click **Launch Steam to sign in**.

**Expected:**
- Log gets a "Launched Steam GUI inside the bottle…" line.
- Within ~30 seconds, the Steam client window appears (sign-in
  prompt, or the main library if already signed in).

⚠️ **First-launch Steam updates take 5–15 minutes.** Steam will
download the actual ~500 MB client over its tiny installer. You'll
see a "Updating Steam" progress bar inside Steam itself. Be patient.

After Steam finishes updating:
1. Sign in.
2. Install at least one small game from your library.
3. Wait for the game to finish downloading inside Steam.

Close the Install Steam sheet (Steam keeps running).

## S5. Add Steam Game sheet — discovery

In the Library toolbar → **Steam** menu → **Add Steam Game…** is now
enabled. Click it.

**Expected:**
- Title "Add Steam Games", sub-line "Pick a bottle, choose games
  to add to your library."
- Bottle picker pre-selected to your Steam bottle.
- A scan kicks off automatically — within ~1 second, the list
  populates with every game you've installed in this bottle's Steam.
- Each row shows: name, `(appid)`, size on disk, install directory.

If no games appear:
- Make sure you actually finished installing at least one game in S4.
- Make sure you closed and reopened the sheet, or click **Rescan**.

**Verify the scan against Steam's own data:**

```bash
ls "$HOME/Library/Application Support/Carafe/Bottles/<bottle-uuid>/drive_c/Program Files (x86)/Steam/steamapps/"
# Expect: appmanifest_<appid>.acf files matching what the UI shows
```

## S6. Bulk-add games

Tick a couple of games (or all). The footer count updates.

Click **Add N games**.

**Expected:**
- Sheet dismisses.
- Each picked game appears as a tile in the library grid.
- Each tile carries a small **blue Steam badge** (gamecontroller
  icon) in the bottom-right corner of its cover.
- The placeholder cover is the same as any other game (initials on a
  colored gradient) until you set cover art.

**Verify in library.json:**

```bash
python3 -c "
import json
with open('$HOME/Library/Application Support/Carafe/library.json') as f:
    data = json.load(f)
for g in data['games']:
    if g.get('steamAppID'):
        print(f\"{g['name']:30s}  appid={g['steamAppID']}  args={g['arguments']}\")
"
```

Each Steam game should have:
- `steamAppID` set to the AppID
- `arguments` = `["-applaunch", "<appid>", "-no-cef-sandbox"]`
- `exePath.kind = "insidePrefix"`
- `exePath.path` ending in `Steam.exe`

## S7. Launch a Steam game from the tile

Click any Steam-badged tile.

**Expected:**
- LaunchGameSheet opens.
- Log starts with the usual Carafe info lines.
- Steam.exe launches (it's the actual executable Carafe runs).
- Steam catches the `-applaunch <appid>` and starts that game.
- After 10–30 seconds, the game window appears.

⚠️ Notes for what's *normal*:
- Steam's overlay still works (Shift+Tab inside the game).
- Achievements still register (they're handled by Steam, not the
  game).
- If you Stop the tile in Carafe, the entire Steam process tree dies
  — including any other game launched through that Steam.
- Carafe's play-time counter measures the lifetime of `Steam.exe`,
  not the actual game. So if you exit the game but leave Steam open,
  the counter keeps running. Documented; not a v1 priority.

## S8. Dedupe — already-added games

Re-open Add Steam Game. The games you added in S6 should be **hidden
from the list** (we dedupe by bottle + appid).

If you've added every installed Steam game already:

**Expected:**
- An empty-state message: "Every game installed in this bottle's
  Steam is already in your Carafe library. Install more games in
  Steam, then click Rescan."

## S9. Rescan after installing more

Inside Steam (the running window from S4), install another game.
Wait for it to finish downloading.

Back in Carafe's Add Steam Game sheet, click **Rescan**.

**Expected:**
- The list refreshes with the new game added.

## S10. Filter

In Add Steam Game, type part of a game name (or appid) into the
filter field.

**Expected:**
- The list narrows to matching rows.
- Clear button (×) appears in the filter and clears on click.

## S11. Cover art for Steam games

Right-click a Steam-badged tile → **Edit…** → **Search SteamGridDB…**.

**Expected:**
- The picker pre-fills the search with the game's name.
- Cover art comes back as usual — the SteamGridDB integration
  doesn't care that this is a Steam-launched game.

(Direct appid-based cover lookup is a future polish; for v1 we
just search by name.)

## S12. Empty state — no Steam bottles

Open Add Steam Game from a state where no bottle has Steam installed.

**Expected:**
- Empty state with a gamecontroller icon, the heading "No Steam-
  bearing bottles found", a paragraph of guidance, and an **Install
  Steam in a bottle…** button that opens InstallSteamSheet.

## S13. The Elden Ring / EAC escape hatch

For Elden Ring specifically — Carafe blocks EAC games at the kernel
level, but Elden Ring ships with both EAC and non-EAC executables in
its install directory:

- `start_protected_game.exe` — EAC-protected (won't work)
- `eldenring.exe` — direct, no EAC (works for single-player)

To play Elden Ring offline through Carafe:

1. Install Elden Ring through Steam in your Steam bottle.
2. Add it via Add Steam Game (steamAppID = 1245620).
3. Right-click the tile → **Edit…**.
4. Change the **Executable** picker to point directly at:
   `<bottle>/drive_c/Program Files (x86)/Steam/steamapps/common/ELDEN RING/Game/eldenring.exe`
5. Clear **Launch arguments** (remove the `-applaunch` Steam stuff).
6. Save.

The game now launches directly, bypassing both Steam's launcher and
EAC. You lose Steam overlay and online play; you keep offline
single-player.

⚠️ This is community-known knowledge — Carafe doesn't have a
dedicated UI for it in v1.

## What to report back

1. **S3** — does the four-step pipeline run cleanly? Anything wrong
   with the skip-states (vcrun2022 / cached installer)?
2. **S4** — does the post-install **Launch Steam** button actually
   pop the Steam GUI? How long does the first-launch Steam update
   take on your network?
3. **S5/S6** — does the discovery list match what Steam shows
   inside its own client?
4. **S7** — does Steam catch the `-applaunch <appid>` cleanly, or
   does the game ever get stuck behind a "Steam is starting" splash?
5. **S8/S9** — does the dedupe + rescan flow feel right?
6. Anything in the install pipeline that's slow / unclear / scary?
7. (If you tried it) **S13** — Elden Ring direct exe flow workable?

---

# Milestone 7.5 — Steam webhelper crash hotfix

Pure code changes — no new files, no xcodegen needed. Just build & run.

## Why this hotfix exists

GPTK ships **Wine 7.7** (from 2023). Modern Steam's CEF/Chromium-
based UI components (`steamwebhelper.exe`, React login) need Wine 8+
to render reliably. On Wine 7.7 you get the "steamwebhelper is not
responding" dialog within a minute or two of launch. Steam's own
"Restart with Browser Sandboxing disabled" recovery doesn't stick.

Carafe's mitigation: force Steam into **legacy WinAPI UI mode** by
renaming `steamwebhelper.exe` so Steam can't find it. The legacy UI
works fine on Wine 7.7. Trade-offs:
- ❌ no embedded store browser (clicking store links opens your Mac
  browser, which is fine)
- ❌ no Chromium-based friends panel
- ❌ no React login screen (you'll see the older login dialog)
- ✅ Steam stays alive
- ✅ games launch
- ✅ Library, downloads, settings, overlay all work

The proper long-term fix is a newer wine — see "Where this is going"
below.

## H1. Re-run Install Steam to apply the fix

Open Library toolbar → Steam menu → **Install Steam in Bottle…**.
Pick the bottle that already has Steam (the picker shows "Steam
already installed" — that's fine, the pipeline is idempotent).

**Expected (Plan card):**
- VC++ runtime → "vcrun2019 already installed — will skip" (if you
  ran Gaming Essentials) OR "vcrun2022 already installed — will
  skip" (if you ran Steam install first).
- Download → "cached — will skip" (`SteamSetup.exe` in your
  `~/Library/Application Support/Carafe/Downloads/`).
- Run installer → "~30 s" (overwrites the existing install — Steam's
  installer handles this gracefully).
- Verify → "<1 s".
- **Disable steamwebhelper (legacy UI) → "Wine-7.7 workaround (file
  rename)"** — this is new.

Click **Install Steam**.

**Expected during the run:**
- vcrun runtime + Download skip immediately (gray arrow icons).
- Run installer streams the same wine output as before.
- Verify → green check.
- **Disable steamwebhelper** → green check, log line:
  ```
  Renamed steamwebhelper.exe → steamwebhelper.exe.disabled-by-carafe at bin/cef/cef.win7x64/.
  Steam will fall back to the legacy WinAPI UI. Note: Steam's
  self-update will restore this file; re-run the installer afterward
  if Steam starts crashing again.
  ```

**Verify on disk:**

```bash
ls "$HOME/Library/Application Support/Carafe/Bottles/<bottle-uuid>/drive_c/Program Files (x86)/Steam/bin/cef/cef.win7x64/"
# Expect:
#   steamwebhelper.exe.disabled-by-carafe    (the renamed file)
# Expect NO:
#   steamwebhelper.exe                        (the original)
```

## H2. Launch Steam

Click **Launch Steam to sign in** in the install sheet.

**Expected:**
- A Steam window appears (older-looking UI; no shiny Chromium gloss).
- Sign in works.
- ⚠️ Steam will still try to auto-update on first launch. **This is
  the dangerous moment** — see H4 below.
- Once signed in, Steam's main window stays stable for as long as
  you keep it open. No "steamwebhelper not responding" dialog.

If you DO still get the crash dialog:
- Verify the rename actually happened (see H1's `ls` step).
- Check the launch flags. Confirm with:
  ```bash
  ps eww | grep wine64 | grep Steam.exe
  # Expect args to include:
  #   -no-cef-sandbox -noreactlogin -nofriendsui -skipinitialbootstrap
  ```
- Check env. The same `ps eww` line should contain
  `WEBKIT_DISABLE_COMPOSITING_MODE=1` and `STEAM_DISABLE_BROWSER=1`.

## H3. Verify the workaround in a Steam-launched game

Add a Steam game (Add Steam Game flow from milestone 7), click its
tile. Game should launch through Steam exactly as before — the
webhelper workaround only affects the Steam *client* UI, not the
games themselves.

## H4. Steam auto-update restores steamwebhelper.exe

⚠️ **This is the part the user needs to know about.** Steam runs a
self-update on every launch. When the update runs, **it restores
`steamwebhelper.exe`** because Valve doesn't know we wanted it
disabled. Symptoms after an update:
- Open Steam → "steamwebhelper is not responding" dialog returns.
- The renamed `.disabled-by-carafe` file still sits in the CEF
  directory, but it's no longer the only file.

**Fix:** re-run **Install Steam in Bottle…** on that bottle. The
pipeline is idempotent and the Disable step takes <100 ms. New log
output:

```
steamwebhelper.exe already renamed at bin/cef/cef.win7x64/steamwebhelper.exe.disabled-by-carafe.
```
…if Steam hadn't run yet. Or, if Steam *did* update and restore:

```
Renamed steamwebhelper.exe → steamwebhelper.exe.disabled-by-carafe at bin/cef/cef.win7x64/.
```

A future Carafe milestone (see below) can run this rename
automatically on every Steam launch — punt for now.

## H5. Sanity-check the launch error alert

Move Steam.exe aside to simulate the dealloc/missing-exe path:

```bash
mv "$HOME/Library/Application Support/Carafe/Bottles/<bottle-uuid>/drive_c/Program Files (x86)/Steam/Steam.exe" /tmp/steam.exe.bak
```

Click **Launch Steam to sign in**.

**Expected:**
- An **alert** appears (not just a log line!) with the message:
  "Couldn't launch Steam — Steam.exe is no longer at … Re-run the
  installer."

Restore:

```bash
mv /tmp/steam.exe.bak "$HOME/Library/Application Support/Carafe/Bottles/<bottle-uuid>/drive_c/Program Files (x86)/Steam/Steam.exe"
```

## Where this is going

Apple's GPTK is stuck at Wine 7.7 (Apple hasn't updated it since
2023 in the Gcenx cask we install). Current Steam, CrossOver 26, and
Sikarugir have all moved to Wine 8.0.1 / Wine 11.0. The proper fix
is a newer wine.

**Realistic next milestone (when this hotfix proves insufficient):**

Add per-bottle wine version choice. The Gcenx tap already provides
`gcenx/wine/wine-crossover` (Wine 8.0.1 / CrossOver 23.7.1 sources)
as a separate cask — free, open source, Apple Silicon native. The
shape of that milestone:

1. Add a `WineBuild` enum: `.gptk` (current default) and
   `.wineCrossover` (Wine 8.0.1).
2. Extend `BottleCompatDefaults` (or its own field) with the chosen
   build.
3. `WineRunner` resolves `wine64Path` per build (GPTK lives at
   `/opt/homebrew/bin/wine64`, wine-crossover at a different cask
   path).
4. A `BottleInstaller` step that brews `wine-crossover` on demand.
5. Update Bottle creation UI to offer "Recommended (GPTK)" vs
   "Newer wine (CrossOver 23.7.1) — better Steam compatibility".

That's a real chunk of work (~200 LOC + UI) and worth doing only if
the webhelper workaround stops being enough — which it might, when
Valve eventually drops compatibility shims for the legacy UI mode.

## What to report back

1. **H1** — did the new Disable step actually rename
   `steamwebhelper.exe`? Any log warnings?
2. **H2** — does Steam stay alive past sign-in now? Roughly how
   long before you've ruled out the original crash?
3. **H3** — Steam-launched games still work?
4. **H4** — when (not if) Steam auto-updates and breaks the
   workaround, does re-running Install Steam fix it cleanly?
5. If the workaround is still not enough: is the Wine 8.0.1 path
   worth committing to as the next milestone?

---

# Milestone 8 — Wine version switcher

**xcodegen first** (two new files):

```bash
cd "/Users/rubensandher/Documents/windows to mac convertor"
xcodegen generate
open Carafe.xcodeproj
```

New files:
- `Carafe/Core/Runtime/WineBuild.swift`
- `Carafe/Core/Runtime/WineStagingInstaller.swift`

Notable change in approach: the wine-crossover cask the user
originally suggested no longer exists in the `gcenx/wine` tap (Gcenx
removed it at some point). We instead pull **upstream WineHQ Wine
Staging 11.9** from `Gcenx/macOS_Wine_builds` GitHub releases — a
direct tar.xz download we extract into Carafe's own app-support
directory. This is *newer* than CrossOver 23.7.1 (Wine 8.0.1) and
self-contained (no brew dependency, no conflict with GPTK's
`/opt/homebrew/bin/wine64` symlinks).

The enum case is `.wineStaging` (the actual flavour) instead of
`.wineCrossover`.

## W0. Existing bottles still load

Before doing anything else: launch Carafe, switch to the Bottles
tab. Your existing bottles (created pre-switcher) should appear
unchanged — they decode with `wineBuild = nil` in the JSON, default
to `.gptk` at runtime. Confirm by checking the new Wine column
behaviour (or just by clicking a bottle and verifying nothing's
broken).

`cat ~/Library/Application\ Support/Carafe/Bottles/<uuid>/metadata.json`
should NOT have a `wineBuild` key for old bottles. When you next
write metadata (rename / install components / etc.), the field
appears as `"wineBuild": "gptk"`.

## W1. Create a Wine Staging bottle

Library tab → Steam menu → **Create new Steam-compatible bottle…**

OR

Bottles tab → New Bottle → in the Wine build picker, pick
**Steam-compatible (Wine Staging 11.9)**.

**Expected (form):**
- Wine build picker shows both options.
- Selecting `Wine Staging 11.9` flips:
  - Summary text changes to the Wine Staging description.
  - Install-status row reads "~190 MB one-time download — will
    install when you create this bottle" with a blue download icon.
  - Orange note: "Recommended for current Steam and any game that
    needs Wine 8+. Slightly slower graphics than GPTK."
  - Footer note changes to "First-time setup: ~5 minutes…"

Name the bottle `Steam (staging)`, Windows version `Windows 10`.
Click **Create**.

**Expected (operation sheet, first-ever wine-staging bottle):**

```
Stage: Installing Wine Staging 11.9 (~190 MB one-time download)…
   log: Downloading Wine Staging 11.9 from Gcenx releases (~190 MB)…
   log: Downloaded Wine Staging tarball (181.1 MB).
   log: Extracting wine-staging-11.9-osx64.tar.xz into <install dir>…
   log: Extracted Wine Staging bundle.
   log: Stripping quarantine attribute from Wine Staging.app…
   log: Quarantine attribute already clean.
   log: Wine Staging 11.9 ready at <install dir>.
Stage: Creating folder…
Stage: Initializing prefix (this may take 30 seconds or more)…
   log: Initializing prefix at <prefix path> using Wine Staging…
   log: <wineboot output for ~30-60s>
   log: Prefix initialized.
Stage: Applying Windows version…
   log: Setting Windows version to Windows 10…
Stage: Writing metadata…
Stage: Done.
```

Total time on a fresh machine: ~3-5 minutes (mostly download).

## W2. Verify on disk

```bash
ls "$HOME/Library/Application Support/Carafe/Wine/staging-11.9/Wine Staging.app/Contents/Resources/wine/bin/wine64"
# Expect: file exists, executable

cat "$HOME/Library/Application Support/Carafe/Bottles/<new-bottle-uuid>/metadata.json" \
  | python3 -m json.tool | grep -E 'wineBuild|wineVersion'
# Expect:
#   "wineBuild": "wineStaging",
#   "wineVersion": "wine-staging-11.9"
```

## W3. Re-creating a second Wine Staging bottle — cached install

Create another wine-staging bottle. The Wine Staging install step
should now be a no-op (we already extracted it):

```
log: Wine Staging 11.9 already installed at <install dir>.
```

Total time: ~30-60 s for wineboot only.

## W4. Install Steam in the new bottle

Library toolbar → Steam → **Install Steam in Bottle…**

**Expected (bottle picker behaviour):**
- The picker now shows BOTH your old GPTK bottle(s) AND the new
  Wine Staging bottle.
- The picker is sorted so Wine Staging bottles appear first.
- Bottle labels: `Steam (staging) — Wine Staging` and the
  GPTK bottle reads `<name> — GPTK ⚠ Wine 7.7`.
- Below the picker:
  - When a Wine Staging bottle is selected: green
    "Wine Staging 11.9 — recommended for Steam."
  - When a GPTK bottle is selected: orange warning explaining
    that Wine 7.7 can't bootstrap current Steam.
- Top-right of the picker: **Create new Steam-compatible bottle…**
  button (opens CreateBottleSheet with `.wineStaging` pre-selected).

Pick the Wine Staging bottle and run the Steam install pipeline.

## W5. Steam install should now bootstrap cleanly

On a Wine Staging bottle, the pipeline behaves the same way as
before, BUT step 6 (first-launch CEF bootstrap) should now
**actually succeed**:

```
Step 6: First launch (downloading CEF)
   log: Launching Steam to download CEF components (~30 MB)…
   log: Still waiting for steamwebhelper.exe to appear (15s elapsed, ~165s remaining)…
   log: steamwebhelper.exe appeared after 35s. Renaming and stopping Steam…
   log: Renamed steamwebhelper.exe → steamwebhelper.exe.disabled-by-carafe at cef/<path>
   log: First-launch CEF bootstrap complete. Steam is set up for legacy UI mode.
   ✓
```

The "appeared after Xs" log line is the *proof* that Wine Staging
fixes the bootstrap problem Wine 7.7 couldn't.

## W6. Launch Steam and sign in

Click **Launch Steam to sign in**. Steam should now actually launch
to a usable UI — same legacy-WinAPI mode as before (because we
renamed steamwebhelper.exe), but Steam doesn't crash because the
underlying wine isn't broken.

Sign in. Install a small single-player game. Verify games still
launch from Carafe tiles the same as before.

## W7. WinetricksRunner uses the right wine

Open Install Components on the new Wine Staging bottle. Install
something tiny (`d3dcompiler_47` is good — 5 MB, fast).

The log should now read:
```
→ winetricks --unattended d3dcompiler_47  [via Wine Staging]
```

(Note the `[via Wine Staging]` tag.)

Same operation on a GPTK bottle reads `[via GPTK]`. Confirms the
per-bottle wine resolution is wired through.

## W8. Mixed setup — both builds installed

You should now have:
- GPTK installed (from onboarding)
- Wine Staging installed (from W1)
- A GPTK bottle (your original one)
- A Wine Staging bottle (the new one)

Both bottle types should be usable in parallel:
- Launch a game in your GPTK bottle → uses
  `/opt/homebrew/bin/wine64`
- Launch a game in your Wine Staging bottle → uses
  `~/Library/Application Support/Carafe/Wine/staging-11.9/…/wine64`

Verify with `ps eww | grep wine64` while two games are running.

## W9. Repair a bottle defaults to GPTK

Simulate corruption on the Wine Staging bottle:

```bash
echo 'broken' > "$HOME/Library/Application Support/Carafe/Bottles/<wine-staging-uuid>/metadata.json"
```

Bottles tab → right-click corrupted entry → Repair.

**Expected:**
- Repair regenerates metadata with `wineBuild = "gptk"` (we can't
  recover which build the prefix was originally created against —
  the prefix itself contains no marker — so we default to the safe
  pre-switcher behaviour).
- This is logged loudly in the comment in `BottleManager.repair`
  but is a real limitation: a "repaired" Wine Staging bottle will
  try to launch with GPTK, fail, and need re-creation.

If this matters in practice, we can add a `wineBuild` sidecar
file inside the prefix in a future milestone.

## What to report back

1. **W1** — does the Wine Staging download actually complete? The
   tarball is 190 MB; on a typical home connection that's a couple
   minutes. Network failures should give clear errors.
2. **W5** — does step 6 (first-launch CEF bootstrap) finally succeed
   on Wine Staging? This is the milestone-defining test. The
   "appeared after Xs" timing tells us how long Steam's bootstrapper
   actually takes when wine works.
3. **W6** — does Steam stay stable past sign-in? Can you install a
   game and launch it from a Carafe tile?
4. **W7** — `[via Wine Staging]` / `[via GPTK]` tag appearing
   correctly in the winetricks log?
5. **W4 bottle picker** — does the sort + warning copy convey "use
   Wine Staging for Steam" clearly enough, or does it need to be
   louder?

When this is green, the next milestone is your call. Obvious
candidates:
- (a) Steam appid-based cover art lookup (we have appid stored;
  SteamGridDB has /grids/steam/&lt;appid&gt;)
- (b) Compatibility hints in the per-game context menu
- (c) GOG / Epic integration mirroring the Steam pattern
- (d) Per-bottle "force re-disable steamwebhelper" action that the
  user can hit after a Steam auto-update breaks the workaround.

Pick what hurts most in real use.

---

# Milestone 9 — Headless Add Steam Game by AppID

One new file (`SteamAppIDParser.swift`) — run xcodegen first:

```bash
cd "/Users/rubensandher/Documents/windows to mac convertor"
xcodegen generate
open Carafe.xcodeproj
```

## Why this exists

The Steam client UI renders black on `winemac.drv` even with the
dcomp / Metal-wrapper workarounds. Rather than keep fighting the
client's rendering, sidestep it: register games directly via their
Steam AppID. Steam still launches headlessly via `-applaunch <id>`,
downloads the game if needed, runs it. The game window itself
isn't a Chromium UI — it renders fine through `winemac.drv`.

## H1. Open Add Steam Game, switch to By App ID

Library toolbar → Steam menu → **Add Steam Game…**

**Expected:**
- A new segmented picker at the top with **Browse Installed** /
  **Add by App ID**.
- Browse Installed is the default and behaves exactly as before.

Click **Add by App ID**.

**Expected:**
- Body changes to:
  - Info blurb explaining headless launch via `-applaunch`
  - "App ID or Steam URL" text field with a long placeholder showing
    three accepted formats
  - "Name" text field
- The Filter / Rescan controls disappear from the bottle row
  (they're browse-only).
- Footer: **Cancel** + disabled **Add Game** with the hint
  "Enter an App ID or Steam URL."

## H2. Paste a raw AppID

Type or paste **1245620** into the App ID field. (Elden Ring's
canonical Steam AppID.)

**Expected:**
- A green checkmark immediately appears: "Parsed: AppID 1245620".
- The Name field is still empty (raw integer input has no URL slug
  to derive from).
- Footer changes to "Give it a name."

Type `Elden Ring` in the Name field.

**Expected:**
- Footer: "Ready to add."
- Add Game button enables.

Click **Add Game**.

**Expected:**
- Sheet dismisses.
- A new tile appears in the library with the placeholder cover
  (initials "ER") and a blue Steam badge in the bottom-right.

## H3. Paste a Steam store URL

Reopen Add Steam Game → Add by App ID.

Paste:

```
https://store.steampowered.com/app/1599340/Lost_Ark/
```

**Expected:**
- Parsed shows "AppID 1599340".
- Name auto-fills to **Lost Ark** (URL slug parsing handles the
  underscore-to-space conversion).
- Footer: "Ready to add."

Don't actually add — click Cancel.

## H4. Paste a steam:// protocol URL

Reopen, paste:

```
steam://run/440
```

**Expected:**
- Parsed shows "AppID 440" (Team Fortress 2).
- Name stays empty (protocol URLs don't carry a slug).
- Footer asks for a name.

## H5. Garbage input

Type `not an app id` into the App ID field.

**Expected:**
- Orange warning: "Couldn't extract an App ID from that input".
- Add Game button stays disabled.

## H6. Dedupe protection

Reopen Add Steam Game → Add by App ID. Paste 1245620 again (the AppID
you added in H2).

Type any name and click **Add Game**.

**Expected:**
- Red inline error: "AppID 1245620 is already in your library for
  this bottle."
- No duplicate created.

## H7. Verify the game launches

Close the sheet and click the Elden Ring tile in the library.

**Expected:**
- LaunchGameSheet opens; log shows `Steam.exe -applaunch 1245620
  -no-cef-sandbox` in the command line.
- Steam starts in the background (you may not see its window if it
  was previously hidden / black).
- After Steam catches `-applaunch`, the game itself starts
  downloading / launching.

Note: if Steam isn't signed in inside the bottle, `-applaunch` will
queue the launch waiting for sign-in. That's a Steam thing, not
something Carafe can shortcut. Sign in once manually (Steam mobile
QR via the still-broken Steam window, or any other method) and
subsequent `-applaunch` calls work without UI.

## What to report back

1. **H2 / H3** — URL parsing handles the formats you actually paste
   in practice?
2. **H7** — does Elden Ring (or any other Steam game you've added
   this way) actually launch through `-applaunch`, even when the
   Steam client window is black?
3. The dedupe (**H6**) — informative enough, or does it need more
   guidance about how to remove the existing entry?

The next milestone after this is **DXMT graphics backend** (option C
from the prior round) — adding a Mac-native DirectX 11 → Metal
translator alongside D3DMetal and DXVK for games whose Wine DX
support is borderline.

---

# Polish milestone — Settings pane

Confirms the new Settings window (Cmd+, / gear icon) and the
preferences it exposes. New code lives in `AppSettings.swift` and
`SettingsView.swift`. The macOS Settings scene is wired in
`CarafeApp.swift`.

Run order: P1 → P7. Bottle data is preserved end-to-end; the only
destructive-feeling step is P5 (migrate bottles), which is opt-in
behind a confirmation alert.

## P1. Open Settings

- Press **Cmd+,** anywhere in the app. Expected: the Settings window
  opens with a four-tab strip (General / Defaults / Storage / About)
  and the General tab is selected.
- Click the **gear icon** in the toolbar. Expected: same window
  comes forward (or opens if it was closed).
- Close the Settings window with Cmd+W. Expected: just the Settings
  window closes; the main library/bottles window stays open.

## P2. General tab — SteamGridDB key shortcut

- General → **Integrations** → click **Manage…**. Expected: the
  existing `APIKeysSheet` opens as a sheet *over* the Settings
  window (not over the main library window). The "Stored" badge
  reflects whether you set a key in a previous run.
- Save or clear the key, then close. Expected: returns to the
  Settings window cleanly; the badge state matches what you did.

## P3. General tab — Telemetry toggle

- General → **Privacy** → flip the telemetry toggle ON, then OFF.
  Expected: it's a real bistable switch with the explanation copy
  below it. The "Carafe doesn't currently send any telemetry" line
  stays visible regardless.
- Quit and relaunch Carafe. Expected: the toggle state persists.
- (No further consumer to verify yet — the toggle is wired to
  `AppSettings.telemetryEnabled` but no telemetry pipe exists. This
  is intentional; the Stability milestone gates Sentry off it.)

## P4. Defaults tab — Bottle creation pre-seed

- Settings → **Defaults** → change **Default Wine build** to
  "Wine Staging", change **Default Windows version** to "Windows
  11", change **Default graphics backend** to "DXVK (advanced)".
- Close Settings. Open the **Bottles** sidebar item. Click
  **Add bottle…**. Expected: the New Bottle sheet opens with
  Wine Staging pre-selected, Win 11 pre-selected, and the wine-
  build summary text reflects Wine Staging.
- Cancel. Re-open Settings, flip defaults back (Wine build = GPTK,
  Windows = Win 10, graphics = D3DMetal). Click **Add bottle…**
  again. Expected: now defaults to GPTK / Win 10 in the form.
- Create one fresh bottle named e.g. `Polish-defaults-test`.
  Expected: the create flow succeeds; check the resulting bottle's
  `metadata.json` (in `~/Library/Application Support/Carafe/Bottles/<UUID>/metadata.json`)
  has `compatDefaults.graphicsBackend` set to the value that was
  in Settings at create time.
- Steam flow only: from the Library toolbar's Steam menu →
  **Install Steam in Bottle…** → "Create new Steam-compatible
  bottle". Expected: Wine Staging is forced regardless of the
  Settings default (the install flow explicitly overrides). This
  is correct behavior — Steam needs Wine Staging.

## P5. Storage tab — Custom location (no migration)

- Settings → **Storage**. Expected: the current path row reads
  `…/Application Support/Carafe/Bottles` and says "Default
  location". The migrate section is NOT shown.
- Click **Choose…**. Pick a folder (e.g. `~/Desktop/Carafe-test`).
  Expected: the row now shows the new path with "Custom location";
  a **Reset to default** button appears.
- Click **Open in Finder**. Expected: Finder opens the new path
  (which Carafe just created if it didn't exist).
- Open the **Bottles** sidebar. Expected: empty — Carafe is now
  looking at the new (empty) folder. Your previous bottles are NOT
  visible. Don't panic; they're still safe at the default path.
- Click **Reset to default** in Settings. Expected: path reverts;
  bottles reappear in the sidebar.

## P6. Storage tab — Migrate existing bottles

⚠️ This step **moves** bottle folders. The data isn't deleted, but
make sure no games / Steam are running first.

- With the bottles list non-empty at the default location, set
  Settings → Storage → Choose… to a NEW path (e.g.
  `~/Desktop/Carafe-bottles-moved`). Expected: the bottles list
  goes empty (we're looking at the new path) AND the **Move
  existing bottles** section appears, saying "N bottle folder(s)
  still in the default location" with a **Move now…** button.
- Click **Move now…**. A confirmation alert appears with the
  exact source → destination paths and the bottle count.
- Confirm. Expected: spinner labelled "Moving bottles…" briefly,
  then a green "Moved N bottle(s) to …" line.
- Open **Bottles** in the sidebar. Expected: all the bottles you
  had before are now visible at the new location. Launch one
  bottle's **Open in Finder** to confirm the path moved.
- Try launching a game from one of the moved bottles. Expected: it
  launches. **If a game complains about a missing path** (rare —
  see FRAGILITY note in `AppSettings.migrateBottles`), open
  winecfg for that bottle once. Report which game.
- Reset by setting Settings → Storage back to default and either:
  (a) migrating back the same way, or (b) manually moving the
  folders in Finder and clearing the override.

## P7. Storage tab — Open data folder

- Settings → Storage → **Open Carafe data folder**. Expected:
  Finder opens `~/Library/Application Support/Carafe/`. You should
  see `Bottles/`, `Wine/` (if Wine Staging was installed),
  `CoverArt/`, `library.json`, and `logs/`.

## P8. About tab

- Settings → **About**. Expected:
  - Big wineglass icon, "Carafe" headline, "Version 0.1.0 (build 1)".
  - GitHub link is a real clickable Link (placeholder URL —
    `github.com/carafe-app/carafe`. TODO before release: replace
    with the real repo URL).
  - Acknowledgements section lists Wine, GPTK, Gcenx, Winetricks,
    SteamGridDB. Each has an arrow-link icon that opens the
    upstream URL in your browser (except GPTK which has none —
    no canonical URL to point at).
  - Troubleshooting section has **Re-run onboarding** which sets
    `appState.onboardingComplete = false` and bounces you back to
    the welcome screen. This replaces the old gear-menu debug
    item. Verify: re-run onboarding completes, returns to library,
    your bottles and games are intact.

## What to report back

1. **P1** — does Cmd+, work in your Xcode debug-run as well as a
   release-built app? (Sometimes the Settings scene needs a
   re-build to register.)
2. **P5 / P6** — the migrate flow, end to end. Did anything break
   when you ran a game from a moved bottle? Steam in particular —
   it stores absolute paths in its own configs.
3. **P8** — replace the placeholder GitHub URL with the real one
   before tagging 0.1.0. Edit `Self.githubURL` in
   `SettingsView.swift`.
4. Anything that *looks* wrong — typography, spacing, alignment.
   This pane is the user-facing front door for power features;
   it should feel native.

The next milestone after this is **Onboarding improvements**:
first-launch welcome explaining what Carafe does, quick-start
guide, and a clear "GPTK vs Wine Staging — pick one" decision aid.

---

# Release milestone A — App icon + branding

Confirms the new procedurally-generated app icon, the locked accent
colour, and the version/display-name metadata. The icon is generated
by `Tools/generate-app-icon.swift`, which is committed alongside the
PNGs — re-run that script any time the design changes; do NOT
hand-edit the PNGs in `AppIcon.appiconset/`.

Run order: A1 → A6.

## A1. Confirm Info.plist metadata

In a Terminal, against a fresh debug build:

    APP="$HOME/Library/Developer/Xcode/DerivedData/Carafe-*/Build/Products/Debug/Carafe.app"
    /usr/libexec/PlistBuddy \
      -c "Print CFBundleDisplayName" \
      -c "Print CFBundleShortVersionString" \
      -c "Print CFBundleVersion" \
      -c "Print NSAccentColorName" \
      "$APP"/Contents/Info.plist

Expected:

    Carafe
    0.1.0
    1
    AccentColor

If any of those is missing or different, the project.yml change
didn't land — re-run `xcodegen generate` and rebuild.

## A2. Dock and app-switcher

- Build + run from Xcode (Cmd-R). Expected: the dock icon shows the
  carafe silhouette on the dark-wine gradient background. No
  default-app placeholder, no Xcode hammer.
- Open Cmd-Tab. Expected: same icon, scaled smaller, still
  recognizable. Wine fill should still read as red.

## A3. Finder + Get Info

- Reveal `Carafe.app` in Finder (right-click in Xcode → Show in
  Finder; or use the path printed in A1).
- Switch Finder to icon view at maximum size (Cmd-J → Icon size →
  drag slider all the way right). Expected: large detailed
  rendering with the rim highlight visible on the upper-left of
  the body.
- Switch to icon size minimum (small list-view icon). Expected:
  still legible as a carafe shape with red fill — at this size
  the rim highlight is suppressed by design (script
  `drawCarafeIcon` line `if size >= 64`).
- Cmd-I (Get Info). Expected: the large preview at the top of the
  Info window uses the 512@2x rendering. No "default app" generic.

## A4. AccentColor lockdown

- Open System Settings → Appearance → Accent color → pick a non-
  blue option (e.g. **Pink**).
- Reopen Carafe (or force a redraw — switching tabs is enough).
  Expected: the app's tinted elements (toolbar gear, accent-styled
  buttons, focus rings) STAY blue. The system pink does NOT bleed
  through.
- Reset System Settings back to "Multicolor" or your preferred
  accent.
- WHY this matters: locking the accent prevents the brand colour
  from shifting under the user. SwiftUI's `.tint` reads the
  asset-catalog AccentColor when
  `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME` is set
  (project.yml). Without that build setting, `.tint` falls back to
  the user's system accent — which is what was happening prior to
  this milestone.

## A5. Accent colour consistency across the UI

Visit each surface and confirm the same blue is used for primary
chrome. The "right" blue is #0A84FF / display-p3 (0.039, 0.518,
1.000) — matches macOS system blue under the default Multicolor
accent.

- Onboarding → welcome icon
- Library → grid empty-state icon
- Library → game tile selected outline + selected-checkmark
  badge (multiselect mode)
- Bottles → empty-state icon
- Sheet headers: New Bottle, Launch Game, Install Components,
  Compat Config, Add Steam Game, Install Steam
- Settings → header icons (wineglass + manage-API-key + folder
  icon in Storage tab)
- Settings → About → version block icon

If any surface is using a noticeably different blue, that's a
hard-coded colour bug, not a tint inheritance issue. Grep the
codebase for `Color(red:` / `NSColor(red:` to find culprits.

## A6. Icon regeneration

This step is only needed if you want to iterate on the design.

    swift Tools/generate-app-icon.swift

Expected:
- Ten PNG files written into
  `Carafe/Resources/Assets.xcassets/AppIcon.appiconset/`,
  ranging from 16×16 to 1024×1024.
- `Contents.json` rewritten with the new filenames.
- No other state touched.

After re-running, rebuild in Xcode (Cmd-B) and verify A2 + A3
visually. Note that the .icns inside `Carafe.app` is regenerated
by Xcode's asset-catalog compiler at build time, NOT by the
generator script — the script only produces the source PNGs.

## What to report back

1. **A2 / A3** — does the icon look right at the dock and at the
   1024×1024 Finder preview? The design choices to revisit if not:
   colours (`CGColor(srgbRed: ...)` calls in `drawCarafeIcon`),
   proportions (the `p(x, y)` Bezier path points), and whether the
   rim highlight is too subtle / too obvious at large sizes.
2. **A4** — does the accent stay blue when you change the macOS
   system accent? If it doesn't,
   `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME` didn't take
   effect — sometimes a full clean (Xcode → Product → Clean Build
   Folder, Shift-Cmd-K) is needed for the asset catalog compiler
   to honour the new binding.
3. **A5** — any UI surface where the blue looks "off"? Photo
   evidence helps; specific surface names are enough for me to
   find the source.

After this comes **Release milestone B**: Sparkle 2 auto-update,
code signing + Gatekeeper bypass instructions, .dmg with custom
background, GitHub Actions CI on tag push, README.md with
screenshots and download link.

---

# A-bis. Icon fix (asset-catalog bypass)

This sub-milestone fixes the "dock shows default icon" bug that
shipped with A. Root cause: Xcode's `actool` was silently
dedup-merging byte-identical PNGs in the AppIcon.appiconset and
dropping six of the ten size slots from the generated icns. The
fix bypasses the asset catalog for the icon entirely:

* `Tools/generate-app-icon.swift` now renders PNGs into a working
  directory at `Tools/build/AppIcon.iconset/`, then runs `iconutil
  -c icns` to pack a full-fat 1.18 MB `Carafe/Resources/AppIcon.icns`
  with all 10 size slots present.
* `project.yml` switched from `GENERATE_INFOPLIST_FILE: YES` to a
  hand-rolled `info:` block — needed because Xcode's
  `INFOPLIST_KEY_*` auto-inject doesn't recognise `CFBundleIconFile`.
  The new Info.plist is committed at `Carafe/App/Info.plist` and
  regenerated by xcodegen on every `xcodegen generate`.
* `Carafe/Resources/Assets.xcassets/AppIcon.appiconset/` was
  deleted. AccentColor still lives in the catalog.

## Verify the fix

    APP="$HOME/Library/Developer/Xcode/DerivedData/Carafe-*/Build/Products/Debug/Carafe.app"
    
    # 1. Bundle has a fat icns (~1.18 MB, not ~68 KB)
    ls -la "$APP"/Contents/Resources/AppIcon.icns
    
    # 2. icns contains ALL 10 slots, not just 4
    rm -rf /tmp/check.iconset
    iconutil -c iconset "$APP"/Contents/Resources/AppIcon.icns -o /tmp/check.iconset
    ls /tmp/check.iconset/
    # Expect: 10 files, 16/16@2x/32/32@2x/128/128@2x/256/256@2x/512/512@2x

    # 3. Info.plist wires CFBundleIconFile → AppIcon
    /usr/libexec/PlistBuddy -c "Print CFBundleIconFile" "$APP"/Contents/Info.plist
    # Expect: AppIcon

## If the dock STILL shows the default icon

This is almost certainly a Launch Services cache problem. macOS
caches icons keyed by bundle ID — once it has decided your app's
icon is "the default placeholder", it sometimes sticks with that
even after the .app is rebuilt with a real icon. Clearing the
caches fixes it:

    # 1. Force-rebuild Launch Services' icon database
    /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister \
        -kill -r -domain local -domain system -domain user
    
    # 2. Re-register the freshly built app explicitly
    /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister \
        -f "$HOME/Library/Developer/Xcode/DerivedData/Carafe-*/Build/Products/Debug/Carafe.app"
    
    # 3. Kick the Dock + Finder so they re-read the icon
    killall Dock
    killall Finder

If you've copied the .app out of DerivedData and dragged it to
`/Applications`, also run step 2 with the `/Applications/Carafe.app`
path. Finder + Dock will show the carafe immediately.

The cache-clear is a one-time thing per machine; once Launch
Services has cached the correct icon, future builds (with the icon
intact) pick it up cleanly without re-running the lsregister
commands.

---

# Release milestone B-1 — Sparkle 2 auto-update

Adds the Sparkle 2 framework via SPM, wires a "Check for Updates…"
menu item, and arms a once-per-day background check on launch. The
appcast URL points at the GitHub Releases of `carafe-app/carafe`
(placeholder — replace with the real repo slug in `project.yml`
before the first tagged release).

What's deliberately NOT done in B-1 (it's done as part of the
release-engineering work in B-2/B-3):

- Generating the EdDSA `SUPublicEDKey` / `SUPrivateEDKey` pair.
- Signing the appcast entries with `sign_update`.
- Producing the appcast.xml itself (that's GitHub Actions in B-3).

Until those land, Sparkle will let you *trigger* a check from the
menu, but the actual install path will fail at signature
validation. That's the correct pre-release behaviour.

## B-1.1. Menu item visible + reactive

- Build + run (Cmd-R from Xcode, or run the .app from
  `~/Library/Developer/Xcode/DerivedData/Carafe-*/Build/Products/Debug/`).
- Open the **Carafe** menu (top-left of the menu bar, the app menu).
  Expected order:
    1. About Carafe
    2. **Check for Updates…**  ← new
    3. Settings… (Cmd+,)
    4. Services
    5. Hide Carafe / Hide Others / Show All
    6. Quit Carafe (Cmd+Q)
- Hover the "Check for Updates…" item. Expected: enabled (clickable).

## B-1.2. Trigger a check (pre-release expected failure)

- Click **Check for Updates…**. Expected:
    1. Sparkle's progress sheet appears briefly ("Checking for
       updates…").
    2. Sparkle attempts to fetch the appcast XML from the placeholder
       GitHub URL.
    3. Since the placeholder repo doesn't exist yet (or the appcast
       isn't built yet), Sparkle shows an alert: **"Update Error!"**
       — could be 404 ("Couldn't find appcast feed") or DNS / network
       depending on the state.
    4. Menu item re-enables.
- Verify the menu item re-enables (`canCheckForUpdates` flips back
  to true) after the failure dialog is dismissed.
- This whole flow exercises the wrapper code in `Updater.swift`. The
  *content* of the error is meaningful only after the real appcast
  exists.

## B-1.3. Verify Info.plist + framework embedding

```
APP="$HOME/Library/Developer/Xcode/DerivedData/Carafe-*/Build/Products/Debug/Carafe.app"

# Sparkle.framework + XPC services must exist:
ls $APP/Contents/Frameworks/Sparkle.framework/Sparkle
ls $APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/

# Expected: Downloader.xpc and Installer.xpc

/usr/libexec/PlistBuddy -c "Print SUFeedURL" \
                       -c "Print SUEnableAutomaticChecks" \
                       -c "Print SUScheduledCheckInterval" \
                       -c "Print SUAutomaticallyUpdate" \
                       $APP/Contents/Info.plist

# Expected:
#   https://github.com/carafe-app/carafe/releases/latest/download/appcast.xml
#   true
#   86400
#   false
```

`SUPublicEDKey` must be **absent** at this stage (PlistBuddy errors
"Entry, "SUPublicEDKey", Does Not Exist"). Once it's filled in
during B-2 release prep, installs will be permitted.

## B-1.4. Sparkle release engineering — one-time setup

This is the procedure for the *first* tagged release. You only do it
once per project. After this, every release follows B-1.5.

### Generate the EdDSA key pair

Sparkle ships a `generate_keys` tool inside its SPM package. Locate
it after a fresh build:

```
find ~/Library/Developer/Xcode/DerivedData/Carafe-*/SourcePackages/checkouts/Sparkle/bin \
  -name 'generate_keys'
```

Run it:

```
./generate_keys
```

This creates the private key in the **macOS Keychain** (account:
`ed25519` under `https://sparkle-project.org`) and prints the
public key to stdout — copy the base64 string.

⚠️ **The private key never leaves your Keychain.** If you lose
access to the Keychain or wipe the machine without exporting it,
you cannot sign any future updates — users on the old key will
stop receiving updates and you have to ship a new app with a new
key (which Sparkle treats as a different app). Export the key
NOW and store it somewhere safe (1Password, a printed paper backup
in a drawer, whatever you trust):

```
./generate_keys -x ~/Desktop/carafe-sparkle-private.pem
# Move that file to your password manager, then shred the local copy.
```

For GitHub Actions you'll need the private key as a base64 string
to inject as a secret. Export it once for that purpose:

```
./generate_keys -p           # prints public key
./generate_keys -x -          # prints private key to stdout
```

Add to your repo's GitHub Secrets:
- `SPARKLE_ED_PRIVATE_KEY` — base64 of the private key

### Embed the public key

Add to `project.yml` under `targets.Carafe.info.properties`:

```yaml
SUPublicEDKey: <the base64 string from generate_keys>
```

Then `xcodegen generate` + rebuild. Verify:

```
/usr/libexec/PlistBuddy -c "Print SUPublicEDKey" \
  $APP/Contents/Info.plist
```

### Replace the placeholder repo URL

In `project.yml`, change the `SUFeedURL` from the
`carafe-app/carafe` placeholder to the real repo slug. Also update:
- The About tab GitHub link in `Carafe/App/SettingsView.swift`
  (`AboutTab.githubURL`).
- The README.md once it exists (milestone B-5).

## B-1.5. Per-release signing checklist

For every tagged release (`git tag v0.1.0 && git push --tags`),
GitHub Actions (B-3) does this automatically — but if you're
shipping a manual release for emergency reasons, the procedure is:

1. Build a release .dmg (milestone B-2 procedure).
2. Sign the .dmg with Sparkle's `sign_update`:
   ```
   ./sign_update Carafe-0.1.0.dmg
   ```
   This prints a `sparkle:edSignature="..."` attribute.
3. Build the appcast.xml entry for this release including that
   `sparkle:edSignature`, `sparkle:version`, `length`, `url`, etc.
4. Upload BOTH the .dmg AND the appcast.xml as release assets to
   the GitHub release.

`https://github.com/<repo>/releases/latest/download/appcast.xml`
will then serve the latest appcast, Sparkle clients will hit it
on schedule, see the new version, verify the signature against
the `SUPublicEDKey` baked into the user's installed app, and
prompt the user to install.

## What to report back

1. **B-1.1** — does "Check for Updates…" appear in the right place
   and look native?
2. **B-1.2** — does the failure alert close cleanly and re-enable
   the menu item? Anything weird about the wrapper's
   `canCheckForUpdates` state?
3. Have you generated the EdDSA keys yet? If yes, what's the GitHub
   repo slug? I'll patch the placeholder in B-2.

After this comes **milestone B-2**: build a proper release `.dmg`
with a dark gradient background, the Carafe logo, an Applications
shortcut, and the volume name "Carafe 0.1.0".

---

# Release milestone B-2 — DMG packaging

`Tools/build-dmg.sh` produces a release-ready `Carafe-0.1.0.dmg` in
the repo root. The script:

1. Installs `create-dmg` via Homebrew if needed.
2. Regenerates `Tools/build/dmg-background.png` (1320×800 procedural
   background — gradient + Carafe logo + "Carafe 0.1.0" wordmark).
3. Builds the app in Release **without codesigning** (xcodebuild
   with `CODE_SIGNING_ALLOWED=NO`).
4. Strips `com.apple.provenance` xattrs from the built bundle.
5. Codesigns innermost-out: Sparkle's `Autoupdate`, then its
   `XPCServices/*.xpc`, then `Sparkle.framework`, then the main app
   (with our entitlements).
6. Runs `create-dmg` with the canonical layout (660×400 window,
   128 px icons, volume name "Carafe 0.1.0").

The deferred-codesign workaround is necessary because macOS 14+ /
26.x tags every file the toolchain writes with `com.apple.provenance`
and codesign refuses to operate on tagged files. The
`xattr -cr → codesign` two-step is the standard workaround.

## B-2.1. Build the DMG

From repo root:

```
./Tools/build-dmg.sh
```

Expected: ~3–5 minutes (slower on first run when Homebrew installs
create-dmg). Output:

```
✓ Carafe-0.1.0.dmg
  Size: ~7 MB (varies)
```

## B-2.2. Inspect the DMG

```
hdiutil attach Carafe-0.1.0.dmg
```

Expected mount: `/Volumes/Carafe 0.1.0`. Verify:

- Volume name reads "Carafe 0.1.0" (Finder sidebar + window title).
- Window opens at 660×400 with the dark-gradient background.
- App icon on the LEFT (~ x=165), Applications shortcut on the
  RIGHT (~ x=495), both centered on y=265.
- The carafe logo + "Carafe" wordmark + "0.1.0" version sit above
  the icons in the top half of the window.

Unmount before re-running the script:

```
hdiutil detach "/Volumes/Carafe 0.1.0"
```

## B-2.3. Install + first launch (Gatekeeper bypass)

- Drag Carafe.app from the open DMG into `/Applications`.
- In Finder, navigate to `/Applications`.
- **Right-click** Carafe.app → **Open** (this is the Gatekeeper
  bypass — required because the .app is ad-hoc-signed, not
  notarized).
- macOS asks "Are you sure you want to open it?" → click **Open**.
- App launches. The carafe icon should appear in the dock (run
  `killall Dock` once if you see the placeholder — Launch Services
  cache, see A-bis).

After this first launch, double-click works normally. macOS
remembers your choice for this specific .app on this machine.

## B-2.4. Codesign verification

```
codesign -dv --verbose=4 /Applications/Carafe.app 2>&1 | head -15
```

Expected: `Signature=adhoc`, `Identifier=dev.carafe.Carafe`, and
listings for each nested signed component. No "code object is not
signed at all" or similar errors.

```
codesign --verify --deep --verbose /Applications/Carafe.app
```

Expected: `valid on disk` and `satisfies its Designated Requirement`.

## B-2.5. Regenerating the DMG background

If you want to tweak the gradient, logo size, or layout:

```
swift Tools/generate-dmg-background.swift
```

Re-run `Tools/build-dmg.sh` afterwards. The script always
regenerates the background as part of its pipeline, so iterating on
the design just means editing the Swift file and re-running.

## What to report back

1. **B-2.1** — does the build complete cleanly? On the first run on
   a fresh machine, Homebrew installing create-dmg is the slowest
   step; subsequent runs are fast.
2. **B-2.2** — does the DMG window look right? Specifically: the
   gradient + logo + wordmark layout, the icon positions, and
   whether "Carafe 0.1.0" appears as the volume name.
3. **B-2.3** — does the right-click → Open bypass actually work?
   You should only need to do it once per .app per machine.
4. Anything that looks visually off — icon spacing too tight or too
   loose, wordmark font too big/small, the gradient looking muddy
   at the bottom, etc. The geometry constants live at the top of
   `Tools/build-dmg.sh` and `Tools/generate-dmg-background.swift`.

---

# Release milestone B-3 — GitHub Actions CI + README

`.github/workflows/release.yml` fires on every `v*` tag push and
produces a GitHub Release with the .dmg + appcast.xml attached.

## B-3.1. Workflow dry-run (without tagging)

Before tagging, exercise the workflow locally with `act` (optional)
or just read through the YAML — there's no easy way to test a
release workflow without actually pushing a tag. The pieces that
are testable locally:

- `./Tools/build-dmg.sh` — covered by B-2.
- `./Tools/generate-appcast.sh 0.1.0 Carafe-0.1.0.dmg ""` — verify
  the output is valid XML. The third arg (signature) is empty;
  Sparkle will refuse to install but the document is well-formed.

```
./Tools/generate-appcast.sh 0.1.0 Carafe-0.1.0.dmg "" > /tmp/appcast.xml
xmllint --noout /tmp/appcast.xml && echo "appcast.xml parses"
```

## B-3.2. Tag a test release

When you have the GitHub repo set up, the Sparkle key generated,
and the `SPARKLE_ED_PRIVATE_KEY` secret in place:

```
git tag v0.1.0
git push --tags
```

Watch the workflow run in the **Actions** tab. Expected steps:
1. Checkout
2. Read version from tag
3. Select Xcode 15.4
4. Install xcodegen + create-dmg
5. Generate xcodeproj
6. Build .dmg
7. Resolve sign_update tool path
8. Sign DMG with Sparkle EdDSA
9. Generate appcast.xml
10. Create GitHub Release
11. Summarize

End state: a new GitHub Release at `releases/tag/v0.1.0` with
`Carafe-0.1.0.dmg` + `appcast.xml` attached, plus auto-generated
release notes from the commit history since the previous tag.

## B-3.3. End-to-end Sparkle update test

Once you've shipped v0.1.0 and v0.1.1:
1. Install v0.1.0 from the v0.1.0 GitHub Release.
2. Run it. Wait for the daily background check OR click
   Carafe → Check for Updates….
3. Expected: Sparkle reads the appcast at
   `https://github.com/<repo>/releases/latest/download/appcast.xml`,
   sees v0.1.1 is newer, verifies the EdDSA signature against the
   `SUPublicEDKey` baked into v0.1.0, and prompts the user to
   install.
4. Click Install → Sparkle quits the app, swaps the bundle, relaunches.

If the signature check fails, you'll see "Update Error" with a
verification message. That means either: (a) the
`SPARKLE_ED_PRIVATE_KEY` repo secret doesn't match the
`SUPublicEDKey` in v0.1.0's Info.plist, or (b) something corrupted
the signature in transit. Re-run `generate_keys` and start fresh.

## What to report back

1. **B-3.1** — does the appcast XML validate?
2. **B-3.2** — does the workflow complete on the first real tag
   push? CI failures are usually about: Xcode version drift (pin
   to a newer one in `release.yml`), missing secrets (the workflow
   warns but doesn't fail), or hdiutil flakiness on CI (intermittent).
3. **B-3.3** — does the full update flow work end-to-end? If yes,
   you've completed the release milestone.

After B-3 the project is shipping-ready for 0.1.0 beta.
