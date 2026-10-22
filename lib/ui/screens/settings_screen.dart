import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_identity.dart';
import '../../ai/engine_config.dart';
import '../../ai/cloud_stt_service.dart';
import '../../ai/stt_types.dart';
import '../../ai/apple_speech.dart';
import '../../state/recorder_controller.dart';
import '../../platform/credential_store.dart';
import '../../theme/app_theme.dart';
import '../widgets/widgets.dart';
import '../widgets/about_koe.dart';
import '../widgets/mac_archive_settings.dart';
import 'device_screen.dart';
import '../widgets/koe_icon_button.dart';
import '../../platform/device_kind.dart';

/// Processing choices apply to the next recording.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, this.showBack = false});

  /// Pushed as a phone route (#131) rather than an always-visible desktop pane.
  final bool showBack;

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();

    return GradientScaffold(
      child: SafeArea(
        child: Stack(
          children: [
            ListView(
              padding: EdgeInsets.fromLTRB(20, showBack ? 56 : 8, 20, 24),
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 8, bottom: 24),
                  child: Text(
                    '处理与偏好',
                    style: TextStyle(fontSize: 26, fontWeight: FontWeight.w600),
                  ),
                ),
                if (c.settingsStorageError != null)
                  Text(
                    c.settingsStorageError!,
                    style: const TextStyle(color: AppColors.coral),
                  ),
                if (c.settingsStorageError != null)
                  TextButton(
                    onPressed: c.reloadSettings,
                    child: const Text('重试读取安全配置'),
                  ),
                const SectionLabel('传输'),
                _SettingsGroup(
                  key: const ValueKey('settings-transfer-group'),
                  child: _SettingsSwitch(
                    title: '自动传输',
                    subtitle: c.autoTransferActive
                        ? '正在传输设备端未导出录音…'
                        : '自动下载设备上的历史录音',
                    value: c.autoRealtime,
                    onChanged: c.setAutoRealtime,
                  ),
                ),
                const SizedBox(height: 18),
                const SectionLabel('语音与翻译'),
                _SettingsGroup(
                  key: const ValueKey('settings-stt-group'),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _SettingsSwitch(
                        title: '自动转写',
                        subtitle: '连接录音时实时转写，取回独立录音后自动处理',
                        value: c.autoTranscribe,
                        onChanged: c.setAutoTranscribe,
                      ),
                      if (c.phoneRecordingEnabled) ...[
                        const Divider(height: 20),
                        _SettingsSwitch(
                          key: const ValueKey('settings-all-day-listening'),
                          title: '全天监听',
                          subtitle:
                              '打开后按「手机录音」或录音豆录音键，一直识别、只留文字，'
                              '安静约 10 分钟另起一条；安静时不上传声音',
                          value: c.allDayListening,
                          onChanged: c.setAllDayListening,
                        ),
                      ],
                      const Divider(height: 20),
                      _SettingsSwitch(
                        key: const ValueKey('settings-auto-organize'),
                        title: '自动整理新录音',
                        subtitle: '之后的新录音自动转写、写摘要并提取待办；以前的录音不会自动处理',
                        value: c.autoOrganize,
                        onChanged: c.setAutoOrganize,
                      ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          key: const ValueKey('settings-organize-history'),
                          onPressed: () => showOrganizeHistorySheet(context),
                          child: const Text('整理以前的录音…'),
                        ),
                      ),
                      const Divider(height: 20),
                      _ProviderSelector(controller: c),
                      const Divider(height: 20),
                      _SettingsSwitch(
                        key: const ValueKey('settings-meeting-local-only'),
                        title: '录音只留本机',
                        subtitle:
                            '会议录音只用本机引擎转写，不向云端上传音频（局域网加密直连归档到自己的 Mac 不受影响）；'
                            '纯文字记录、按住说话与全天监听不受影响，纪要与问答只发文字',
                        value: c.meetingLocalOnly,
                        onChanged: c.setMeetingLocalOnly,
                      ),
                      if (c.meetingLocalOnly &&
                          !c.onDeviceSpeechSupported &&
                          !c.appleCapabilitiesLoading) ...[
                        const SizedBox(height: 6),
                        Text(
                          c.meetingLocalOnlyUnavailableMessage,
                          key: const ValueKey(
                            'meeting-local-only-unavailable',
                          ),
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 12,
                            height: 1.35,
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                      if (c.speechProvider.usesEngineTrio) ...[
                        _CloudEngineSettings(
                          key: ValueKey(c.speechProvider),
                          controller: c,
                          provider: c.speechProvider,
                        ),
                        const SizedBox(height: 14),
                        _TranscriptLanguageSelector(controller: c),
                      ] else
                        _AppleLanguageSettings(controller: c),
                      if (c.isLiveSession) ...[
                        const SizedBox(height: 12),
                        const Text(
                          '更改将用于下一段录音',
                          style: TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 13,
                          ),
                        ),
                      ],
                      if (!c.speechProvider.defersTranscription) ...[
                        const Divider(height: 28),
                        _SttModeSelector(controller: c),
                      ],
                      if (c.fileJobRecoveryError != null)
                        Text(c.fileJobRecoveryError!),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                const SectionLabel('设备'),
                _SettingsGroup(
                  child: ListTile(
                    key: const ValueKey('device-entry'),
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.headphones_rounded),
                    title: const Text('安克录音豆'),
                    subtitle: Text(
                      c.connected
                          ? '已连接 · ${c.displayDeviceName}'
                          : '未连接设备 · 打开后扫描',
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        settings: const RouteSettings(name: 'device'),
                        builder: (_) => const DeviceScreen(showBack: true),
                      ),
                    ),
                  ),
                ),
                if (runsOnApple) ...[
                  const SizedBox(height: 18),
                  const SectionLabel('Mac 原件归档'),
                  MacArchiveSettings(controller: c),
                ],
                const SizedBox(height: 18),
                const SectionLabel('外部 AI'),
                _SettingsGroup(
                  child: ListTile(
                    key: const ValueKey('external-ai-entry'),
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.hub_outlined),
                    title: const Text('外部 AI 连接'),
                    subtitle: const Text('尚未开放 · 后续用于让授权客户端读取资料'),
                    trailing: const Text(
                      '未开放',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    onTap: () => _showExternalAiNotice(context),
                  ),
                ),
                const SizedBox(height: 18),
                _SettingsGroup(
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.info_outline_rounded),
                    title: const Text('关于 Koe'),
                    subtitle: const Text(AppIdentity.subtitle),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => showKoeAboutDialog(context),
                  ),
                ),
              ],
            ),
            if (showBack)
              Positioned(
                left: 8,
                top: 4,
                child: KoeIconButton(
                  key: const ValueKey('settings-back'),
                  tooltip: '返回',
                  onPressed: () => Navigator.maybePop(context),
                  style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _showExternalAiNotice(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('外部 AI 尚未开放'),
        content: const Text(
          '这里以后用于连接经授权的外部客户端，让它们读取你选择的资料并交办任务。'
          '当前版本不会发起连接、不会申请权限，也不会显示连接成功。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }
}

/// Data-driven ASR engine lineup. Iterates over the engines the controller
/// offers on this device and derives each card from per-engine metadata plus
/// the controller's configuration state, so adding an engine is a data change
/// (enum value plus a [_metadata] entry) — no engine-specific widget code.
class _ProviderSelector extends StatelessWidget {
  const _ProviderSelector({required this.controller});
  final RecorderController controller;

  static const _metadata = <SttProvider, ({IconData icon, String description})>{
    SttProvider.apple: (
      icon: Icons.phone_iphone_rounded,
      description: 'iOS 本地神经网络语音引擎，离线可用、隐私优先',
    ),
    SttProvider.qwen: (
      icon: Icons.auto_awesome_rounded,
      description: '千问 3.1 实时转写与长录音识别',
    ),
    SttProvider.doubao: (
      icon: Icons.bolt_rounded,
      description: '豆包 2.0 实时二遍识别与录音文件极速转写',
    ),
  };

  ({IconData icon, String description, String statusLabel, Color statusColor})
  _metaFor(SttProvider provider, KoeTokens tokens) {
    final meta =
        _metadata[provider] ??
        (icon: Icons.mic_none_rounded, description: '${provider.label} 语音识别引擎');
    final selected = controller.speechProvider == provider;
    if (provider == SttProvider.apple) {
      final caps = controller.appleCapabilities;
      final ready =
          caps.supported && caps.speechStatus == SpeechResourceStatus.ready;
      return (
        icon: meta.icon,
        description: meta.description,
        statusLabel: !caps.supported
            ? '设备受限'
            : ready
            ? (selected ? '使用中' : '已就绪')
            : '待准备',
        statusColor: !caps.supported
            ? tokens.textMuted
            : ready
            ? (selected ? tokens.accent : tokens.textSecondary)
            : tokens.amber,
      );
    }
    final configured = controller.engineConfigured(provider);
    return (
      icon: meta.icon,
      description: meta.description,
      statusLabel: !configured ? '需密钥' : (selected ? '使用中' : '已配置'),
      statusColor: !configured
          ? tokens.amber
          : (selected ? tokens.accent : tokens.textSecondary),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = KoeTokens.of(context);
    final providers = controller.speechProviders;
    return Column(
      key: ValueKey('speech-provider-${controller.speechProvider.name}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '语音服务',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                  color: tokens.textPrimary,
                ),
              ),
            ),
            Text(
              '共 ${providers.length} 个引擎',
              style: TextStyle(
                fontSize: 12,
                color: tokens.textMuted,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        for (var i = 0; i < providers.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          _EngineOptionCard(
            provider: providers[i],
            selected: controller.speechProvider == providers[i],
            meta: _metaFor(providers[i], tokens),
            meetingDisabled:
                controller.meetingLocalOnly && !providers[i].onDevice,
            enabled:
                !providers[i].needsCredentials ||
                controller.engineConfigured(providers[i]),
            onTap: () => _tap(context, providers[i]),
          ),
        ],
      ],
    );
  }

  void _tap(BuildContext context, SttProvider provider) {
    if (!provider.needsCredentials || controller.engineConfigured(provider)) {
      controller.setSpeechProvider(provider);
      return;
    }
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('配置 ${provider.label}'),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: _CloudEngineSettings(
              controller: controller,
              provider: provider,
              onSaved: () {
                controller.setSpeechProvider(provider);
                Navigator.pop(context);
              },
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }
}

class _EngineOptionCard extends StatelessWidget {
  const _EngineOptionCard({
    required this.provider,
    required this.selected,
    required this.meta,
    required this.enabled,
    required this.onTap,
    this.meetingDisabled = false,
  });

  final SttProvider provider;
  final bool selected;
  final bool enabled;
  final bool meetingDisabled;
  final ({
    IconData icon,
    String description,
    String statusLabel,
    Color statusColor,
  })
  meta;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = KoeTokens.of(context);
    return MergeSemantics(
      child: Semantics(
        button: true,
        selected: selected,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            key: ValueKey('speech-provider-option-${provider.name}'),
            onTap: onTap,
            borderRadius: BorderRadius.circular(AppRadii.md),
            child: AnimatedContainer(
              duration: AppMotion.duration(context, AppMotion.snap),
              curve: AppMotion.snappy,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              decoration: BoxDecoration(
                color: selected ? tokens.bgCard : tokens.bgPanel,
                borderRadius: BorderRadius.circular(AppRadii.md),
                border: Border.all(
                  color: selected ? tokens.inkAccent : tokens.border,
                  width: selected ? 1.4 : 1,
                ),
                boxShadow: selected ? tokens.cardShadow : const [],
              ),
              child: Opacity(
                opacity: enabled ? 1 : 0.55,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    IconBadge(
                      icon: meta.icon,
                      size: 32,
                      iconSize: 16,
                      radius: 8,
                      color: selected
                          ? tokens.onInkAccent
                          : tokens.textSecondary,
                      backgroundColor: selected
                          ? tokens.inkAccent
                          : tokens.bgCard,
                      borderColor: selected
                          ? tokens.inkAccent
                          : tokens.borderSoft,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(
                                provider.label,
                                style: TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600,
                                  color: tokens.textPrimary,
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: meta.statusColor.withValues(
                                    alpha: 0.12,
                                  ),
                                  borderRadius: BorderRadius.circular(
                                    AppRadii.pill,
                                  ),
                                ),
                                child: Text(
                                  meta.statusLabel,
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w600,
                                    color: meta.statusColor,
                                    height: 1.2,
                                  ),
                                ),
                              ),
                              if (meetingDisabled)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 7,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: tokens.textMuted.withValues(
                                      alpha: 0.12,
                                    ),
                                    borderRadius: BorderRadius.circular(
                                      AppRadii.pill,
                                    ),
                                  ),
                                  child: Text(
                                    '会议录音已关闭：会上传音频',
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w600,
                                      color: tokens.textSecondary,
                                      height: 1.2,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 3),
                          Text(
                            meta.description,
                            style: TextStyle(
                              fontSize: 12,
                              color: tokens.textSecondary,
                              height: 1.35,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Icon(
                        selected
                            ? Icons.radio_button_checked_rounded
                            : Icons.radio_button_off_rounded,
                        size: 18,
                        color: selected ? tokens.inkAccent : tokens.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AppleLanguageSettings extends StatelessWidget {
  const _AppleLanguageSettings({required this.controller});
  final RecorderController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final capabilities = c.appleCapabilities;
    final preparing = c.appleLanguagePreparationBusy;
    final loading = c.appleCapabilitiesLoading;
    if (!capabilities.supported) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            loading
                ? '正在检查设备支持…'
                : c.appleSetupError ?? 'Apple 设备端需要 iOS 26 和受支持的设备。',
            style: const TextStyle(color: AppColors.textSecondary, height: 1.4),
          ),
          if (!loading)
            TextButton.icon(
              onPressed: c.refreshAppleCapabilities,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('重新检查'),
            ),
        ],
      );
    }
    final speechReady = capabilities.speechStatus == SpeechResourceStatus.ready;
    final translationReady =
        capabilities.translationStatus == SpeechResourceStatus.ready;
    final requiresDownload =
        capabilities.speechStatus == SpeechResourceStatus.needsDownload ||
        capabilities.translationStatus == SpeechResourceStatus.needsDownload;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _AppleLanguageField(
          label: '原文语言',
          value: c.appleSourceLanguage,
          languages: capabilities.speechLanguages,
          onChanged: preparing ? null : c.setAppleSourceLanguage,
        ),
        const SizedBox(height: 16),
        _AppleLanguageField(
          label: '翻译目标语言',
          value: c.translationTargetLanguage,
          languages: capabilities.translationLanguages,
          onChanged: preparing ? null : c.setTranslationTargetLanguage,
        ),
        const SizedBox(height: 12),
        Text(
          preparing
              ? '正在准备语言…'
              : loading
              ? '正在检查语言…'
              : !speechReady
              ? (capabilities.speechStatus == SpeechResourceStatus.unsupported
                    ? '请选择受支持的原文语言'
                    : '转写语言需要下载')
              : !translationReady
              ? (capabilities.translationStatus ==
                        SpeechResourceStatus.unsupported
                    ? '转写可用，请选择受支持的翻译语言组合'
                    : '转写可用，翻译语言需要下载')
              : '转写和翻译语言已就绪',
          style: const TextStyle(
            color: AppColors.textSecondary,
            fontSize: 13,
            height: 1.4,
          ),
        ),
        if (c.appleSetupError != null) ...[
          const SizedBox(height: 8),
          Text(
            c.appleSetupError!,
            style: const TextStyle(
              color: AppColors.coral,
              fontSize: 13,
              height: 1.4,
            ),
          ),
        ],
        if (requiresDownload || preparing || c.appleSetupError != null) ...[
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              key: const ValueKey('prepare-apple-languages'),
              onPressed: preparing || loading || c.isLiveSession
                  ? null
                  : c.prepareAppleLanguages,
              icon: preparing
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.download_rounded),
              label: Text(
                preparing
                    ? '准备中…'
                    : c.appleSetupError == null
                    ? '下载并准备语言'
                    : '重试',
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _AppleLanguageField extends StatelessWidget {
  const _AppleLanguageField({
    required this.label,
    required this.value,
    required this.languages,
    required this.onChanged,
  });
  final String label;
  final String value;
  final List<SpeechLanguage> languages;
  final ValueChanged<String>? onChanged;
  @override
  Widget build(BuildContext context) {
    final selected = languages
        .where((language) => language.code.toLowerCase() == value.toLowerCase())
        .firstOrNull
        ?.code;
    return DropdownButtonFormField<String>(
      key: ValueKey('apple-language-$label-$selected'),
      initialValue: selected,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      hint: const Text('选择语言'),
      items: [
        for (final language in languages)
          DropdownMenuItem(
            value: language.code,
            child: Text(language.name, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: onChanged == null
          ? null
          : (value) {
              if (value != null) onChanged!(value);
            },
    );
  }
}

class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(0, 12, 0, 16),
        child: child,
      ),
    );
  }
}

class _TranscriptLanguageSelector extends StatelessWidget {
  const _TranscriptLanguageSelector({required this.controller});

  static const _languages = [
    ('auto', '自动'),
    ('zh', '中文'),
    ('en', 'English'),
    ('ja', '日本語'),
    ('ko', '한국어'),
  ];

  final RecorderController controller;

  @override
  Widget build(BuildContext context) {
    final selected =
        _languages.any(
          (language) => language.$1 == controller.transcriptLanguage,
        )
        ? controller.transcriptLanguage
        : 'auto';
    return DropdownButtonFormField<String>(
      key: const ValueKey('transcript-language-selector'),
      initialValue: selected,
      decoration: const InputDecoration(labelText: '语言提示'),
      isExpanded: true,
      items: [
        for (final language in _languages)
          DropdownMenuItem(value: language.$1, child: Text(language.$2)),
      ],
      onChanged: (value) {
        if (value != null) controller.setTranscriptLanguage(value);
      },
    );
  }
}

class _SttModeSelector extends StatelessWidget {
  const _SttModeSelector({required this.controller});

  final RecorderController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final subtitle = !c.autoTranscribe ? '请先开启自动转写' : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '实时模式',
          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 3),
          Text(
            subtitle,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
              height: 1.3,
            ),
          ),
        ],
        const SizedBox(height: 10),
        SegmentedButton<SttDisplayMode>(
          key: const ValueKey('stt-display-mode-selector'),
          segments: [
            const ButtonSegment(
              value: SttDisplayMode.transcription,
              label: Text('转写'),
            ),
            ButtonSegment(
              value: SttDisplayMode.translation,
              label: const Text('翻译'),
              enabled: c.translationModeAvailable,
            ),
          ],
          selected: {c.sttMode},
          showSelectedIcon: false,
          onSelectionChanged: (selection) {
            if (selection.isNotEmpty) c.setSttMode(selection.first);
          },
        ),
      ],
    );
  }
}

class _SettingsSwitch extends StatelessWidget {
  const _SettingsSwitch({
    super.key,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    // One screen-reader node: the switch named by the text beside it.
    return MergeSemantics(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
          Switch.adaptive(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _CloudEngineSettings extends StatefulWidget {
  const _CloudEngineSettings({
    super.key,
    required this.controller,
    required this.provider,
    this.onSaved,
  });

  final RecorderController controller;
  final SttProvider provider;
  final VoidCallback? onSaved;

  @override
  State<_CloudEngineSettings> createState() => _CloudEngineSettingsState();
}

class _CloudEngineSettingsState extends State<_CloudEngineSettings> {
  late final TextEditingController _key = TextEditingController(
    text: widget.controller.engineConfig(widget.provider).apiKey ?? '',
  );
  late final TextEditingController _workspace = TextEditingController(
    text: _workspaceId(widget.controller.engineConfig(widget.provider).baseUrl),
  );
  static String _workspaceId(String? baseUrl) {
    final host = Uri.tryParse(baseUrl ?? '')?.host ?? '';
    return host.endsWith('.maas.aliyuncs.com') ? host.split('.').first : '';
  }

  String? _error;
  EngineConfig? _lastSaved;
  bool _saved = false;
  bool _saving = false;
  bool _cleared = false;

  @override
  void initState() {
    super.initState();
    _lastSaved = widget.controller.engineConfig(widget.provider);
  }

  @override
  void didUpdateWidget(covariant _CloudEngineSettings oldWidget) {
    super.didUpdateWidget(oldWidget);
    final saved = widget.controller.engineConfig(widget.provider);
    if (saved != _lastSaved) {
      _lastSaved = saved;
      _key.text = saved.apiKey ?? '';
      _workspace.text = _workspaceId(saved.baseUrl);
    }
  }

  @override
  void dispose() {
    _key.dispose();
    _workspace.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    if (_key.text.trim().isEmpty) {
      setState(() => _error = '请输入 API Key');
      return;
    }
    try {
      final current = widget.controller.engineConfig(widget.provider);
      var baseUrl = current.baseUrl;
      if (widget.provider == SttProvider.qwen) {
        final workspace = _workspace.text.trim();
        if (workspace.isNotEmpty &&
            !RegExp(
              r'^[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$',
            ).hasMatch(workspace)) {
          setState(() => _error = '请填写 Workspace ID，不需要填写网址');
          return;
        }
        final host = Uri.tryParse(current.baseUrl ?? '')?.host ?? '';
        final region = host.endsWith('.maas.aliyuncs.com')
            ? host.split('.')[1]
            : host == 'dashscope-intl.aliyuncs.com'
            ? 'ap-southeast-1'
            : 'cn-beijing';
        baseUrl = workspace.isNotEmpty
            ? 'https://$workspace.$region.maas.aliyuncs.com'
            : region == 'ap-southeast-1'
            ? 'https://dashscope-intl.aliyuncs.com'
            : null;
      }
      setState(() {
        _saving = true;
        _error = null;
      });
      await widget.controller.setEngineConfig(
        widget.provider,
        EngineConfig(apiKey: _key.text, baseUrl: baseUrl, model: current.model),
      );
      if (!mounted) return;
      setState(() {
        _error = null;
        _saved = true;
        _cleared = false;
      });
      FocusScope.of(context).unfocus();
      widget.onSaved?.call();
    } on CloudSttException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on CredentialStorageException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _clear() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final current = widget.controller.engineConfig(widget.provider);
      await widget.controller.setEngineConfig(
        widget.provider,
        EngineConfig(baseUrl: current.baseUrl, model: current.model),
      );
      if (!mounted) return;
      setState(() {
        _key.clear();
        _cleared = true;
        _saved = false;
      });
    } on CredentialStorageException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: ValueKey('apikey-${widget.provider.name}'),
          controller: _key,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: widget.provider == SttProvider.qwen
                ? '通义 API Key'
                : '豆包 API Key',
          ),
          onChanged: (_) => setState(() => _saved = false),
          onSubmitted: (_) => _save(),
        ),
        if (widget.provider == SttProvider.qwen) ...[
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('qwen-workspace'),
            controller: _workspace,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: 'Workspace ID（选填）',
              helperText: '使用专属工作空间时填写；现有配置可留空',
              helperMaxLines: 2,
            ),
            onChanged: (_) => setState(() => _saved = false),
            onSubmitted: (_) => _save(),
          ),
        ],
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? '正在保存…' : '保存'),
          ),
        ),
        if (widget.controller.engineConfig(widget.provider).isConfigured)
          TextButton(
            onPressed: _saving ? null : _clear,
            child: const Text('清除已保存的 API Key'),
          ),
        if (_cleared) const Text('已清除已保存的 API Key；开发环境注入不受影响'),
        if (_saved) const Text('已保存'),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: const TextStyle(color: AppColors.coral)),
        ],
      ],
    );
  }
}

/// Lets the user pick which history to organize; nothing runs until they
/// confirm a range (#133).
Future<void> showOrganizeHistorySheet(BuildContext context) async {
  final c = context.read<RecorderController>();
  final messenger = ScaffoldMessenger.of(context);
  final range = await showModalBottomSheet<OrganizeRange>(
    context: context,
    sheetAnimationStyle: AppMotion.sheetStyle(context),
    showDragHandle: true,
    builder: (sheetContext) {
      Widget option(OrganizeRange range, String title) {
        final count = c.organizeCandidates(range).length;
        return ListTile(
          key: ValueKey('organize-range-${range.name}'),
          title: Text(title),
          subtitle: Text(count == 0 ? '没有需要整理的录音' : '$count 条未整理'),
          enabled: count > 0,
          onTap: () => Navigator.pop(sheetContext, range),
        );
      }

      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                '整理以前的录音',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                '只处理你选的范围：缺文字的先转写，再写摘要、提取待办。已完成的步骤不会重复调用模型。',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
              ),
            ),
            option(OrganizeRange.lastWeek, '最近 7 天'),
            option(OrganizeRange.lastMonth, '最近 30 天'),
            option(OrganizeRange.all, '全部'),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
  if (range == null) return;
  final added = await c.organizeHistory(c.organizeCandidates(range));
  messenger.showSnackBar(
    SnackBar(content: Text(added == 0 ? '这些录音已在整理中' : '已加入整理：$added 条')),
  );
}
