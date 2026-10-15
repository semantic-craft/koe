import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../app_identity.dart';

Future<void> showKoeAboutDialog(BuildContext context) async {
  var version = '版本信息暂不可用';
  try {
    final info = await PackageInfo.fromPlatform();
    if (info.version.isNotEmpty) {
      version = info.buildNumber.isEmpty
          ? info.version
          : '${info.version} (${info.buildNumber})';
    }
  } catch (_) {
    // Keep product information accessible when platform metadata is unavailable.
  }
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      scrollable: true,
      title: Text(
        AppIdentity.name,
        style: Theme.of(context).textTheme.headlineMedium,
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(version),
          const SizedBox(height: 16),
          const Text(AppIdentity.description),
          const SizedBox(height: 12),
          const Text(AppIdentity.supportedDevice),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}
