import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';

/// The hint (and spoken name) of the Communities page's filter (F37).
const kSearchCommunitiesHint = 'Search communities';

/// The hint of the members page's handle search (F36): it names what is
/// searched.
const kSearchMembersHint = 'Search members by handle';

/// The spoken name of the members page's handle search (F36).
const kSearchMembersLabel = 'Search members';

/// The helper under the members search while it holds one character.
const kMemberSearchTooShortHelper = 'Type at least 2 characters.';

/// A scoped search field of the communities pages (dz.css `.search`): the
/// pill of the shared search field (outline, search icon, a 48 dp Clear
/// button once there is text), without its suggestions. The page owns the
/// [controller], so the same text follows the field between the page and
/// band B's context pane.
///
/// With no [controller] it is the field's placeholder: the same box,
/// disabled (the pane before the page has lent its field).
class CommunitySearchField extends StatelessWidget {
  const CommunitySearchField({
    super.key,
    required this.hint,
    this.label,
    this.helperFor,
    this.controller,
    this.onChanged,
    this.margin = const EdgeInsets.only(bottom: AppSpacing.md),
  });

  final String hint;

  /// The spoken name; [hint] when null.
  final String? label;

  /// A helper line under the field for its current text (null: none).
  final String? Function(String text)? helperFor;
  final TextEditingController? controller;
  final ValueChanged<String>? onChanged;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = context.appColors;
    final controller = this.controller;
    OutlineInputBorder border(Color color) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadius.pill),
      borderSide: BorderSide(color: color),
    );
    Widget field(String? helper) => Semantics(
      label: label ?? hint,
      child: TextField(
        controller: controller,
        enabled: controller != null,
        onChanged: onChanged,
        textInputAction: TextInputAction.search,
        autocorrect: false,
        enableSuggestions: false,
        style: theme.textTheme.bodyLarge,
        decoration: InputDecoration(
          hintText: hint,
          helperText: helper,
          helperMaxLines: 2,
          isDense: true,
          filled: false,
          prefixIcon: Icon(
            Icons.search,
            size: AppIconSize.md,
            color: colors.secondaryOnRaised,
          ),
          prefixIconConstraints: const BoxConstraints(
            minWidth: AppSpacing.xxl,
            minHeight: AppSpacing.xxl,
          ),
          suffixIcon: controller == null
              ? null
              : ValueListenableBuilder<TextEditingValue>(
                  valueListenable: controller,
                  builder: (context, value, _) => value.text.isEmpty
                      ? const SizedBox.shrink()
                      : IconButton(
                          tooltip: 'Clear search',
                          icon: const Icon(Icons.cancel, size: 20),
                          constraints: const BoxConstraints(
                            minWidth: AppSpacing.minTapTarget,
                            minHeight: AppSpacing.minTapTarget,
                          ),
                          onPressed: () {
                            controller.clear();
                            onChanged?.call('');
                          },
                        ),
                ),
          border: border(scheme.outlineVariant),
          enabledBorder: border(scheme.outlineVariant),
          disabledBorder: border(scheme.outlineVariant),
          focusedBorder: border(scheme.primary),
          contentPadding: const EdgeInsets.symmetric(vertical: AppSpacing.smd),
        ),
      ),
    );
    final helperFor = this.helperFor;
    return Padding(
      padding: margin,
      // The hint goes once there is text: the field keeps its spoken name
      // (as the shared search field does).
      child: helperFor == null || controller == null
          ? field(null)
          : ValueListenableBuilder<TextEditingValue>(
              valueListenable: controller,
              builder: (context, value, _) => field(helperFor(value.text)),
            ),
    );
  }
}
