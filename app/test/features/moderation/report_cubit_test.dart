import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/moderation/data/moderation_repository.dart';
import 'package:dzeroth/features/moderation/presentation/bloc/report_cubit.dart';
import 'package:dzeroth/gen/dzeroth/moderation/v1/moderation.pbenum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:uuid/data.dart';
import 'package:uuid/uuid.dart';

class MockModerationRepository extends Mock implements ModerationRepository {}

class _SeqUuid extends Uuid {
  int minted = 0;

  @override
  String v4({Map<String, dynamic>? options, V4Options? config}) =>
      'key-${++minted}';
}

void main() {
  late MockModerationRepository repo;
  late _SeqUuid uuid;
  late List<Object> unexpected;

  setUpAll(() {
    registerFallbackValue(ReportTargetType.REPORT_TARGET_TYPE_POST);
    registerFallbackValue(ReportReason.REPORT_REASON_SPAM);
  });

  setUp(() {
    repo = MockModerationRepository();
    uuid = _SeqUuid();
    unexpected = [];
  });

  ReportCubit build() => ReportCubit(
    repository: repo,
    targetType: ReportTargetType.REPORT_TARGET_TYPE_POST,
    targetId: '1234567890123456789',
    onUnexpectedError: (e, _) => unexpected.add(e),
    uuid: uuid,
  );

  When<Future<ReportReceipt>> stubReport() => when(
    () => repo.report(
      idempotencyKey: any(named: 'idempotencyKey'),
      targetType: any(named: 'targetType'),
      targetId: any(named: 'targetId'),
      reason: any(named: 'reason'),
      note: any(named: 'note'),
    ),
  );

  List<String> keysSent() => verify(
    () => repo.report(
      idempotencyKey: captureAny(named: 'idempotencyKey'),
      targetType: any(named: 'targetType'),
      targetId: any(named: 'targetId'),
      reason: any(named: 'reason'),
      note: any(named: 'note'),
    ),
  ).captured.cast<String>();

  test('cannot submit without a reason', () async {
    final cubit = build();
    addTearDown(cubit.close);

    expect(cubit.state.canSubmit, isFalse);
    await cubit.submit();

    verifyNever(
      () => repo.report(
        idempotencyKey: any(named: 'idempotencyKey'),
        targetType: any(named: 'targetType'),
        targetId: any(named: 'targetId'),
        reason: any(named: 'reason'),
        note: any(named: 'note'),
      ),
    );
  });

  test('a note over 500 code points blocks submit', () {
    final cubit = build();
    addTearDown(cubit.close);
    cubit.selectReason(ReportReason.REPORT_REASON_SPAM);

    cubit.noteChanged('a' * 501);
    expect(cubit.state.noteRemaining, -1);
    expect(cubit.state.canSubmit, isFalse);

    cubit.noteChanged('a' * 500);
    expect(cubit.state.canSubmit, isTrue);
  });

  test('success sends the trimmed note and marks sent', () async {
    stubReport().thenAnswer(
      (_) async => const ReportReceipt(reportId: 'r1', alreadyReported: false),
    );
    final cubit = build();
    addTearDown(cubit.close);
    cubit.selectReason(ReportReason.REPORT_REASON_HARASSMENT);
    cubit.noteChanged('  rude  ');

    await cubit.submit();

    expect(cubit.state.sent, isTrue);
    expect(cubit.state.alreadyReported, isFalse);
    expect(cubit.state.submitting, isFalse);
    verify(
      () => repo.report(
        idempotencyKey: 'key-1',
        targetType: ReportTargetType.REPORT_TARGET_TYPE_POST,
        targetId: '1234567890123456789',
        reason: ReportReason.REPORT_REASON_HARASSMENT,
        note: 'rude',
      ),
    ).called(1);
  });

  test('alreadyReported is surfaced', () async {
    stubReport().thenAnswer(
      (_) async => const ReportReceipt(reportId: 'r1', alreadyReported: true),
    );
    final cubit = build();
    addTearDown(cubit.close);
    cubit.selectReason(ReportReason.REPORT_REASON_SPAM);

    await cubit.submit();

    expect(cubit.state.sent, isTrue);
    expect(cubit.state.alreadyReported, isTrue);
  });

  test('a retry after a failure reuses the idempotency key', () async {
    var fail = true;
    stubReport().thenAnswer((_) async {
      if (fail) throw const NetworkException('offline');
      return const ReportReceipt(reportId: 'r1', alreadyReported: false);
    });
    final cubit = build();
    addTearDown(cubit.close);
    cubit.selectReason(ReportReason.REPORT_REASON_SPAM);

    await cubit.submit();
    expect(cubit.state.error, isA<NetworkException>());
    expect(cubit.state.sent, isFalse);

    fail = false;
    await cubit.submit();

    expect(cubit.state.sent, isTrue);
    expect(cubit.state.error, isNull);
    expect(keysSent(), ['key-1', 'key-1']);
    expect(uuid.minted, 1, reason: 'one key minted for the one intent');
  });

  test('editing the reason or the note after a failure starts a new intent '
      'with a new key', () async {
    stubReport().thenAnswer((_) async => throw const NetworkException('off'));
    final cubit = build();
    addTearDown(cubit.close);
    cubit.selectReason(ReportReason.REPORT_REASON_SPAM);
    await cubit.submit();

    cubit.selectReason(ReportReason.REPORT_REASON_HATE);
    expect(cubit.state.error, isNull, reason: 'an edit clears the error');
    await cubit.submit();

    cubit.noteChanged('more detail');
    await cubit.submit();

    expect(keysSent(), ['key-1', 'key-2', 'key-3']);
  });

  test('an unexpected error is reported and shown generically', () async {
    stubReport().thenAnswer((_) async => throw const UnknownApiException('x'));
    final cubit = build();
    addTearDown(cubit.close);
    cubit.selectReason(ReportReason.REPORT_REASON_SPAM);

    await cubit.submit();

    expect(unexpected, hasLength(1));
    expect(cubit.state.error, isA<UnknownApiException>());
    expect(cubit.state.submitting, isFalse);
  });

  test('edits are ignored once sent', () async {
    stubReport().thenAnswer(
      (_) async => const ReportReceipt(reportId: 'r1', alreadyReported: false),
    );
    final cubit = build();
    addTearDown(cubit.close);
    cubit.selectReason(ReportReason.REPORT_REASON_SPAM);
    await cubit.submit();

    cubit.selectReason(ReportReason.REPORT_REASON_HATE);

    expect(cubit.state.reason, ReportReason.REPORT_REASON_SPAM);
  });
}
