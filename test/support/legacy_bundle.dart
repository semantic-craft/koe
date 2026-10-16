/// Contents/Info.plist of a bundle at the legacy install path. The defaults
/// describe the pre-rename Soundcore Manager build that
/// scripts/retire-legacy-macos-app.sh may retire; overriding a value lets a
/// test present Koe.app (same Bundle ID) or a newer build at that path.
String legacyInfoPlist({
  String executable = 'Soundcore Manager',
  String name = 'Soundcore Manager',
  String? displayName,
  String version = '1.0.0',
  String build = '1',
}) =>
    '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.anker.ankerRecorder</string>
  <key>CFBundleExecutable</key><string>$executable</string>
  <key>CFBundleName</key><string>$name</string>
${displayName == null ? '' : '  <key>CFBundleDisplayName</key><string>$displayName</string>\n'}  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$build</string>
</dict>
</plist>
''';
