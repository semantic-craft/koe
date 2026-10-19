import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// An [IconButton] whose tooltip is also its accessibility name on the Mac.
///
/// The macOS accessibility bridge exposes a Flutter tooltip only as AXHelp,
/// so VoiceOver and scripts/mac-ax saw an unnamed AXButton (#307). iOS already
/// reads the tooltip as the label, so the extra label is Mac-only to avoid
/// VoiceOver saying the name twice.
class KoeIconButton extends IconButton {
  const KoeIconButton({
    super.key,
    super.iconSize,
    super.visualDensity,
    super.padding,
    super.alignment,
    super.splashRadius,
    super.color,
    super.focusColor,
    super.hoverColor,
    super.highlightColor,
    super.splashColor,
    super.disabledColor,
    required super.onPressed,
    super.onHover,
    super.onLongPress,
    super.mouseCursor,
    super.focusNode,
    super.autofocus,
    super.tooltip,
    super.enableFeedback,
    super.constraints,
    super.style,
    super.isSelected,
    super.selectedIcon,
    super.statesController,
    required super.icon,
  });

  @override
  Widget build(BuildContext context) =>
      macAccessibleName(tooltip, super.build(context));
}

/// Gives a tooltip-only control (an icon button, a [PopupMenuButton]) [name]
/// as its accessibility label on the Mac; see [KoeIconButton].
Widget macAccessibleName(String? name, Widget control) {
  if (name == null || defaultTargetPlatform != TargetPlatform.macOS) {
    return control;
  }
  // Merge so the label lands on the control's own node, not on a parent
  // group around it.
  return MergeSemantics(
    child: Semantics(label: name, child: control),
  );
}
