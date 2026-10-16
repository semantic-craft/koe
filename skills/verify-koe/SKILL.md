---
name: verify-koe
description: Verify the Koe macOS app (installed as /Applications/Koe.app; formerly Soundcore Manager.app): development credential isolation, Developer ID signing, and Keychain access that survives install upgrades. Use before delivering signing, Keychain, credential or macOS install changes.
---

# Verify Koe macOS credentials and install

Read [features/README.md](features/README.md) first: it maps the user-facing behavior
this skill proves. The macOS app is the primary surface; the phone app shares
`darwin/KeychainStore.swift` but is installed and accepted separately.

Every check here uses synthetic items under
`com.semanticcraft.koe.validation.*`, a scratch app copy, or process-local state.
No check reads, prints, rewrites or deletes a personal credential, and none of them
change Keychain authorizations. A one-time system authorization is a user action:
ask for it, never drive the SecurityAgent dialog yourself.

## Launch

Run from the repository root in a **non-login shell** with no provider credentials
loaded (`env -u DASHSCOPE_API_KEY -u ARK_API_KEY -u DOUBAO_TTS_API_KEY`). A shell that
already exports them makes 千问 look configured, which fails unrelated UI tests.
Do not `direnv exec` for the checks below.

- **Daily install (delivery artifact).** `scripts/install-macos.sh` builds Release,
  signs it with the unique Developer ID Application certificate of team
  `LQAVR62TK2`, stages a copy, and replaces
  `/Applications/Koe.app`. It refuses to install while Koe or the pre-rename
  `Soundcore Manager.app` is running and refuses to fall back to ad-hoc signing. After
  installing it archives the pre-rename bundle to
  `~/Library/Application Support/Koe Install Backups/*.zip`, verifies the archive,
  then removes and unregisters the old bundle (`scripts/retire-legacy-macos-app.sh`;
  `--keep-legacy` skips this). Bundle ID and data container are unchanged. `scripts/sign-macos.sh` is the
  shared signer; `scripts/build-dmg.sh` reuses it before packaging.
- **Isolated verification app.** `skills/verify-koe/scripts/check.py isolated-app`
  builds a fixture entrypoint into the shared Debug product and copies it to a
  scratch name before running it. Ready = the log line
  `KOE_CREDENTIAL_ISOLATION_PASS`. It deletes both copies; see Cleanup.
- **Provider acceptance (only when asked).** `scripts/run-with-secrets.py macos`
  launches the installed app with environment credentials and
  `KOE_CREDENTIAL_SOURCE=environment`, so no Keychain read happens. Provider
  acceptance needs real audio and the user's own credentials — a separate, explicitly
  authorized run.
- **Debug UI (VoiceOver).** `scripts/check-macos-accessibility.py` builds
  `test/support/macos_accessibility_app.dart` into the Debug product and needs
  VoiceOver running; restore with
  `flutter build macos --debug -t lib/main.dart` afterwards.

## Doctor

```sh
python3 skills/verify-koe/scripts/check.py doctor
```

One read-only report: installed bundle designated requirement and CDHash, the
signing identity found for the team, running Koe processes, whether a personal
credential item exists (`true`/`false` only), and which build products exist.
It exits non-zero when there is nothing installed or built to verify, so run it
first whenever a result looks wrong. Compare the printed requirement with the
previous install before blaming the app: a changed requirement is what makes macOS
ask for the login password again.

## Drive

```sh
python3 skills/verify-koe/scripts/check.py native         # isolation + cross-build access
python3 skills/verify-koe/scripts/check.py isolated-app   # real app, development mode
```

`native` compiles `darwin/KeychainStore.swift` with test entrypoints and runs each
mapped recipe from [features/](features/README.md). It asserts that development
builds never reach Security, that two Developer ID builds share Keychain access
across a rebuild, and that the ad-hoc control **fails fast** instead of blocking on
a password dialog. The measured `adhoc_block_seconds` is the regression signal: a
blocked read is the reported symptom.

`isolated-app` runs the real Flutter app in development mode and fails if
`securityCalls != 0`. It proves the Dart/`AppConfiguration` path, not just the native
store.

For install/upgrade acceptance run the real thing, in this order:

1. Record the installed requirement and CDHash (`check.py doctor`).
2. Quit the installed app; `scripts/install-macos.sh`.
3. Launch `/Applications/Koe.app`, open Settings, and confirm the
   configured provider shows 使用中 with no password dialog.
4. Rebuild and install again (a different Dart/Flutter build), relaunch, and confirm
   no authorization was requested a second time.

Step 4 is the whole point: a same-build restart proves nothing about upgrades. When
the requirement changes, macOS asks once — say so instead of calling it a pass.

`flutter test` in the non-login shell covers the Dart-side regression suite
(`test/credential_storage_test.dart` guards the isolation default and the development
settings path).

## Evidence

Every `check.py` mode writes its full logs plus `result.json` into
`build/verify-koe/<timestamp>/` (override with `--evidence DIR`). `result.json` is the
machine-readable proof: SHA-256 of the two signed builds, the ad-hoc control's
failure time, and the isolated app's captured output.

Keep for install acceptance: the designated requirement and CDHash before and after,
the `install-macos.sh` output, and the app's own state read back from the running app.
Say explicitly which layer each artifact proves:

- synthetic Keychain item under a validation service → native store behavior;
- scratch app copy with `securityCalls=0` → development isolation in the real app;
- signed install launched by the user → delivered build keeps its saved access.

An unsigned or simulator-only result, a signature check, or a passing unit test is
never evidence for the next layer. Provider calls stay out of `check.py` entirely.

## Cleanup

`check.py` cleans up after itself: it removes compiled binaries, unregisters and
deletes the scratch app, deletes the shared Debug product it replaced, and deletes
every synthetic Keychain item it created (validation services only). It keeps the
evidence directory.

After an `isolated-app` or `native` run:

- rebuild the normal development app with
  `flutter build macos --debug -t lib/main.dart` if you need it (the check deletes it
  on purpose, so no verification fixture stays behind);
- quit any installed app you launched yourself
  (`pkill -f '^/Applications/Koe.app/Contents/MacOS/Koe$'`);
- never kill by process name alone, never delete the personal
  `com.semanticcraft.soundcore.credentials` item, and never touch the user's Keychain
  authorizations.

## Helpers

- `skills/verify-koe/scripts/check.py doctor|native|isolated-app` — the checks above,
  `--evidence DIR` to choose the output directory, `--team` to override the team.
- `scripts/sign-macos.sh [--identity NAME] [--verify-only] APP` — sign or verify a
  built bundle; prints CDHash and the designated requirement.
- `scripts/install-macos.sh [--skip-build] [--identity NAME]` — build, sign, install.
- `scripts/run-with-secrets.py macos` — launch the installed app with injected
  environment credentials (explicit authorization only).
- `scripts/check-macos-accessibility.py` — native VoiceOver AX regression.
