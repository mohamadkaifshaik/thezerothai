import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import 'character_counter.dart';

/// A text field the way the designs draw it (dz.css `.field`): its [label]
/// above a filled field, the counter under it at the end, then the [error] or
/// the [helper]. The field is keyed `field-<label>` so tests and callers find
/// it without the label living inside the decoration.
///
/// The label is spoken as the field's own name (the [TextField] sits in a
/// [Semantics] carrying it), not read a second time as loose text. [remaining]
/// is the characters left under the field's limit; null shows no counter.
/// [readOnly] with a [suffixIcon] is a stored value with an action in it
/// (Edit profile's Remove).
class AppLabeledField extends StatelessWidget {
  const AppLabeledField({
    super.key,
    required this.label,
    required this.controller,
    required this.enabled,
    this.remaining,
    this.error,
    this.helper,
    this.helperMaxLines,
    this.hint,
    this.minLines,
    this.maxLines = 1,
    this.textInputAction,
    this.textCapitalization = TextCapitalization.none,
    this.keyboardType,
    this.plainText = false,
    this.readOnly = false,
    this.suffixIcon,
    this.onChanged,
  });

  final String label;
  final TextEditingController controller;
  final bool enabled;
  final int? remaining;
  final String? error;
  final String? helper;
  final int? helperMaxLines;
  final String? hint;
  final int? minLines;
  final int maxLines;
  final TextInputAction? textInputAction;
  final TextCapitalization textCapitalization;
  final TextInputType? keyboardType;

  /// No autocorrect and no suggestions (a web address).
  final bool plainText;
  final bool readOnly;
  final Widget? suffixIcon;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final left = remaining;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ExcludeSemantics(
            child: Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: context.appColors.text2,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Semantics(
            label: label,
            child: TextField(
              key: ValueKey('field-$label'),
              controller: controller,
              enabled: enabled,
              readOnly: readOnly,
              minLines: minLines,
              maxLines: maxLines,
              textInputAction: textInputAction,
              textCapitalization: textCapitalization,
              keyboardType: keyboardType,
              autocorrect: !plainText,
              enableSuggestions: !plainText,
              onChanged: onChanged,
              decoration: InputDecoration(
                hintText: hint,
                errorText: error,
                helperText: helper,
                helperMaxLines: helperMaxLines,
                suffixIcon: suffixIcon,
                counter: left == null
                    ? null
                    : CharacterCounter(remaining: left),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
