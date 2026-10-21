import 'package:flutter/foundation.dart';

// What kind of device Koe runs on. Read from Flutter's target platform, not
// dart:io, so widget tests can switch it with
// `debugDefaultTargetPlatformOverride` or `TargetPlatformVariant`.

/// iPhone or Android phone: share sheets instead of save dialogs, phone
/// recording, topics.
bool get runsOnPhone =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.android);

/// The Mac desk app.
bool get runsOnMac => !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

/// iPhone or Mac: the two ends of Mac archiving.
bool get runsOnApple =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS);
