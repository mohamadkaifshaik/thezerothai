import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../gen/dzeroth/communities/v1/communities.pb.dart' as pb;
import '../../../shared/widgets/primitives/app_form_header.dart';
import '../../../shared/widgets/primitives/app_main_column.dart';
import '../../../shared/widgets/primitives/character_counter.dart';
import '../data/communities_repository.dart';
import '../domain/communities_feature_flag.dart';
import '../domain/community_text_rules.dart';
import 'bloc/create_community_cubit.dart';

/// `/communities/new` (W5-31): name, description and a rules editor (up to
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

  @override
  void initState() {
    super.initState();
    _name.addListener(_changed);
    _description.addListener(_changed);
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    for (final r in _rules) {
      r.dispose();
    }
    _cubit.close();
    super.dispose();
  }

  void _changed() => setState(() {});

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

  Widget _counter(TextEditingController c, int max) =>
      CharacterCounter(remaining: max - communityTextLength(c.text));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
                    title: 'Create a Community',
                    actionLabel: 'Create',
                    busy: busy,
                    busySemanticsLabel: 'Creating Community',
                    onCancel: _cancel,
                    onAction: _canCreate && !busy ? _create : null,
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(AppSpacing.md),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          TextField(
                            controller: _name,
                            enabled: !busy,
                            textInputAction: TextInputAction.next,
                            decoration: InputDecoration(
                              labelText: 'Name',
                              errorText: communityFieldError(
                                communityNameIssue(_name.text),
                                max: kCommunityNameMaxLength,
                              ),
                              counter: _counter(_name, kCommunityNameMaxLength),
                            ),
                          ),
                          const SizedBox(height: AppSpacing.md),
                          TextField(
                            controller: _description,
                            enabled: !busy,
                            minLines: 2,
                            maxLines: 4,
                            decoration: InputDecoration(
                              labelText: 'Description',
                              errorText: communityFieldError(
                                communityDescriptionIssue(_description.text),
                                max: kCommunityDescriptionMaxLength,
                              ),
                              counter: _counter(
                                _description,
                                kCommunityDescriptionMaxLength,
                              ),
                            ),
                          ),
                          const SizedBox(height: AppSpacing.lg),
                          Semantics(
                            header: true,
                            child: Text(
                              'Rules',
                              style: theme.textTheme.titleMedium,
                            ),
                          ),
                          const SizedBox(height: AppSpacing.xs),
                          Text(
                            'Optional. Up to $kMaxCommunityRules rules, shown '
                            'in the order you add them.',
                            style: theme.textTheme.bodyMedium?.copyWith(
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
                          const SizedBox(height: AppSpacing.sm),
                          Align(
                            alignment: AlignmentDirectional.centerStart,
                            child: TextButton.icon(
                              onPressed:
                                  busy || _rules.length >= kMaxCommunityRules
                                  ? null
                                  : _addRule,
                              icon: const Icon(Icons.add),
                              label: Text(
                                _rules.length >= kMaxCommunityRules
                                    ? 'Most rules added '
                                          '($kMaxCommunityRules)'
                                    : 'Add a rule',
                              ),
                            ),
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
      padding: const EdgeInsets.only(top: AppSpacing.md),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          border: Border.all(color: theme.colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      'Rule $number',
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Remove rule $number',
                  icon: const Icon(Icons.close),
                  onPressed: enabled ? onRemove : null,
                ),
              ],
            ),
            TextField(
              controller: fields.title,
              enabled: enabled,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: 'Rule $number title',
                errorText: communityFieldError(
                  communityRuleTitleIssue(fields.title.text),
                  max: kCommunityRuleTitleMaxLength,
                ),
                counter: counter(fields.title, kCommunityRuleTitleMaxLength),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: fields.text,
              enabled: enabled,
              minLines: 2,
              maxLines: 5,
              decoration: InputDecoration(
                labelText: 'Rule $number details',
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
