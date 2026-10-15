import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../ai/apple_speech.dart';
import '../../ai/moss_stt.dart';
import '../../ai/soniox_languages.dart';
import '../../ai/stt_types.dart';
import '../../state/recorder_controller.dart';
import '../../theme/app_theme.dart';
import '../widgets/widgets.dart';

/// Processing choices apply to the next recording.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    final tokens = KoeTokens.of(context);

    return GradientScaffold(
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
          children: [
            const SectionLabel('传输与同步'),
            _SettingsGroup(
              key: const ValueKey('settings-transfer-group'),
              child: _SettingsSwitch(
                icon: Icons.sync_rounded,
                title: '自动传输',
                subtitle: c.autoTransferActive
                    ? '正在传输设备端未导出录音…'
                    : '连接后自动下载设备上的历史录音',
                value: c.autoRealtime,
                onChanged: c.setAutoRealtime,
              ),
            ),
            const SizedBox(height: 20),
            const SectionLabel('语音与翻译'),
            _SettingsGroup(
              key: const ValueKey('settings-stt-group'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _SettingsSwitch(
                    icon: Icons.auto_awesome_outlined,
                    title: '自动转写',
                    subtitle: c.speechProvider == SttProvider.moss
                        ? '录音结束后生成文字'
                        : '录音时生成文字',
                    value: c.autoTranscribe,
                    onChanged: c.setAutoTranscribe,
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Divider(height: 1),
                  ),
                  _ProviderSelector(controller: c),
                  const SizedBox(height: 16),
                  if (c.speechProvider == SttProvider.soniox) ...[
                    _ApiKeyField(
                      key: const ValueKey('apikey-soniox'),
                      label: 'Soniox API Key',
                      initialValue: c.sonioxApiKeyStored ?? '',
                      onSave: c.setSonioxApiKey,
                    ),
                    const SizedBox(height: 14),
                    _TranscriptLanguageSelector(controller: c),
                  ] else if (c.speechProvider == SttProvider.moss)
                    _MossKeyField(controller: c)
                  else if (c.speechProvider == SttProvider.apple)
                    _AppleLanguageSettings(controller: c),
                  if (c.isLiveSession) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 9,
                      ),
                      decoration: BoxDecoration(
                        color: tokens.amberSoft,
                        borderRadius: BorderRadius.circular(AppRadii.md),
                        border: Border.all(color: tokens.amberBorder),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.info_outline_rounded,
                            size: 16,
                            color: tokens.amber,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '更改将用于下一段录音',
                              style: TextStyle(
                                color: tokens.textPrimary,
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (c.speechProvider != SttProvider.moss) ...[
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 18),
                      child: Divider(height: 1),
                    ),
                    _SttModeSelector(controller: c),
                  ],
                  if (c.mossRecoveryError != null) ...[
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 9,
                      ),
                      decoration: BoxDecoration(
                        color: tokens.coralSoft,
                        borderRadius: BorderRadius.circular(AppRadii.md),
                        border: Border.all(color: tokens.coralBorder),
                      ),
                      child: Text(
                        c.mossRecoveryError!,
                        style: TextStyle(
                          color: tokens.coral,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                  if (c.sttMode == SttDisplayMode.translation &&
                      c.speechProvider == SttProvider.soniox) ...[
                    const SizedBox(height: 14),
                    _TranslationLanguageSettings(controller: c),
                  ],
                  if (c.speechProvider == SttProvider.soniox &&
                      c.sttMode == SttDisplayMode.conversation) ...[
                    const SizedBox(height: 14),
                    _CommunicationLanguageSettings(controller: c),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Data-driven ASR engine lineup selector inspired by open-design selectable
/// workspace cards (`SettingsWorkspaceSection.module.css`).
///
/// Iterates over `SttProvider.values` dynamically and uses a non-exhaustive
/// name-based metadata lookup so newly added engines (such as Qwen ASR) render
/// automatically without merge conflicts.
class _ProviderSelector extends StatelessWidget {
  const _ProviderSelector({required this.controller});

  final RecorderController controller;

  ({
    IconData icon,
    String description,
    String statusLabel,
    Color statusColor,
  })
  _metaFor(SttProvider provider, KoeTokens tokens) {
    switch (provider.name) {
      case 'soniox':
        final configured =
            (controller.sonioxApiKeyStored ?? '').trim().isNotEmpty;
        return (
          icon: Icons.cloud_outlined,
          description: '云端低延迟流式转写，支持多语种同传与双人对话',
          statusLabel: configured ? '已配置' : '需密钥',
          statusColor: configured ? tokens.mint : tokens.amber,
        );
      case 'apple':
        final caps = controller.appleCapabilities;
        final ready =
            caps.supported && caps.speechStatus == SpeechResourceStatus.ready;
        return (
          icon: Icons.phone_iphone_rounded,
          description: 'iOS 本地神经网络语音引擎，离线可用、隐私优先',
          statusLabel: !caps.supported
              ? '设备受限'
              : ready
              ? '已就绪'
              : '待准备',
          statusColor: !caps.supported
              ? tokens.textMuted
              : ready
              ? tokens.mint
              : tokens.amber,
        );
      case 'moss':
        final configured =
            (controller.mossApiKeyStored ?? '').trim().isNotEmpty;
        return (
          icon: Icons.graphic_eq_rounded,
          description: '录音完成后整段精细转写，自动切分说话人段落',
          statusLabel: configured ? '已配置' : '需密钥',
          statusColor: configured ? tokens.mint : tokens.amber,
        );
      default:
        final isQwen = provider.name.toLowerCase().contains('qwen');
        return (
          icon: isQwen ? Icons.auto_awesome_rounded : Icons.mic_none_rounded,
          description: isQwen
              ? '通义千问语音识别模型，支持中英多语种高准确度转写'
              : '${provider.label} 语音识别引擎',
          statusLabel: controller.speechProvider == provider ? '使用中' : '可用',
          statusColor: controller.speechProvider == provider
              ? tokens.accent
              : tokens.textMuted,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = KoeTokens.of(context);
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
              '共 ${SttProvider.values.length} 个引擎',
              style: TextStyle(
                fontSize: 12,
                color: tokens.textMuted,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        for (var i = 0; i < SttProvider.values.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          _EngineOptionCard(
            provider: SttProvider.values[i],
            selected: controller.speechProvider == SttProvider.values[i],
            meta: _metaFor(SttProvider.values[i], tokens),
            onTap: () => controller.setSpeechProvider(SttProvider.values[i]),
          ),
        ],
      ],
    );
  }
}

class _EngineOptionCard extends StatelessWidget {
  const _EngineOptionCard({
    required this.provider,
    required this.selected,
    required this.meta,
    required this.onTap,
  });

  final SttProvider provider;
  final bool selected;
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
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: ValueKey('speech-provider-option-${provider.name}'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadii.md),
        child: AnimatedContainer(
          duration: AppMotion.fast,
          curve: AppMotion.easeOut,
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
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              IconBadge(
                icon: meta.icon,
                size: 32,
                iconSize: 16,
                radius: 8,
                color: selected ? tokens.onInkAccent : tokens.textSecondary,
                backgroundColor: selected ? tokens.inkAccent : tokens.bgCard,
                borderColor: selected ? tokens.inkAccent : tokens.borderSoft,
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
                            color: meta.statusColor.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(AppRadii.pill),
                            border: Border.all(
                              color: meta.statusColor.withValues(alpha: 0.28),
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
                  color: selected ? tokens.inkAccent : tokens.textFaint,
                ),
              ),
            ],
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
    final tokens = KoeTokens.of(context);
    final capabilities = c.appleCapabilities;
    final preparing = c.appleLanguagePreparationBusy;
    final loading = c.appleCapabilitiesLoading;
    if (!capabilities.supported) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: tokens.bgPanel,
          borderRadius: BorderRadius.circular(AppRadii.md),
          border: Border.all(color: tokens.borderSoft),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              loading
                  ? '正在检查设备支持…'
                  : c.appleSetupError ?? 'Apple 设备端需要 iOS 26 和受支持的设备。',
              style: TextStyle(
                color: tokens.textSecondary,
                fontSize: 13,
                height: 1.4,
              ),
            ),
            if (!loading) ...[
              const SizedBox(height: 6),
              TextButton.icon(
                onPressed: c.refreshAppleCapabilities,
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text('重新检查'),
              ),
            ],
          ],
        ),
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
        const SizedBox(height: 14),
        _AppleLanguageField(
          label: '翻译目标语言',
          value: c.translationTargetLanguage,
          languages: capabilities.translationLanguages,
          onChanged: preparing ? null : c.setTranslationTargetLanguage,
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(
                speechReady && translationReady
                    ? Icons.check_circle_outline_rounded
                    : Icons.info_outline_rounded,
                size: 15,
                color: speechReady && translationReady
                    ? tokens.mint
                    : tokens.textSecondary,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                preparing
                    ? '正在准备语言…'
                    : loading
                    ? '正在检查语言…'
                    : !speechReady
                    ? (capabilities.speechStatus ==
                              SpeechResourceStatus.unsupported
                          ? '请选择受支持的原文语言'
                          : '转写语言需要下载')
                    : !translationReady
                    ? (capabilities.translationStatus ==
                              SpeechResourceStatus.unsupported
                          ? '转写可用，请选择受支持的翻译语言组合'
                          : '转写可用，翻译语言需要下载')
                    : '转写和翻译语言已就绪',
                style: TextStyle(
                  color: tokens.textSecondary,
                  fontSize: 12.5,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
        if (c.appleSetupError != null) ...[
          const SizedBox(height: 8),
          Text(
            c.appleSetupError!,
            style: TextStyle(
              color: tokens.coral,
              fontSize: 12.5,
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
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.download_rounded, size: 17),
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
    final tokens = KoeTokens.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: tokens.bgCard,
        borderRadius: BorderRadius.circular(AppRadii.lg),
        border: Border.all(color: tokens.border),
        boxShadow: tokens.cardShadow,
      ),
      child: child,
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
    final tokens = KoeTokens.of(context);
    final soniox = c.speechProvider == SttProvider.soniox;
    final subtitle = !c.autoTranscribe
        ? '请先开启自动转写'
        : soniox
        ? '翻译为单向，交流为双向'
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '实时模式',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 14,
            color: tokens.textPrimary,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 3),
          Text(
            subtitle,
            style: TextStyle(
              color: tokens.textSecondary,
              fontSize: 12,
              height: 1.35,
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
              enabled:
                  c.autoTranscribe &&
                  (c.speechProvider == SttProvider.apple
                      ? c.appleTranslationAvailable
                      : c.sonioxTranslationModeAvailable),
            ),
            if (soniox)
              ButtonSegment(
                value: SttDisplayMode.conversation,
                label: const Text('交流'),
                enabled: c.conversationModeAvailable,
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

class _TranslationLanguageSettings extends StatelessWidget {
  const _TranslationLanguageSettings({required this.controller});

  final RecorderController controller;

  @override
  Widget build(BuildContext context) {
    return _LanguageField(
      label: '目标语言',
      code: controller.translationTargetLanguage,
      excludedCode: null,
      onSelected: controller.setTranslationTargetLanguage,
    );
  }
}

class _SettingsSwitch extends StatelessWidget {
  const _SettingsSwitch({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    this.icon,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final tokens = KoeTokens.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (icon != null) ...[
          IconBadge(
            icon: icon!,
            size: 34,
            iconSize: 17,
            radius: 9,
            color: value ? tokens.accent : tokens.textSecondary,
            backgroundColor: value ? tokens.accentSoft : tokens.bgPanel,
            borderColor: value ? tokens.accentBorder : tokens.borderSoft,
          ),
          const SizedBox(width: 12),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                  color: tokens.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(
                  color: tokens.textSecondary,
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Switch.adaptive(
          value: value,
          activeTrackColor: tokens.accent.withValues(alpha: 0.45),
          activeThumbColor: tokens.accent,
          onChanged: onChanged,
        ),
      ],
    );
  }
}

class _CommunicationLanguageSettings extends StatelessWidget {
  const _CommunicationLanguageSettings({required this.controller});

  final RecorderController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final tokens = KoeTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _LanguageField(
          label: '我的语言',
          code: c.ownerLanguage,
          excludedCode: c.guestLanguage,
          onSelected: c.setOwnerLanguage,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Center(
            child: IconButton(
              key: const ValueKey('swap-communication-languages'),
              tooltip: '交换语言',
              visualDensity: VisualDensity.compact,
              onPressed: c.swapCommunicationLanguages,
              icon: Icon(
                Icons.swap_vert_rounded,
                color: tokens.textSecondary,
              ),
            ),
          ),
        ),
        _LanguageField(
          label: '对方语言',
          code: c.guestLanguage,
          excludedCode: c.ownerLanguage,
          onSelected: c.setGuestLanguage,
        ),
      ],
    );
  }
}

class _LanguageField extends StatelessWidget {
  const _LanguageField({
    required this.label,
    required this.code,
    required this.excludedCode,
    required this.onSelected,
  });

  final String label;
  final String code;
  final String? excludedCode;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final tokens = KoeTokens.of(context);
    final language = sonioxLanguageFor(code);
    return OutlinedButton(
      key: ValueKey('communication-language-$label'),
      style: OutlinedButton.styleFrom(
        backgroundColor: tokens.bgPanel,
        foregroundColor: tokens.textPrimary,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        side: BorderSide(color: tokens.border),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
        ),
      ),
      onPressed: () async {
        final selected = await showModalBottomSheet<String>(
          context: context,
          useSafeArea: true,
          isScrollControlled: true,
          backgroundColor: tokens.bgCard,
          builder: (_) => _LanguagePickerSheet(
            title: label,
            selectedCode: code,
            excludedCode: excludedCode,
          ),
        );
        if (selected != null) onSelected(selected);
      },
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: tokens.textSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  language.label,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: tokens.textPrimary,
                  ),
                ),
              ],
            ),
          ),
          Icon(
            Icons.unfold_more_rounded,
            size: 18,
            color: tokens.textSecondary,
          ),
        ],
      ),
    );
  }
}

class _LanguagePickerSheet extends StatefulWidget {
  const _LanguagePickerSheet({
    required this.title,
    required this.selectedCode,
    required this.excludedCode,
  });

  final String title;
  final String selectedCode;
  final String? excludedCode;

  @override
  State<_LanguagePickerSheet> createState() => _LanguagePickerSheetState();
}

class _LanguagePickerSheetState extends State<_LanguagePickerSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final tokens = KoeTokens.of(context);
    final query = _query.trim().toLowerCase();
    final languages = sonioxLanguages.where((language) {
      if (language.code == widget.excludedCode) return false;
      if (query.isEmpty) return true;
      return language.code.contains(query) ||
          language.name.toLowerCase().contains(query);
    }).toList();

    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.82,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: tokens.border,
                      borderRadius: BorderRadius.circular(AppRadii.pill),
                    ),
                  ),
                ),
                Text(
                  '选择${widget.title}',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: tokens.textPrimary,
                  ),
                ),
                const SizedBox(height: 12),
                SearchBar(
                  hintText: '搜索语言或代码',
                  leading: Icon(
                    Icons.search_rounded,
                    size: 18,
                    color: tokens.textSecondary,
                  ),
                  elevation: const WidgetStatePropertyAll(0),
                  backgroundColor: WidgetStatePropertyAll(tokens.bgPanel),
                  side: WidgetStatePropertyAll(
                    BorderSide(color: tokens.border),
                  ),
                  onChanged: (value) => setState(() => _query = value),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              itemCount: languages.length,
              itemBuilder: (context, index) {
                final language = languages[index];
                final selected = language.code == widget.selectedCode;
                return ListTile(
                  title: Text(
                    language.name,
                    style: TextStyle(
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      color: tokens.textPrimary,
                    ),
                  ),
                  subtitle: Text(
                    language.code,
                    style: TextStyle(fontSize: 12, color: tokens.textMuted),
                  ),
                  trailing: selected
                      ? Icon(Icons.check_rounded, color: tokens.accent)
                      : null,
                  onTap: () => Navigator.of(context).pop(language.code),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ApiKeyField extends StatefulWidget {
  const _ApiKeyField({
    super.key,
    required this.label,
    required this.initialValue,
    required this.onSave,
  });

  final String label;
  final String initialValue;
  final ValueChanged<String?> onSave;

  @override
  State<_ApiKeyField> createState() => _ApiKeyFieldState();
}

class _ApiKeyFieldState extends State<_ApiKeyField> {
  late final TextEditingController _controller;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void didUpdateWidget(covariant _ApiKeyField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Sync from controller only when not mid-edit.
    if (!_dirty && oldWidget.initialValue != widget.initialValue) {
      _controller.text = widget.initialValue;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _commit() {
    final v = _controller.text.trim();
    widget.onSave(v.isEmpty ? null : v);
    setState(() => _dirty = false);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          v.isEmpty ? '已清除 ${widget.label}' : '已保存 ${widget.label}',
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = KoeTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.key_rounded, size: 15, color: tokens.textSecondary),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                widget.label,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                  color: tokens.textPrimary,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _controller,
          onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          style: TextStyle(
            fontSize: 13,
            fontFamily: 'Menlo',
            color: tokens.textPrimary,
          ),
          decoration: InputDecoration(
            isDense: true,
            hintText: '粘贴 API Key…',
            hintStyle: TextStyle(
              fontSize: 12,
              color: tokens.textMuted,
            ),
            filled: true,
            fillColor: tokens.bgPanel,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 12,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppRadii.md),
              borderSide: BorderSide(color: tokens.border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppRadii.md),
              borderSide: BorderSide(color: tokens.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppRadii.md),
              borderSide: BorderSide(color: tokens.accent, width: 1.4),
            ),
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_controller.text.isNotEmpty)
                  IconButton(
                    tooltip: '清除',
                    onPressed: () {
                      _controller.clear();
                      setState(() => _dirty = true);
                      widget.onSave(null);
                      setState(() => _dirty = false);
                    },
                    icon: Icon(
                      Icons.clear_rounded,
                      size: 18,
                      color: tokens.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
          onChanged: (_) {
            if (!_dirty) setState(() => _dirty = true);
          },
          onSubmitted: (_) => _commit(),
        ),
        if (_dirty) ...[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: AccentButton(
              label: '保存',
              icon: Icons.check_rounded,
              expand: false,
              onPressed: _commit,
            ),
          ),
        ],
      ],
    );
  }
}

class _MossKeyField extends StatefulWidget {
  const _MossKeyField({required this.controller});
  final RecorderController controller;
  @override
  State<_MossKeyField> createState() => _MossKeyFieldState();
}

class _MossKeyFieldState extends State<_MossKeyField> {
  late final TextEditingController _text = TextEditingController(
    text: widget.controller.mossApiKeyStored ?? '',
  );
  bool _busy = false;
  String? _message;
  Future<void> _save() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await widget.controller.validateAndSaveMossApiKey(_text.text);
      if (mounted) setState(() => _message = 'MOSS API Key 已保存');
    } catch (error) {
      if (mounted) {
        setState(
          () => _message = error is MossException ? error.message : '无法保存，请重试',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = KoeTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const ValueKey('apikey-moss'),
          controller: _text,
          enabled: !_busy,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          style: TextStyle(
            fontSize: 13,
            fontFamily: 'Menlo',
            color: tokens.textPrimary,
          ),
          decoration: InputDecoration(
            labelText: 'MOSS API Key',
            filled: true,
            fillColor: tokens.bgPanel,
            suffixIcon: widget.controller.mossApiKeyStored == null
                ? null
                : IconButton(
                    tooltip: '清除',
                    onPressed: _busy
                        ? null
                        : () {
                            widget.controller.clearMossApiKey();
                            _text.clear();
                            setState(() => _message = 'MOSS API Key 已清除');
                          },
                    icon: const Icon(Icons.clear_rounded, size: 18),
                  ),
          ),
          onSubmitted: (_) => _save(),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(
            onPressed: _busy ? null : _save,
            child: Text(_busy ? '正在验证…' : '验证并保存'),
          ),
        ),
        if (_message != null) ...[
          const SizedBox(height: 8),
          Text(
            _message!,
            style: TextStyle(fontSize: 12.5, color: tokens.textSecondary),
          ),
        ],
      ],
    );
  }
}
