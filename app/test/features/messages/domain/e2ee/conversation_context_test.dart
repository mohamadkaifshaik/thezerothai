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
}
