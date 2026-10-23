import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// The counts offered for about how many people speak in a recording
/// (Shiyin R22.1, R24.2); not choosing one leaves it to the speaker labelling.
const expectedSpeakerCounts = [2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12];

/// '人数：自动判断' or '大约 3 人'.
String expectedSpeakersLabel(int? count) =>
    count == null ? '人数：自动判断' : '大约 $count 人';

/// The choices as chips, for a dialog: 自动判断, then 2 人 to 12 人.
class ExpectedSpeakersChips extends StatelessWidget {
  const ExpectedSpeakersChips({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  final int? selected;
  final ValueChanged<int?> onSelected;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        ChoiceChip(
          key: const ValueKey('expected-speakers-auto'),
          label: const Text('自动判断'),
          selected: selected == null,
          onSelected: (_) => onSelected(null),
        ),
        for (final n in expectedSpeakerCounts)
          ChoiceChip(
            key: ValueKey('expected-speakers-$n'),
            label: Text('$n 人'),
            selected: selected == n,
            onSelected: (_) => onSelected(n),
          ),
      ],
    );
  }
}

/// The same choices behind one compact button that shows the current one.
class ExpectedSpeakersMenu extends StatelessWidget {
  const ExpectedSpeakersMenu({
    super.key,
    required this.selected,
    required this.onSelected,
    this.enabled = true,
  });

  /// A menu item can't carry null, so 自动判断 travels as this.
  static const _auto = 0;

  final int? selected;
  final ValueChanged<int?> onSelected;

  /// False while the screen is about to close, so no menu is left open on it.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    // PopupMenuButton with a custom child has no button role.
    return Semantics(
      button: true,
      child: PopupMenuButton<int>(
        tooltip: '大约几个人',
        enabled: enabled,
        initialValue: selected ?? _auto,
        onSelected: (value) => onSelected(value == _auto ? null : value),
        itemBuilder: (_) => [
          const PopupMenuItem(
            key: ValueKey('expected-speakers-auto'),
            value: _auto,
            child: Text('自动判断'),
          ),
          for (final n in expectedSpeakerCounts)
            PopupMenuItem(
              key: ValueKey('expected-speakers-$n'),
              value: n,
              child: Text('$n 人'),
            ),
        ],
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: AppColors.bgCardHover,
            borderRadius: BorderRadius.circular(AppRadii.button),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.groups_outlined, size: 18),
              const SizedBox(width: 6),
              Text(
                expectedSpeakersLabel(selected),
                style: const TextStyle(fontSize: 14),
              ),
              const Icon(Icons.expand_more_rounded, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}
