import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

/// What a field collects. It decides the autofill hints, the keyboard and the
/// text-entry flags, so a credential field cannot ship without hints.
enum AppFieldKind {
  email(
    autofillHints: [AutofillHints.email],
    keyboardType: TextInputType.emailAddress,
  ),
  username(
    autofillHints: [AutofillHints.username],
    keyboardType: TextInputType.text,
  ),
  currentPassword(
    autofillHints: [AutofillHints.password],
    keyboardType: TextInputType.visiblePassword,
    isSecret: true,
  ),
  newPassword(
    autofillHints: [AutofillHints.newPassword],
    keyboardType: TextInputType.visiblePassword,
    isSecret: true,
  ),
  oneTimeCode(
    autofillHints: [AutofillHints.oneTimeCode],
    keyboardType: TextInputType.number,
  ),

  /// Free text; autofill hints are optional (see [AppTextField.autofillHints]).
  plain(autofillHints: <String>[], keyboardType: TextInputType.text);

  const AppFieldKind({
    required this.autofillHints,
    required this.keyboardType,
    this.isSecret = false,
  });

  /// Platform autofill hints for this kind (empty for [plain]).
  final List<String> autofillHints;
  final TextInputType keyboardType;

  /// Passwords start obscured and get a show/hide toggle.
  final bool isSecret;

  /// Credentials: autocorrect and suggestions are off so secrets and handles
  /// are not sent to a keyboard dictionary.
  bool get isCredential => this != plain;
}

/// Minimum height of a multiline [AppTextField.area] (dp).
const double _areaMinHeight = 96;

/// A text field with a visible label above it, an optional hint under the
/// label, and an error or confirmation message under the field (dz.css
/// `.field`, `.hint`, `.err`, `.ok`).
///
/// Semantics: the field node carries the label, the hint (or, while there is
/// an error, the error) and `validationResult`. The error row is a separate
/// live region, so it is spoken once when it appears or its text changes and
/// not again on rebuilds; the decoration's own error text is not used, which
/// avoids a second announcement. Errors are never colour alone: they carry an
/// icon and text.
///
/// Errors are controlled through [errorText] (state lives in the cubit).
class AppTextField extends StatefulWidget {
  const AppTextField({
    super.key,
    required this.label,
    required this.kind,
    this.controller,
    this.focusNode,
    this.hint,
    this.errorText,
    this.okText,
    this.semanticsLabel,
    this.autofillHints,
    this.counter,
    this.area = false,
    this.minLines,
    this.maxLines,
    this.maxLength,
    this.enabled = true,
    this.autofocus = false,
    this.readOnly = false,
    this.obscure,
    this.keyboardType,
    this.textInputAction,
    this.textCapitalization = TextCapitalization.none,
    this.inputFormatters,
    this.onChanged,
    this.onSubmitted,
    this.onEditingComplete,
  }) : assert(
         kind == AppFieldKind.plain || autofillHints == null,
         'autofillHints can only be overridden for AppFieldKind.plain',
       );

  /// Sentence-case label shown above the field.
  final String label;
  final AppFieldKind kind;
  final TextEditingController? controller;
  final FocusNode? focusNode;

  /// Muted help under the label; replaced by [errorText] while there is one.
  final String? hint;

  /// The error. Non-empty shows the error row (icon + text), turns the border
  /// to the error colour and announces it as a live region.
  final String? errorText;

  /// A confirmation under the field (dz.css `.ok`); ignored while
  /// [errorText] is set.
  final String? okText;

  /// Replaces [label] in the field's spoken name when the visible label alone
  /// is not enough.
  final String? semanticsLabel;

  /// Hints for [AppFieldKind.plain] only; other kinds carry their own.
  final List<String>? autofillHints;

  /// Slot for a `CharacterCounter` (placed in the decoration's counter).
  final Widget? counter;

  /// Multiline area: at least 96 dp tall.
  final bool area;
  final int? minLines;
  final int? maxLines;
  final int? maxLength;
  final bool enabled;
  final bool autofocus;
  final bool readOnly;

  /// Initial obscuring for secret kinds (default true there, false otherwise).
  /// Only secret kinds show the toggle.
  final bool? obscure;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final TextCapitalization textCapitalization;
  final List<TextInputFormatter>? inputFormatters;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onEditingComplete;

  /// The autofill hints this field passes to the platform.
  List<String> get effectiveAutofillHints => kind == AppFieldKind.plain
      ? (autofillHints ?? const <String>[])
      : kind.autofillHints;

  @override
  State<AppTextField> createState() => _AppTextFieldState();
}

class _AppTextFieldState extends State<AppTextField> {
  late bool _obscured = widget.obscure ?? widget.kind.isSecret;

  bool get _hasError => (widget.errorText ?? '').isNotEmpty;
  bool get _hasOk => !_hasError && (widget.okText ?? '').isNotEmpty;
  bool get _hasHint => (widget.hint ?? '').isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = context.appColors;
    final kind = widget.kind;
    final hints = widget.effectiveAutofillHints;
    final secret = kind.isSecret;
    final multiline = widget.area;
    final label = widget.semanticsLabel ?? widget.label;
    // While there is an error it is the more useful hint.
    final spokenHint = _hasError
        ? widget.errorText
        : (_hasHint ? widget.hint : null);

    final field = TextFormField(
      controller: widget.controller,
      focusNode: widget.focusNode,
      enabled: widget.enabled,
      autofocus: widget.autofocus,
      readOnly: widget.readOnly,
      obscureText: secret && _obscured,
      autofillHints: hints.isEmpty ? null : hints,
      keyboardType:
          widget.keyboardType ??
          (multiline ? TextInputType.multiline : kind.keyboardType),
      textInputAction:
          widget.textInputAction ??
          (multiline ? TextInputAction.newline : null),
      textCapitalization: widget.textCapitalization,
      autocorrect: !kind.isCredential,
      enableSuggestions: !kind.isCredential,
      inputFormatters: widget.inputFormatters,
      maxLength: widget.maxLength,
      maxLengthEnforcement: MaxLengthEnforcement.enforced,
      minLines: multiline ? (widget.minLines ?? 4) : widget.minLines,
      maxLines: secret
          ? 1
          : (multiline ? (widget.maxLines ?? 10) : widget.maxLines ?? 1),
      onChanged: widget.onChanged,
      onFieldSubmitted: widget.onSubmitted,
      onEditingComplete: widget.onEditingComplete,
      // The message is drawn below, as its own live region. forceErrorText
      // turns the border red; the zero-size builder keeps the decoration from
      // adding a second, spoken copy of the text.
      forceErrorText: _hasError ? widget.errorText : null,
      errorBuilder: (context, error) => const SizedBox.shrink(),
      decoration: InputDecoration(
        counter: widget.counter,
        // We draw the length counter ourselves via [counter] or not at all.
        counterText: widget.counter == null ? '' : null,
        suffixIcon: secret
            ? IconButton(
                tooltip: _obscured ? 'Show password' : 'Hide password',
                icon: Icon(
                  _obscured
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
                onPressed: () => setState(() => _obscured = !_obscured),
              )
            : null,
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        ExcludeSemantics(
          child: Text(
            widget.label,
            style: theme.textTheme.labelMedium?.copyWith(color: colors.text2),
          ),
        ),
        if (_hasHint && !_hasError) ...[
          const SizedBox(height: AppSpacing.xs),
          ExcludeSemantics(
            child: Text(
              widget.hint!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.sm),
        ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: multiline ? _areaMinHeight : 0,
          ),
          child: Semantics(
            label: label,
            hint: spokenHint,
            validationResult: _hasError
                ? SemanticsValidationResult.invalid
                : SemanticsValidationResult.none,
            child: field,
          ),
        ),
        if (_hasError)
          _Message(
            key: const ValueKey('app-text-field-error'),
            text: widget.errorText!,
            icon: Icons.error_outline,
            color: scheme.error,
            live: true,
          )
        else if (_hasOk)
          _Message(
            key: const ValueKey('app-text-field-ok'),
            text: widget.okText!,
            icon: Icons.check_circle_outline,
            color: colors.selectedIndicator,
            live: true,
          ),
      ],
    );
  }
}

/// The error / ok row. A live region on its own node: it is spoken when it
/// appears or its text changes, and not on rebuilds with the same text.
class _Message extends StatelessWidget {
  const _Message({
    super.key,
    required this.text,
    required this.icon,
    required this.color,
    required this.live,
  });

  final String text;
  final IconData icon;
  final Color color;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(color: color);
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xs),
      child: Semantics(
        liveRegion: live,
        container: true,
        label: text,
        child: ExcludeSemantics(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(icon, size: AppIconSize.sm, color: color),
              ),
              const SizedBox(width: AppSpacing.xs),
              Expanded(child: Text(text, style: style)),
            ],
          ),
        ),
      ),
    );
  }
}
