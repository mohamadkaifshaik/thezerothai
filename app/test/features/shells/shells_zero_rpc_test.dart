import 'dart:io';

import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/shells/domain/shell_entries.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/shells_harness.dart';
import '../../support/theme_harness.dart';

/// W8-8: the "0 RPCs, 0 reads" claim of the plan's Cost section.
///
/// The harness (`pumpShellsApp`) provides **no repository, no `ApiClient` and
/// no generated client** above the real router, so a page that read one would
/// throw `ProviderNotFoundException` at build time. On top of that, the blocs
/// the pages could use to start a `GetMe` (the only RPC near them) are mocks
/// that must never receive an event. The structural tests keep it true as the
/// files change.
void main() {
  setUpAll(() {
    registerFallbackValue(const OnboardingUserSignedOut());
    registerFallbackValue(const AuthSubscriptionRequested());
  });

  final pages = {
    'Creator tools': AppRouter.creatorStudioPath,
    'Advertise': AppRouter.advertisePath,
    'Calls': AppRouter.callsPath,
  };

  for (final width in kMatrixWidths) {
    for (final entry in pages.entries) {
      shellsTest('${entry.key} at ${width.toInt()}dp: no repository, no '
          'event, no error', (tester) async {
        final app = await pumpShellsApp(
          tester,
          location: entry.value,
          size: Size(width, 900),
        );
        // Settle: nothing is scheduled after the first frame either.
        await tester.pump(const Duration(minutes: 1));
        await tester.pumpAndSettle();

        expect(app.path, entry.value);
        expect(tester.takeException(), isNull);
        verifyNever(() => app.onboarding.add(any()));
        verifyNever(() => app.auth.add(any()));
      });
    }

    shellsTest('Premium pop-up at ${width.toInt()}dp: no repository, no '
        'event, no error', (tester) async {
      final app = await pumpShellsApp(tester, size: Size(width, 900));
      verifyNever(() => app.onboarding.add(any()));
      app.router.router.push(AppRouter.premiumPath, extra: kShellPushExtra);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(minutes: 1));
      await tester.pumpAndSettle();

      expect(app.path, AppRouter.premiumPath);
      expect(tester.takeException(), isNull);
      verifyNever(() => app.onboarding.add(any()));
      verifyNever(() => app.auth.add(any()));
    });
  }

  shellsTest('the entries (drawer, More menu) start nothing either', (
    tester,
  ) async {
    final app = await pumpShellsApp(tester, size: const Size(1200, 900));
    await tester.tap(find.bySemanticsLabel(RegExp(r'^More, menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Calls'));
    await tester.pumpAndSettle();
    expect(app.path, AppRouter.callsPath);
    verifyNever(() => app.onboarding.add(any()));
    verifyNever(() => app.auth.add(any()));
  });

  group('structural: nothing under features/shells reaches the network', () {
    final files = Directory('lib/features/shells')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList();
    String code(File f) => f
        .readAsLinesSync()
        .map((l) => l.replaceFirst(RegExp(r'//.*$'), ''))
        .join('\n');
    String imports(File f) => f
        .readAsLinesSync()
        .where((l) => RegExp(r'^\s*(import|export|part)\s').hasMatch(l))
        .join('\n');

    test('there are files to check', () {
      expect(files.length, greaterThanOrEqualTo(8));
    });

    test('no import of a data/ repository, ApiClient, a generated client '
        'or a connect/http/Firebase package', () {
      // Generated message types (`*.pb.dart`) are plain data and stay allowed
      // (Creator tools names `Profile` to read the counts already in memory);
      // generated service clients and specs are not.
      final forbidden = RegExp(
        r'/data/|api_client|\.connect\.|connectrpc|package:connect|'
        r'package:dio|package:http|cloud_firestore|firebase_functions|'
        r'firebase_storage|grpc|_repository\.dart',
      );
      for (final f in files) {
        final import = imports(f);
        expect(
          forbidden.firstMatch(import)?[0],
          isNull,
          reason: '${f.path} imports:\n$import',
        );
        // A generated import is only ever a `.pb.dart` message file.
        for (final line in import.split('\n')) {
          if (line.contains('gen/')) {
            expect(line, contains('.pb.dart'), reason: f.path);
          }
        }
      }
    });

    test('no use of a repository, ApiClient, transport or HTTP client', () {
      for (final f in files) {
        expect(
          RegExp(
            r'ApiClient|Repository\b|Transport\b|HttpClient|'
            r'context\.read<\w*(Repository|Client)',
          ).firstMatch(code(f))?[0],
          isNull,
          reason: f.path,
        );
      }
    });

    test(
      'the only bloc the shells read is the onboarding profile, read-only',
      () {
        final readers = <String>{};
        for (final f in files) {
          final c = code(f);
          // Nothing dispatches an event: no `.add(` on a bloc.
          expect(RegExp(r'\.add\(').hasMatch(c), isFalse, reason: f.path);
          // No `context.read` of anything (reading a repository or bloc).
          expect(
            RegExp(r'context\.read<').hasMatch(c),
            isFalse,
            reason: f.path,
          );
          for (final m in RegExp(
            r'(?:BlocSelector|BlocBuilder|BlocListener|BlocConsumer|'
            r'context\.(?:select|watch))<\s*(\w+)',
          ).allMatches(c)) {
            expect(m[1], 'OnboardingBloc', reason: f.path);
            readers.add(f.path);
          }
        }
        expect(readers, isNotEmpty, reason: 'Creator tools reads the profile');
      },
    );
  });
}
