# Settings and startup

At startup the app loads non-secret settings and shows the saved provider without
asking for any password; when the system store cannot be read silently, the settings
screen explains it and offers one explicit retry that performs the single
authorization.

## Sub-features

- `startup-silent` loads settings and provider state without any system prompt.
- `startup-shows-provider` shows the configured provider (千问/豆包) as 使用中.
- `settings-error-banner` shows the storage message plus 重试读取安全配置 when a read
  fails.
- `settings-retry-authorized` performs the one interactive read on explicit user
  action, then reloads settings.
- `save-failure-report` keeps the old credential and reports a save failure instead of
  claiming success.

## How to get to it (user POV)

- Launch the installed app; the 首页 shows the selected engine.
- Open 设置.
- Press 重试读取安全配置 when the banner about the system store appears.

## Driving it with check.py

Preconditions:

- Installed app quit, then launched again by the user or by
  `open /Applications/Soundcore Manager.app`.
- `check.py doctor` recorded the installed requirement and CDHash for this session.

Reaching 设置: the Flutter window exposes no accessibility children while
accessibility is off, so `System Events` sees only the window controls. Take a
screenshot first, click the 设置 item in the left rail (about 40 points from the
window's left edge, 263 points below its top), then take a second screenshot: only
the 处理与偏好 page is proof that the click landed. With VoiceOver running the AX
tree is populated and the rail can be addressed by name instead. Launching the app
also proves startup behavior on its own — screenshot and `pgrep -x SecurityAgent`
are enough for the no-dialog check.

- **Startup.** Launch the app and watch for a system dialog. None may appear; the
  security layer only reads silently at startup (`_loadPersistedSettings`), and any
  stored item that predates this build fails fast instead.
- **Provider state.** Open 设置 and confirm the provider the user configured shows
  使用中. On an install that has no saved item yet, expect no provider selected —
  that is also a pass, and needs recording as "not configured yet".
- **Retry path.** If the banner appears, press 重试读取安全配置: one authorization
  prompt is expected, and afterwards the provider shows 使用中. A second prompt right
  after is a failure of this feature.
- **Save path.** Change a key in 设置 and save; the old value must survive a failed
  save, and no silent retry may substitute one key for another.

## Gotchas

- Do not treat "no dialog at startup" alone as proof of the fix: pair it with the
  provider readback, because a silently empty store also shows no dialog.
- Apple-device transcription is offered without credentials, so an unconfigured
  provider is not a storage failure.
- The settings banner is also shown for unrelated failures; read its text before
  concluding that authorization is missing.
