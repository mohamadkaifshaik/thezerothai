import 'package:flutter/material.dart';

import '../../domain/post_text_rules.dart';

/// Explains why Post is disabled when it is not just "nothing typed yet".
/// Shared by the composer screen and the thread's reply field. Renders an
/// [Expanded], so place it in a `Row`.
class DraftProblemHint extends StatelessWidget {
  const DraftProblemHint({super.key, required this.problem});

  final PostDraftProblem? problem;

  @override
  Widget build(BuildContext context) {
    final message = switch (problem) {
      PostDraftProblem.tooManyLines => 'Posts can have at most 10 lines.',
      PostDraftProblem.forbiddenCharacter =>
        'Remove the unsupported characters.',
      _ => null,
    };
    if (message == null) return const SizedBox.shrink();
    return Expanded(
      child: Text(
        message,
        style: Theme.of(context).textTheme.bodySmall
            ?.copyWith(color: Theme.of(context).colorScheme.error),
      ),
    );
  }
}
