import 'package:flutter/material.dart';

import '../../app_identity.dart';
import '../../theme/app_theme.dart';
import '../screens/settings_screen.dart';
import 'koe_icon_button.dart';

Future<void> openMobileSettings(BuildContext context) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      settings: const RouteSettings(name: 'settings'),
      builder: (_) => const SettingsScreen(showBack: true),
    ),
  );
}

/// Phone header shared by Today, Projects and Materials (#131).
///
/// The two right-hand actions stay at least 44 by 44 logical pixels and remain
/// reachable at large text sizes; the wordmark is not a decorative image.
class KoeMobileHeader extends StatelessWidget {
  const KoeMobileHeader({
    super.key,
    required this.onNewRecording,
    required this.onOpenSettings,
  });

  final VoidCallback onNewRecording;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        MediaQuery.paddingOf(context).top + 8,
        12,
        4,
      ),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              child: const Text(
                '${AppIdentity.name}.',
                style: TextStyle(
                  fontSize: AppFontSizes.lg,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.8,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
          ),
          KoeIconButton(
            key: const ValueKey('new-recording'),
            tooltip: '新记录',
            onPressed: onNewRecording,
            style: IconButton.styleFrom(
              minimumSize: const Size(48, 48),
              backgroundColor: AppColors.bgCard,
              side: const BorderSide(color: AppColors.border),
              foregroundColor: AppColors.textPrimary,
            ),
            icon: const Icon(Icons.add_rounded),
          ),
          const SizedBox(width: 8),
          KoeIconButton(
            key: const ValueKey('nav-settings'),
            tooltip: '设置',
            onPressed: onOpenSettings,
            style: IconButton.styleFrom(
              minimumSize: const Size(48, 48),
              backgroundColor: AppColors.bgCard,
              side: const BorderSide(color: AppColors.border),
              foregroundColor: AppColors.textPrimary,
            ),
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
    );
  }
}
