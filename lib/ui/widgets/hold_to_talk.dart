import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_theme.dart';
import 'status_indicators.dart';

/// Press and hold to talk, release to send, slide up or off the button to
/// cancel (#142). The widget only reads the gesture; what a take becomes is
/// decided by the screen it sits in.
class HoldToTalkButton extends StatefulWidget {
  const HoldToTalkButton({
    super.key,
    required this.onStart,
    required this.onSend,
    required this.onCancel,
    this.label = '按住说话',
    this.enabled = true,
  });

  /// Starts the microphone; false when it could not start.
  final Future<bool> Function() onStart;
  final Future<void> Function() onSend;
  final Future<void> Function() onCancel;
  final String label;
  final bool enabled;

  /// How far up a finger slides before releasing cancels.
  static const double cancelSlide = 60;

  /// Shorter presses are taps: nothing is sent and the hint is shown.
  static const Duration minimumHold = Duration(milliseconds: 300);

  @override
  State<HoldToTalkButton> createState() => _HoldToTalkButtonState();
}

enum _Phase { idle, holding, cancelling }

class _HoldToTalkButtonState extends State<HoldToTalkButton> {
  _Phase _phase = _Phase.idle;
  Offset? _origin;
  DateTime? _pressedAt;
  Future<bool>? _starting;
  Timer? _ticker;
  Timer? _hintTimer;
  bool _hint = false;

  @override
  void dispose() {
    _ticker?.cancel();
    _hintTimer?.cancel();
    if (_phase != _Phase.idle) unawaited(widget.onCancel());
    super.dispose();
  }

  void _down(PointerDownEvent event) {
    if (!widget.enabled || _phase != _Phase.idle) return;
    HapticFeedback.mediumImpact();
    _origin = event.position;
    _pressedAt = DateTime.now();
    _hintTimer?.cancel();
    setState(() {
      _phase = _Phase.holding;
      _hint = false;
    });
    _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (mounted) setState(() {});
    });
    _starting = widget.onStart();
    _starting!.then((started) {
      if (!started && mounted && _phase != _Phase.idle) _reset();
    });
  }

  void _move(PointerMoveEvent event) {
    if (_phase == _Phase.idle) return;
    final origin = _origin!;
    final box = context.findRenderObject() as RenderBox?;
    final inside =
        box == null ||
        (box.localToGlobal(Offset.zero) & box.size)
            .inflate(24)
            .contains(event.position);
    final away =
        origin.dy - event.position.dy > HoldToTalkButton.cancelSlide || !inside;
    final next = away ? _Phase.cancelling : _Phase.holding;
    if (next != _phase) {
      HapticFeedback.selectionClick();
      setState(() => _phase = next);
    }
  }

  Future<void> _up(PointerEvent event) async {
    if (_phase == _Phase.idle) return;
    final cancelled =
        _phase == _Phase.cancelling || event is PointerCancelEvent;
    final tooShort =
        DateTime.now().difference(_pressedAt!) < HoldToTalkButton.minimumHold;
    final starting = _starting;
    _reset();
    final started = await starting ?? false;
    if (!started) return;
    if (cancelled || tooShort) {
      await widget.onCancel();
      if (tooShort && !cancelled && mounted) {
        setState(() => _hint = true);
        _hintTimer = Timer(const Duration(seconds: 2), () {
          if (mounted) setState(() => _hint = false);
        });
      }
      return;
    }
    await widget.onSend();
  }

  void _reset() {
    _ticker?.cancel();
    _ticker = null;
    _starting = null;
    setState(() => _phase = _Phase.idle);
  }

  String _clock() {
    final at = _pressedAt;
    if (at == null) return '0:00';
    final d = DateTime.now().difference(at);
    return '${d.inMinutes}:${d.inSeconds.remainder(60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final holding = _phase != _Phase.idle;
    final cancelling = _phase == _Phase.cancelling;
    final background = !widget.enabled
        ? AppColors.bgPanel
        : cancelling
        ? AppColors.coral
        : holding
        ? AppColors.accentPressed
        : AppColors.accent;
    final foreground = widget.enabled ? Colors.white : AppColors.textMuted;
    final status = cancelling
        ? '松开手指，取消发送'
        : holding
        ? '正在听 ${_clock()} · 松开发送，上滑取消'
        : _hint
        ? '按住说话，松开发送'
        : null;
    final button = Listener(
      onPointerDown: _down,
      onPointerMove: _move,
      onPointerUp: _up,
      onPointerCancel: _up,
      // Claims vertical drags so a sheet or list around the button does not
      // move while the finger slides up to cancel.
      child: GestureDetector(
        onVerticalDragStart: widget.enabled ? (_) {} : null,
        onVerticalDragUpdate: widget.enabled ? (_) {} : null,
        child: AnimatedScale(
          scale: holding ? 1.06 : 1,
          duration: AppMotion.duration(context, AppMotion.snap),
          curve: AppMotion.snappy,
          child: AnimatedContainer(
            duration: AppMotion.duration(context, AppMotion.micro),
            constraints: const BoxConstraints(minHeight: 44),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(AppRadii.pill),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (holding && !cancelling)
                  const BreathingDot(color: Colors.white)
                else
                  Icon(
                    cancelling ? Icons.close_rounded : Icons.mic_rounded,
                    color: foreground,
                    size: 20,
                  ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    cancelling
                        ? '松开取消'
                        : holding
                        ? '松开发送'
                        : widget.label,
                    style: TextStyle(
                      color: foreground,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return Semantics(
      button: true,
      enabled: widget.enabled,
      label: '${widget.label}，松开发送，上滑取消',
      excludeSemantics: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (status != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                status,
                key: const ValueKey('hold-to-talk-status'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: cancelling ? AppColors.coral : AppColors.textSecondary,
                ),
              ),
            ),
          button,
        ],
      ),
    );
  }
}
