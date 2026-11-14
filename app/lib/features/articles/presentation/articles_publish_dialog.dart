part of 'articles_screen.dart';

class _PublishOptions {
  const _PublishOptions(this.caption, this.policy);
  final String caption;
  final ReplyAudience policy;
}

class _PublishDialog extends StatefulWidget {
  const _PublishDialog({
    required this.draft,
    this.initialCaption = '',
    this.initialPolicy = ReplyAudience.everyone,
    this.locked = false,
    this.canChooseReplyAudience = false,
    this.libraryBeside = false,
  });
  final ArticleDraft draft;

  /// The page shows the library beside it where the window allows (not in
  /// focus mode): in band B of the tablet layout its "Publish settings"
  /// then hold the audience and who can reply, and this dialog does not
  /// ([articlePublishSettingsInPaneAt], decided live).
  final bool libraryBeside;
  final String initialCaption;
  final ReplyAudience initialPolicy;

  /// A publication is pending (or being retried): the caption and policy
  /// of its first attempt are shown read-only and sent again.
  final bool locked;

  /// `reply_audience` is usable ([ArticlesRepository.canChooseReplyAudience]).
  /// Without it, like the composer, there is no reply control and the
  /// article goes out as Everyone.
  final bool canChooseReplyAudience;
  @override
  State<_PublishDialog> createState() => _PublishDialogState();
}

class _PublishDialogState extends State<_PublishDialog> {
  final _caption = TextEditingController();
  ReplyAudience _policy = ReplyAudience.everyone;

  /// A locked retry keeps its stored choice visible (disabled) even with the
  /// capability gone: it must be sent again unchanged.
  bool get _showReplyAudience => widget.canChooseReplyAudience || widget.locked;

  @override
  void initState() {
    super.initState();
    _caption.text = widget.initialCaption;
    // A refused earlier choice may still be stored on the record.
    _policy = _showReplyAudience
        ? widget.initialPolicy
        : ReplyAudience.everyone;
  }

  @override
  void dispose() {
    _caption.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settingsHere =
        !widget.libraryBeside || !articlePublishSettingsInPaneAt(context);
    return _dialog(context, settingsHere: settingsHere);
  }

  Widget _dialog(
    BuildContext context, {
    required bool settingsHere,
  }) => AlertDialog(
    title: const Text('Publish Article'),
    content: SizedBox(
      width: AppSize.contentMax,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (settingsHere) ...[
              Text(
                'Choose your audience',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const ListTile(
                title: Text('Everyone'),
                trailing: Icon(Icons.check_circle),
              ),
              const Divider(),
            ],
            if (settingsHere && _showReplyAudience) ...[
              // Room above and below the heading, so the section does not
              // crowd the divider or its field.
              const SizedBox(height: AppSpacing.md),
              Text(
                'Who can reply?',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: AppSpacing.smd),
              _ReplyAudienceField(
                value: _policy,
                labelText: 'Choose who can reply to this Article',
                onChanged: widget.locked
                    ? null
                    : (value) => setState(() => _policy = value),
              ),
              const SizedBox(height: AppSpacing.lg),
            ],
            TextField(
              controller: _caption,
              readOnly: widget.locked,
              maxLength: 280,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Add a caption to your article',
                helperText:
                    'Optional. Your Article link will be added automatically.',
              ),
            ),
            const Divider(),
            const Text('Post preview'),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Article'),
                    Text(
                      widget.draft.title,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    Text(widget.draft.excerpt()),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        style: FilledButton.styleFrom(
          minimumSize: const Size(
            AppSpacing.minButtonWidth,
            AppSpacing.minTapTarget,
          ),
        ),
        onPressed: () =>
            Navigator.pop(context, _PublishOptions(_caption.text, _policy)),
        child: const Text('Publish'),
      ),
    ],
  );
}

/// "Publish settings" at the top of the editor's library pane in band B of
/// the tablet layout (tablet plan section 6, item 5): the audience (only
/// Everyone until the new-features audience exists) and who can reply,
/// with the publish dialog's rules: no reply control without
/// `reply_audience` unless a pending publication must be resent, and a
/// pending or retried publication's choice shown read-only.
class _PublishSettings extends StatelessWidget {
  const _PublishSettings({
    required this.policy,
    required this.locked,
    required this.canChooseReplyAudience,
    required this.onChanged,
  });

  final ReplyAudience policy;
  final bool locked;
  final bool canChooseReplyAudience;
  final ValueChanged<ReplyAudience> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final showReplyAudience = canChooseReplyAudience || locked;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            header: true,
            child: Text('Publish settings', style: theme.textTheme.titleLarge),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text('Choose your audience', style: theme.textTheme.titleMedium),
          const ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('Everyone'),
            trailing: Icon(Icons.check_circle),
          ),
          if (showReplyAudience)
            _ReplyAudienceField(
              // A new value from outside (the dialog, a reload) rebuilds it.
              key: ValueKey('publish-settings-$policy-$locked'),
              value: policy,
              labelText: 'Who can reply?',
              onChanged: locked ? null : onChanged,
            ),
        ],
      ),
    );
  }
}

/// The "Who can reply?" field of the publish dialog and of the library
/// pane's "Publish settings". It takes the width it is given: the chosen
/// option shows on one line, ellipsized when it does not fit (a phone, a
/// large text scale), and the open menu shows every option whole, wrapping
/// if it must (no fixed item height). [onChanged] null: read-only.
class _ReplyAudienceField extends StatelessWidget {
  const _ReplyAudienceField({
    super.key,
    required this.value,
    required this.labelText,
    required this.onChanged,
  });

  final ReplyAudience value;
  final String labelText;
  final ValueChanged<ReplyAudience>? onChanged;

  @override
  Widget build(BuildContext context) {
    final onChanged = this.onChanged;
    return DropdownButtonFormField<ReplyAudience>(
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: labelText),
      selectedItemBuilder: (_) => [
        for (final audience in ReplyAudience.values)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Text(
              audience.optionLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      items: [
        for (final audience in ReplyAudience.values)
          DropdownMenuItem(value: audience, child: Text(audience.optionLabel)),
      ],
      onChanged: onChanged == null ? null : (value) => onChanged(value!),
    );
  }
}

/// Clips input to [max] code points (the unit the server counts).
class _CodePointLimit extends TextInputFormatter {
  _CodePointLimit(this.max);
  final int max;
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) => newValue.text.runes.length <= max ? newValue : oldValue;
}
