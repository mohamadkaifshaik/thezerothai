import 'dart:async';

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encryption_access.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/conversation_encryption_panel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../../../support/fake_encrypted_messaging.dart';

const _id = 'c1';
final _digits = '1234567890' * 6;
final _other = '0987654321' * 6;

/// A port whose `securityCode` answers are held by the test, in call order.
/// The answer is read when the call is made (before the wait), as the real
/// port reads the vault, so a late answer is a stale one.
class _HeldMessaging extends FakeEncryptedMessaging {
  final List<Completer<void>> gates = [];

  /// Thrown by the next call that waited on a gate, after the wait.
  Object? failAfterGate;

  @override
  Future<SecurityCode> securityCode(String conversationId) async {
    final answer = await super.securityCode(conversationId);
    if (gates.isNotEmpty) {
      await gates.removeAt(0).future;
      final late = failAfterGate;
      failAfterGate = null;
      if (late != null) throw late;
    }
    return answer;
  }
}

void main() {
  late _HeldMessaging port;
  late List<Object> reported;

  setUp(() {
    port = _HeldMessaging();
    reported = [];
  });

  SecurityCodeCubit make() => SecurityCodeCubit(
    messaging: port,
    conversationId: _id,
    onUnexpectedError: (e, _) => reported.add(e),
  );

  test('load emits loading then ready with the code', () async {
    port.setSecurityCode(
      _id,
      SecurityCode(digits: _digits, myDevices: 1, theirDevices: 2),
    );
    final cubit = make();
    final seen = <SecurityCodeState>[];
    final sub = cubit.stream.listen(seen.add);
    await cubit.load();
    await Future<void>.delayed(Duration.zero);
    expect(seen.map((s) => s.status), [
      SecurityCodeStatus.loading,
      SecurityCodeStatus.ready,
    ]);
    expect(seen.last.code!.digits, _digits);
    expect(seen.last.code!.theirDevices, 2);
    await sub.cancel();
    await cubit.close();
  });

  test('a thrown error is failed and is reported without details', () async {
    port.failNextOn('securityCode', StateError('secret $_digits'));
    final cubit = make();
    await cubit.load();
    expect(cubit.state.status, SecurityCodeStatus.failed);
    expect(cubit.state.code, isNull);
    expect(reported, hasLength(1));
    expect(reported.single, isA<StateError>());
    expect(
      (reported.single as StateError).message,
      isNot(contains(_digits)),
      reason: 'the reported error carries none of the thrown text',
    );
    await cubit.close();
  });

  test('a NetworkException is failed and says so, unreported', () async {
    port.failNextOn('securityCode', const NetworkException('offline'));
    final cubit = make();
    await cubit.load();
    expect(cubit.state.status, SecurityCodeStatus.failed);
    expect(cubit.state.failureText, isNotNull);
    expect(reported, isEmpty);
    await cubit.close();
  });

  test('a second load supersedes the first', () async {
    port.setSecurityCode(_id, SecurityCode(digits: _digits));
    final gate = Completer<void>();
    port.gates.add(gate);
    final cubit = make();
    final first = cubit.load();
    await Future<void>.delayed(Duration.zero);
    // The code changed; the second call answers at once.
    port.setSecurityCode(_id, SecurityCode(digits: _other));
    await cubit.load();
    expect(cubit.state.code!.digits, _other);
    gate.complete();
    await first;
    expect(
      cubit.state.code!.digits,
      _other,
      reason: 'the first answer arrived late and is dropped',
    );
    await cubit.close();
  });

  test('a late error of the first load is dropped too', () async {
    port.setSecurityCode(_id, SecurityCode(digits: _digits));
    port.failAfterGate = StateError('x');
    final gate = Completer<void>();
    port.gates.add(gate);
    final cubit = make();
    final first = cubit.load();
    await Future<void>.delayed(Duration.zero);
    await cubit.load();
    gate.complete();
    await first;
    expect(cubit.state.status, SecurityCodeStatus.ready);
    expect(reported, isEmpty);
    await cubit.close();
  });

  test('a reload shows loading again, with no code', () async {
    port.setSecurityCode(_id, SecurityCode(digits: _digits));
    final cubit = make();
    await cubit.load();
    final gate = Completer<void>();
    port.gates.add(gate);
    final again = cubit.load();
    expect(cubit.state.status, SecurityCodeStatus.loading);
    expect(cubit.state.code, isNull);
    gate.complete();
    await again;
    await cubit.close();
  });

  test('closing while a load waits emits nothing and throws nothing', () async {
    final gate = Completer<void>();
    port.gates.add(gate);
    final cubit = make();
    final pending = cubit.load();
    await Future<void>.delayed(Duration.zero);
    await cubit.close();
    gate.complete();
    await pending;
  });

  testWidgets('a security change triggers one reload', (tester) async {
    port.setSecurityCode(_id, SecurityCode(digits: _digits));
    final changes = StreamController<ConversationSecurity?>.broadcast();
    addTearDown(changes.close);
    await tester.pumpWidget(
      MaterialApp(
        theme: appLightTheme,
        home: Scaffold(
          body: ConversationEncryptionHost(
            messaging: port,
            conversationId: _id,
            peerName: 'Sam',
            access: EncryptionAccess.full,
            initialSecurity: const ConversationSecurity(
              state: ConversationEncryptionState.ready,
              myDevices: 1,
              theirDevices: 1,
            ),
            securityChanges: changes.stream,
            isWeb: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    int loads() => port.calls.where((c) => c == 'securityCode').length;
    expect(loads(), 1, reason: 'one load when the panel opens');

    // The same state and counts again: nothing.
    changes.add(
      const ConversationSecurity(
        state: ConversationEncryptionState.ready,
        myDevices: 1,
        theirDevices: 1,
      ),
    );
    await tester.pumpAndSettle();
    expect(loads(), 1);

    // A different count: one reload.
    changes.add(
      const ConversationSecurity(
        state: ConversationEncryptionState.ready,
        myDevices: 1,
        theirDevices: 2,
      ),
    );
    await tester.pumpAndSettle();
    expect(loads(), 2);

    // A different state: one reload.
    changes.add(
      const ConversationSecurity(
        state: ConversationEncryptionState.unknownDevice,
        myDevices: 1,
        theirDevices: 2,
      ),
    );
    await tester.pumpAndSettle();
    expect(loads(), 3);
  });
}
