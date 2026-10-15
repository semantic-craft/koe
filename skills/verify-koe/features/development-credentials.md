# Development credential isolation

A development or verification build never reads, writes, or migrates the personal
credentials and never asks for the login keychain password; it keeps its own
process-local credentials and its own settings file.

## Sub-features

- `dev-default-isolated` makes every Debug macOS build use an in-process store.
- `dev-mode-explicit` keeps `KOE_CREDENTIAL_SOURCE` (any value, including a typo)
  isolated instead of falling back to the personal item.
- `dev-no-security` proves no Security entry point is reached at all.
- `dev-separate-settings` keeps development settings in
  `Documents/AnkerRecorderDevelopment/`, leaving the personal file untouched.
- `release-identity-gate` lets only a build carrying the Developer ID requirement read
  the system item; anything else falls back to isolated.

## How to get to it (user POV)

- Run the app from a development build (`scripts/debug-mac.sh`) or the verification
  fixture, then open 设置 and save a provider key.
- The user's real credentials stay unavailable to those builds; no system dialog
  appears.

## Driving it with check.py

Preconditions:

- No provider credentials in the environment.
- Working tree is clean enough that a Debug rebuild is expected (the check replaces
  and then deletes the shared Debug product).

- **Native isolation.** Run `check.py native`. Every `debug-*` and
  `release-adhoc-*` case must pass; the compiled spy aborts the process if any
  Security entry point is reached, including the `authorize` call.
- **Spy falsification.** Compile the same fixture with `-D REACHES_SECURITY`; it must
  fail with `REGRESSION: credential read reached Security`. Without this the spy could
  be silently dead.
- **Real app isolation.** Run `check.py isolated-app`. Each run prints
  `KOE_CREDENTIAL_ISOLATION_PASS: load/save/readback/authorize; Security calls=0`, and
  `result.json` records the captured output.
- **Settings separation.** The same run saves a synthetic key; the personal
  `Documents/AnkerRecorder/app_settings.json` must still hold its earlier contents.
  `test/credential_storage_test.dart` guards this in the Dart suite.

## Gotchas

- `check.py isolated-app` deletes the shared Debug product on purpose; rebuild with
  `flutter build macos --debug -t lib/main.dart` afterwards.
- The Debug fixture must import `package:koe/...`; importing the app by its older
  package name silently tests a different library.
- A passing unit test with a mocked platform channel proves the Dart branch only.
  Keep the native and real-app checks in the same run.
- Never "fix" a failing isolation check by granting the development build access in the
  Keychain Access utility.
