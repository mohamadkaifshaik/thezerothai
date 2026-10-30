import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../domain/composer_attachment_rules.dart';

/// The "Add a GIF" action in the composer's bottom bar (W6-11, ADR-0029). The
/// caller decides whether it exists ([ComposerAttachmentRules.showGif]) and
/// why it is off ([block]); the tooltip then gives the reason. [onPressed]
/// null (no handler wired yet, or the post is sending) also disables it.
class ComposerGifButton extends StatelessWidget {
  const ComposerGifButton({
    super.key,
    required this.block,
    required this.enabled,
    this.onPressed,
  });

  final ComposerBlock block;

  /// False while the post is being sent.
  final bool enabled;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: block.gifTooltip,
      icon: const Icon(Icons.gif_box_outlined),
      onPressed: enabled && block == ComposerBlock.none ? onPressed : null,
    );
  }
}

/// The "Add poll" action in the composer's bottom bar (W6-11, ADR-0029); see
/// [ComposerGifButton] for the contract. [selected] shows the poll builder is
/// open (W6-12): the icon is filled and accent-coloured.
class ComposerPollButton extends StatelessWidget {
  const ComposerPollButton({
    super.key,
    required this.block,
    required this.enabled,
    this.selected = false,
    this.onPressed,
  });

  final ComposerBlock block;
  final bool enabled;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: block.pollTooltip,
      isSelected: selected,
      icon: const Icon(Icons.poll_outlined),
      selectedIcon: Icon(Icons.poll, color: context.appColors.accentText),
      onPressed: enabled && block == ComposerBlock.none ? onPressed : null,
    );
  }
}
