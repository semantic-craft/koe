import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../ai/soniox_languages.dart';
import '../../ai/stt_types.dart';
import '../../state/recorder_controller.dart';
import '../../theme/app_theme.dart';

/// Immersive, face-to-face live translation surface.
class CommunicationScreen extends StatefulWidget {
  const CommunicationScreen({super.key, this.reference});
  final RecordingReference? reference;
  @override
  State<CommunicationScreen> createState() => _CommunicationScreenState();
}

class _CommunicationScreenState extends State<CommunicationScreen> {
  String _owner = 'en';
  String _guest = 'zh';
  List<SttTranslationTurn> _ownerTurns = const [];
  List<SttTranslationTurn> _guestTurns = const [];
  String? _error;
  bool _captured = false;

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    final tokens = KoeTokens.of(context);
    final currentReference = c.currentRecordingReference;
    final displayed = widget.reference == null
        ? null
        : c.recordingView(widget.reference!).reference;
    final current =
        widget.reference == null ||
        currentReference != null &&
            (currentReference.key == widget.reference!.key ||
                currentReference.fileId != null &&
                    currentReference.fileId == displayed?.fileId ||
                currentReference.path != null &&
                    currentReference.path == displayed?.path);
    if (current) {
      if (!_captured || c.recording) {
        _owner = c.activeOwnerLanguage;
        _guest = c.activeGuestLanguage;
        _captured = true;
      }
      _ownerTurns = List.of(c.ownerTranslationTurns);
      _guestTurns = List.of(c.guestTranslationTurns);
      _error = c.transcriptError;
    }
    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: AppBar(
        backgroundColor: tokens.bgCard,
        title: const Text('双向交流'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(height: 1, color: tokens.borderSoft),
        ),
      ),
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            Column(
              children: [
                Expanded(
                  child: _TranslationPanel(
                    key: const ValueKey('communication-owner-panel'),
                    languageCode: _owner,
                    turns: _ownerTurns,
                    backgroundColor: tokens.accentSoft.withValues(alpha: 0.55),
                    accentColor: tokens.accent,
                  ),
                ),
                Divider(height: 1, thickness: 1, color: tokens.border),
                Expanded(
                  child: RotatedBox(
                    key: const ValueKey('communication-guest-rotation'),
                    quarterTurns: 2,
                    child: _TranslationPanel(
                      key: const ValueKey('communication-guest-panel'),
                      languageCode: _guest,
                      turns: _guestTurns,
                      backgroundColor: tokens.mintSoft.withValues(alpha: 0.65),
                      accentColor: tokens.mint,
                    ),
                  ),
                ),
              ],
            ),
            Align(
              alignment: Alignment.center,
              child: _CenterControls(
                controller: c,
                current: current,
                error: _error,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TranslationPanel extends StatelessWidget {
  const _TranslationPanel({
    super.key,
    required this.languageCode,
    required this.turns,
    required this.backgroundColor,
    required this.accentColor,
  });

  final String languageCode;
  final List<SttTranslationTurn> turns;
  final Color backgroundColor;
  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    final tokens = KoeTokens.of(context);
    final visibleTurns = turns
        .where((turn) => turn.text.trim().isNotEmpty)
        .toList(growable: false);
    final latest = visibleTurns.isEmpty ? null : visibleTurns.last;
    final contextTurns = latest == null
        ? const <SttTranslationTurn>[]
        : visibleTurns
              .take(visibleTurns.length - 1)
              .where((turn) => turn.isFinal)
              .toList()
              .reversed
              .take(2)
              .toList()
              .reversed
              .toList();
    final language = sonioxLanguageFor(languageCode);

    return Semantics(
      label: '${language.name} translation',
      child: ColoredBox(
        color: backgroundColor,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 34),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: accentColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(AppRadii.pill),
                      border: Border.all(
                        color: accentColor.withValues(alpha: 0.28),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: accentColor,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          language.label,
                          style: TextStyle(
                            color: accentColor,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Expanded(
                child: latest == null
                    ? Center(
                        child: Text(
                          '…',
                          style: TextStyle(
                            color: accentColor.withValues(alpha: 0.45),
                            fontSize: 42,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      )
                    : SingleChildScrollView(
                        reverse: true,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            for (final turn in contextTurns) ...[
                              Text(
                                turn.text,
                                style: TextStyle(
                                  color: tokens.textSecondary,
                                  fontSize: 16,
                                  height: 1.4,
                                ),
                              ),
                              const SizedBox(height: 10),
                            ],
                            Text(
                              latest.text,
                              key: ValueKey(
                                'communication-latest-$languageCode',
                              ),
                              style: TextStyle(
                                color: tokens.textPrimary,
                                fontSize: 28,
                                fontWeight: FontWeight.w700,
                                height: 1.25,
                                letterSpacing: -0.4,
                              ),
                            ),
                          ],
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CenterControls extends StatelessWidget {
  const _CenterControls({
    required this.controller,
    required this.current,
    this.error,
  });

  final RecorderController controller;
  final bool current;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final tokens = KoeTokens.of(context);
    final active = current && c.recording;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: Container(
        key: const ValueKey('communication-center-controls'),
        margin: const EdgeInsets.symmetric(horizontal: 18),
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        decoration: BoxDecoration(
          color: tokens.bgCard.withValues(alpha: 0.98),
          borderRadius: BorderRadius.circular(AppRadii.pill),
          border: Border.all(color: tokens.border),
          boxShadow: tokens.floatingShadow,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: active ? tokens.coral : tokens.textMuted,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    active ? '交流 · Soniox' : '已暂停',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: tokens.textPrimary,
                    ),
                  ),
                ),
                IconButton.filledTonal(
                  key: const ValueKey('communication-pause'),
                  tooltip: '暂停录音',
                  style: IconButton.styleFrom(
                    backgroundColor: active
                        ? tokens.coralSoft
                        : tokens.bgSubtle,
                    foregroundColor: active ? tokens.coral : tokens.textMuted,
                  ),
                  onPressed: active && c.phase != AppPhase.busy
                      ? c.pauseRecord
                      : null,
                  icon: const Icon(Icons.pause_rounded, size: 20),
                ),
              ],
            ),
            if (error != null) ...[
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  error!,
                  key: const ValueKey('communication-error'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: tokens.coral,
                    fontSize: 11,
                    height: 1.25,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
