# Signed install and upgrade

Installing a new build keeps the credentials the user already saved: the app reads
its Keychain item without asking for the login password again, and the settings
screen still shows the configured provider as 使用中.

## Sub-features

- `install-build` builds Release and signs it with the team's Developer ID identity.
- `install-replace` replaces `/Applications/Soundcore Manager.app` after staging and
  verifying a signed copy, refusing to overwrite a running app.
- `install-requirement` keeps the designated requirement identical across installs so
  an existing authorization keeps working.
- `install-refuse-adhoc` stops instead of producing an unsigned or ad-hoc build.
- `upgrade-read` reads the saved item again after a differently built install.

## How to get to it (user POV)

- Run `scripts/install-macos.sh` from the repository root.
- Launch the installed app from Finder/Spotlight and open 设置.
- Install a newer build later and open 设置 again.

## Driving it with check.py

Preconditions:

- `python3 skills/verify-koe/scripts/check.py doctor` reports one Developer ID identity
  and the installed bundle with its requirement and CDHash.
- The installed app is not running.

- **Record the old boundary.** Run `check.py doctor` and keep the installed
  `requirement` and `cdhash`. The requirement is what the Keychain access control list
  stores for this app.
- **Install.** Run `scripts/install-macos.sh`. The output ends with
  `Verified: /Applications/Soundcore Manager.app` and
  `Installed signed macOS Release; existing app data retained.`, and prints
  `Existing install shares this code requirement; saved Keychain access stays valid.`
  when the requirement did not change.
- **Confirm the new boundary.** Run `check.py doctor` again. The requirement must equal
  the recorded one; the CDHash must differ when the binary changed, which is what makes
  this a real upgrade rather than a reinstall of the same build.
- **Launch and read back.** Launch the app, open 设置, and confirm the configured
  provider shows 使用中 with no password dialog. The app's own display is the proof;
  the signature check is not.
- **Upgrade again.** Pick up a different build (change Dart code or rebuild), install
  again, relaunch, and confirm no authorization is requested the second time.

## Gotchas

- `scripts/install-macos.sh` refuses to install while the app runs. Quit it first; do
  not force-replace the bundle.
- A build signed by another team or ad-hoc has a different requirement, so macOS asks
  once even though nothing is wrong with the Keychain item. Report that as a one-time
  authorization, not as a pass or a failure.
- Only the user can complete that authorization (Computer Use must not drive the
  SecurityAgent dialog). If it is needed and refused, the run is BLOCKED, not PASS.
- `codesign --verify` passing says nothing about which build wrote the existing item.
  Always pair it with the app's readback.
- Never delete or rewrite the personal `com.semanticcraft.soundcore.credentials` item
  to make an upgrade test pass.
