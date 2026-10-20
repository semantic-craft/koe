import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// How a sentence the user marked as a key point looks wherever it shows:
/// while capturing, in the text, and on the timeline.
TextStyle highlightTextStyle(BuildContext context) => TextStyle(
  backgroundColor: KoeTokens.of(context).amberSoft,
  fontWeight: FontWeight.w600,
);
