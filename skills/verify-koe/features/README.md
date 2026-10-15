# Koe macOS verification map

This directory is the maintained source for verifying the user-facing behavior of
Koe on macOS. Read the index before driving the app, then use the matching feature
file as the recipe.

## Baseline preconditions

- Apple Silicon macOS with Flutter, Xcode command line tools, and one Developer ID
  Application certificate for team `LQAVR62TK2` in the login keychain.
- Run in a non-login shell with no provider credentials loaded, from the repository
  root.
- Evidence goes to `build/verify-koe/<timestamp>/`; every synthetic Keychain item uses
  a `com.semanticcraft.koe.validation.*` service name.
- Never drive a personal credential item, and never authorize a system dialog for the
  user. Diagnose with `python3 skills/verify-koe/scripts/check.py doctor` first.

## Driving conventions

- Start from the baseline state, and change one layer at a time: native store,
  scratch app, signed install.
- Treat commands as literal; keep service names and flags unchanged.
- Record the code requirement and CDHash of anything you install or launch.
- A check that cannot fail is not a check: keep the negative control (ad-hoc rebuild,
  missing configuration) in the same run as the positive one.

## Proof and skip reporting

- Capture the action and its result, not only a final state: the app's own readback of
  the configured provider, plus the absence of a system authorization prompt.
- Name the layer a result proves (synthetic item, scratch app, delivered install) and
  do not promote it to the next layer.
- Report an unreachable path with the attempted command and the unmet precondition;
  provider calls and a real user authorization are user actions, not agent steps.

## Feature entry contract

Each feature file starts with an H1 title and one paragraph describing the
user-visible behavior, then exactly four H2 sections in this order: `Sub-features`,
`How to get to it (user POV)`, `Driving it with check.py`, `Gotchas`. Keep
implementation detail out of the map; name only paths, commands, and observable proof.

## Features

- [Signed install and upgrade](./signed-install-upgrade.md) covers building, signing,
  installing, and upgrading without losing saved Keychain access.
- [Development credential isolation](./development-credentials.md) covers development
  builds and the checks that keep them away from personal credentials.
- [Settings and startup](./settings-startup.md) covers what the user sees at launch
  and how the settings screen resolves a storage failure.
