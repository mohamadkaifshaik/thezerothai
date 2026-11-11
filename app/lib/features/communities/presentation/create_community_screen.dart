import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/context_pane.dart';
import '../../../core/widgets/context_pane_slots.dart';
import '../../../core/widgets/shell_geometry.dart';
import '../../../gen/dzeroth/communities/v1/communities.pb.dart' as pb;
import '../../../shared/widgets/primitives/app_dialog.dart';
import '../../../shared/widgets/primitives/app_card.dart';
import '../../../shared/widgets/primitives/app_form_header.dart';
import '../../../shared/widgets/primitives/app_main_column.dart';
import '../../../shared/widgets/primitives/app_pill_button.dart';
import '../../../shared/widgets/primitives/app_text_field.dart';
import '../../../shared/widgets/primitives/character_counter.dart';
import '../data/communities_repository.dart';
import '../domain/communities_feature_flag.dart';
import '../domain/community_text_rules.dart';
import 'bloc/create_community_cubit.dart';
import 'widgets/community_preview.dart';

/// `/communities/new`: name, description and a rules editor (up to
/// [kMaxCommunityRules], each a title and a text), and Create.
///
/// - 1 `CreateCommunity` per submit, one idempotency key per action (reused on
///   a retry, renewed when the payload changes).
/// - Limits are counted in code points after trim and NFC, as the server does
///   (`community_text_rules.dart`); the server stays authoritative and a
///   refusal (not a creator, the owned cap, validation) shows inline as its
///   friendly text with the form kept for a retry.
/// - On success it opens the new community's page.
/// - The route needs the `communities` flag. The entry on `/communities` is
///   shown only with the server's `can_create`; a direct visit by someone who
///   is not a creator gets the server's FORBIDDEN text on Create.
class CreateCommunityScreen extends StatefulWidget {
  const CreateCommunityScreen({super.key});

  @override
  State<CreateCommunityScreen> createState() => _CreateCommunityScreenState();
}

class _RuleFields {
  _RuleFields(this.id);

  /// Stable across reorders and removals (the row key).
  final int id;
  final title = TextEditingController();
  final text = TextEditingController();

  void dispose() {
    title.dispose();
    text.dispose();
  }
}

class _CreateCommunityScreenState extends State<CreateCommunityScreen> {
  late final CreateCommunityCubit _cubit = CreateCommunityCubit(
    repository: context.read<CommunitiesRepository>(),
  );
  final _name = TextEditingController();
  final _description = TextEditingController();
  final List<_RuleFields> _rules = [];
  var _nextRuleId = 0;

  /// The form as typed, for the preview (band B's context pane, band A's
  /// Preview dialog; T8a). Follows every field, rules added and removed.
  final _draft = ValueNotifier(const CommunityDraft());
  final _paneLease = ContextPaneLease();

  @override
  void initState() {
    super.initState();
    _name.addListener(_changed);
    _description.addListener(_changed);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _paneLease.attach(context, AppRouter.communityNewPath, {
      ContextSectionKind.communityPreview: (context) =>
          ValueListenableBuilder<CommunityDraft>(
            valueListenable: _draft,
            builder: (context, draft, _) => CommunityPreviewCard(draft: draft),
          ),
    });
  }

  @override
  void dispose() {
    _paneLease.dispose();
    _draft.dispose();
    _name.dispose();
    _description.dispose();
    for (final r in _rules) {
      r.dispose();
    }
    _cubit.close();
    super.dispose();
  }

  static const _previewTitle = kCommunityPreviewTitle;

  void _changed() {
    _syncDraft();
    setState(() {});
  }

  void _syncDraft() => _draft.value = CommunityDraft(
    name: _name.text.trim(),
    description: _description.text.trim(),
    rules: [
      for (final r in _rules)
        CommunityDraftRule(
          title: r.title.text.trim(),
          text: r.text.text.trim(),
        ),
    ],
  );

  /// Band A's Preview (tablet plan section 4.1: "header action that opens a
  /// Preview dialog"): a D 560 dialog on the content area that follows the
  /// form.
  void _openPreview() => showAppDialog<void>(
    context: context,
    maxWidth: AppSize.dialogMax,
    builder: (dialogContext) => AppDialog(
      title: _previewTitle,
      body: ValueListenableBuilder<CommunityDraft>(
        valueListenable: _draft,
        // The dialog pads its title and body already: the preview's lines
        // start where the title does.
        builder: (context, draft, _) =>
            CommunityPreview(draft: draft, inset: 0),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );

  void _cancel() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRouter.communitiesPath);
    }
  }

  void _addRule() {
    if (_rules.length >= kMaxCommunityRules) return;
    final rule = _RuleFields(_nextRuleId++);
    rule.title.addListener(_changed);
    rule.text.addListener(_changed);
    setState(() => _rules.add(rule));
  }

  void _removeRule(_RuleFields rule) {
    setState(() => _rules.remove(rule));
    rule.dispose();
    _syncDraft();
  }

  bool get _canCreate {
    if (communityNameIssue(_name.text) != null) return false;
    if (communityDescriptionIssue(_description.text) != null) return false;
    for (final r in _rules) {
      if (communityRuleTitleIssue(r.title.text) != null) return false;
      if (communityRuleTextIssue(r.text.text) != null) return false;
    }
    return true;
  }

  void _create() => _cubit.create(
    name: _name.text.trim(),
    description: _description.text.trim(),
    rules: [
      for (final r in _rules)
        pb.CommunityRule(title: r.title.text.trim(), text: r.text.text.trim()),
    ],
  );

  /// The design's "13 / 30": the used count against the limit.
  Widget _counter(TextEditingController c, int max) => CharacterCounter(
    remaining: max - communityTextLength(c.text),
    limit: max,
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Band A of the tablet layout: Preview in the header opens the dialog.
    // Band B shows the preview in the context pane instead; phones and
    // desktop keep today's header (ruling R-1).
    final tablet = ShellGeometry.maybeOf(context)?.tablet ?? false;
    final previewAction =
        tablet &&
        !ContextPaneScope.shows(context, ContextSectionKind.communityPreview);
    return Scaffold(
      body: SafeArea(
        child: AppMainColumn(
          child: BlocConsumer<CreateCommunityCubit, CreateCommunityState>(
            bloc: _cubit,
            listenWhen: (a, b) => a.created != b.created && b.created != null,
            listener: (context, state) => context.pushReplacement(
              AppRouter.communityPath(state.created!.communityId),
            ),
            builder: (context, state) {
              final busy = state.busy;
              return Column(
                children: [
                  AppFormHeader(
                    title: 'Create a community',
                    actionLabel: 'Create',
                    busy: busy,
                    busySemanticsLabel: 'Creating community',
                    onCancel: _cancel,
                    onAction: _canCreate && !busy ? _create : null,
                    secondaryLabel: previewAction ? _previewTitle : null,
                    onSecondary: previewAction ? _openPreview : null,
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      // dz: 16 dp above and below, 20 dp each side.
                      padding: const EdgeInsets.symmetric(
                        horizontal: _kFormInset,
                        vertical: AppSpacing.md,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          AppTextField(
                            label: 'Name',
                            kind: AppFieldKind.plain,
                            controller: _name,
                            enabled: !busy,
                            textInputAction: TextInputAction.next,
                            errorText: communityFieldError(
                              communityNameIssue(_name.text),
                              max: kCommunityNameMaxLength,
                            ),
                            counter: _counter(_name, kCommunityNameMaxLength),
                          ),
                          const SizedBox(height: AppSpacing.smd),
                          AppTextField(
                            label: 'Description',
                            kind: AppFieldKind.plain,
                            controller: _description,
                            enabled: !busy,
                            area: true,
                            minLines: 3,
                            maxLines: 6,
                            errorText: communityFieldError(
                              communityDescriptionIssue(_description.text),
                              max: kCommunityDescriptionMaxLength,
                            ),
                            counter: _counter(
                              _description,
                              kCommunityDescriptionMaxLength,
                            ),
                          ),
                          const SizedBox(height: AppSpacing.smd),
                          Semantics(
                            header: true,
                            // dz: a 13 w600 label in text2.
                            child: Text(
                              'Rules',
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: context.appColors.text2,
                              ),
                            ),
                          ),
                          const SizedBox(height: AppSpacing.xs),
                          Text(
                            'Optional. Up to $kMaxCommunityRules rules, shown '
                            'in the order you add them.',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          for (var i = 0; i < _rules.length; i++)
                            _RuleEditor(
                              key: ValueKey('rule-${_rules[i].id}'),
                              number: i + 1,
                              fields: _rules[i],
                              enabled: !busy,
                              counter: _counter,
                              onRemove: () => _removeRule(_rules[i]),
                            ),
                          const SizedBox(height: AppSpacing.smd),
                          AppPillButton(
                            label: _rules.length >= kMaxCommunityRules
                                ? 'Most rules added ($kMaxCommunityRules)'
                                : 'Add a rule',
                            variant: AppButtonVariant.outline,
                            onPressed:
                                busy || _rules.length >= kMaxCommunityRules
                                ? null
                                : _addRule,
                          ),
                          if (state.error != null) ...[
                            const SizedBox(height: AppSpacing.md),
                            Semantics(
                              liveRegion: true,
                              child: Text(
                                state.error!,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.error,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// The form's side inset (dz `20px`).
const double _kFormInset = 20;

/// One rule: an [AppCard] with its "RULE n" eyebrow, a remove button (a 48 dp
/// target) and its two fields (the design's card shows the rule read-only;
/// here it is where the rule is written).
class _RuleEditor extends StatelessWidget {
  const _RuleEditor({
    super.key,
    required this.number,
    required this.fields,
    required this.enabled,
    required this.counter,
    required this.onRemove,
  });

  final int number;
  final _RuleFields fields;
  final bool enabled;
  final Widget Function(TextEditingController, int) counter;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.smd),
      child: AppCard(
        padding: const EdgeInsets.fromLTRB(14, 6, 6, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Semantics(
                    header: true,
                    label: 'Rule $number',
                    excludeSemantics: true,
                    // dz: the eyebrow, in the accent text colour.
                    child: Text(
                      'Rule $number'.toUpperCase(),
                      style: AppTextStyles.eyebrow(theme)
                          .copyWith(color: context.appColors.accentText),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Remove rule $number',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: enabled ? onRemove : null,
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 8),
              child: AppTextField(
                label: 'Rule $number title',
                kind: AppFieldKind.plain,
                controller: fields.title,
                enabled: enabled,
                textInputAction: TextInputAction.next,
                errorText: communityFieldError(
                  communityRuleTitleIssue(fields.title.text),
                  max: kCommunityRuleTitleMaxLength,
                ),
                counter: counter(fields.title, kCommunityRuleTitleMaxLength),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 8),
              child: AppTextField(
                label: 'Rule $number details',
                kind: AppFieldKind.plain,
                controller: fields.text,
                enabled: enabled,
                area: true,
                minLines: 2,
                maxLines: 5,
                errorText: communityFieldError(
                  communityRuleTextIssue(fields.text.text),
                  max: kCommunityRuleTextMaxLength,
                ),
                counter: counter(fields.text, kCommunityRuleTextMaxLength),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
