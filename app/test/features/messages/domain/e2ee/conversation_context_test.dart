import 'package:dzeroth/features/messages/domain/e2ee/conversation_context.dart';
import 'package:flutter_test/flutter_test.dart';

/// The pass-scoped "listed to the end" fact of the final-attempt gate (step
/// 2b fix round 1): the smallest unit that holds it. A pass cannot meet a
/// retirement after its own reconcile step (only its probe retires, and the
/// probe runs first; passes of a conversation are single flight), so the
/// clearing is shown here.
void main() {
  test('a retirement after this pass\'s listing reached its end closes the '
      'final-attempt gate again', () {
    final context = ConversationContext();
    final pass = Object();
    context.noteListedToEnd(pass);
    expect(context.listedToEndIn(pass), isTrue);

    // What a retirement does: it clears the fact and writes the record.
    context
      ..clearListedToEnd()
      ..serial += 1;

    expect(context.listedToEndIn(pass), isFalse);
  });

  test('the fact is the noting pass\'s alone', () {
    final context = ConversationContext();
    final pass = Object();
    context.noteListedToEnd(pass);

    // The sink's own pass, or the public reconcile's.
    expect(context.listedToEndIn(Object()), isFalse);
    expect(context.listedToEndIn(pass), isTrue);
  });

  test('any write of the receive record after the listing\'s last page '
      'forgets the fact for good', () {
    final context = ConversationContext();
    final pass = Object();
    context.noteListedToEnd(pass);

    context.serial++;

    expect(context.listedToEndIn(pass), isFalse);
    // Not back when the serial is the noted one again.
    context.serial--;
    expect(context.listedToEndIn(pass), isFalse);
  });

  test('a pass that ends takes the fact with it', () {
    final context = ConversationContext();
    final pass = Object();
    context
      ..noteListedToEnd(pass)
      ..clearListedToEnd();

    expect(context.listedToEndIn(pass), isFalse);
  });

  // The freshness witness of a deferred message's engine call while no
  // reconcile entry stands (the whole-branch fix wave): this pass's probe
  // was answered for the stored, non-empty since token.
  group('the answered-probe witness', () {
    test('holds for the noting pass and the token its probe sent, and for no '
        'other pass or token', () {
      final context = ConversationContext();
      final pass = Object();
      expect(context.probeAnsweredIn(pass, 'token-a'), isFalse);

      context.noteProbeAnswered(pass, 'token-a');

      expect(context.probeAnsweredIn(pass, 'token-a'), isTrue);
      // The sink's own pass, or a later one.
      expect(context.probeAnsweredIn(Object(), 'token-a'), isFalse);
      // The stored token is another one, or was cleared by a retirement.
      expect(context.probeAnsweredIn(pass, 'token-b'), isFalse);
      expect(context.probeAnsweredIn(pass, ''), isFalse);
    });

    test('a probe that sent no since token is never a witness', () {
      final context = ConversationContext();
      final pass = Object();

      context.noteProbeAnswered(pass, '');

      expect(context.probeAnsweredIn(pass, ''), isFalse);
      expect(context.probeAnsweredIn(pass, 'token-a'), isFalse);
    });

    test('follows only the witnessed pass\'s own save over the witnessed '
        'token', () {
      final context = ConversationContext();
      final pass = Object();
      context.noteProbeAnswered(pass, 'token-a');

      // Another pass's save, a save over another token, and an empty token
      // move nothing.
      context
        ..noteSinceTokenSaved(Object(), 'token-a', 'token-b')
        ..noteSinceTokenSaved(pass, 'token-x', 'token-b')
        ..noteSinceTokenSaved(pass, 'token-a', '');
      expect(context.probeAnsweredIn(pass, 'token-a'), isTrue);
      expect(context.probeAnsweredIn(pass, 'token-b'), isFalse);

      context.noteSinceTokenSaved(pass, 'token-a', 'token-b');

      expect(context.probeAnsweredIn(pass, 'token-b'), isTrue);
      expect(context.probeAnsweredIn(pass, 'token-a'), isFalse);
    });

    test('a retirement or the end of the pass takes the witness with it', () {
      final context = ConversationContext();
      final pass = Object();
      context
        ..noteProbeAnswered(pass, 'token-a')
        ..clearProbeAnswered();

      expect(context.probeAnsweredIn(pass, 'token-a'), isFalse);
      // A save without a witness creates none.
      context.noteSinceTokenSaved(pass, 'token-a', 'token-b');
      expect(context.probeAnsweredIn(pass, 'token-b'), isFalse);
    });
  });
}
