import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../../app/session_wiring.dart' show UnexpectedErrorReporter;
import '../../../../core/feature_flags/feature_flags.dart';
import '../../../../core/feature_flags/ui_shell_feature_flag.dart';
import '../../../../core/network/app_exception.dart';
import '../../../../core/router/app_router.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/shell_geometry.dart';
import '../../../../shared/widgets/primitives/app_dialog.dart';
import '../../../../shared/widgets/primitives/app_pill_button.dart';
import '../../../../shared/widgets/primitives/app_sheet.dart';
import '../../../../shared/widgets/primitives/app_side_sheet.dart';
import '../../domain/e2ee/encrypted_messaging.dart';
import '../../domain/e2ee/encryption_access.dart';
import 'encryption_access_builder.dart';
import 'encryption_copy.dart';
import 'encryption_error_messages.dart';
import 'widgets/conversation_encryption_note.dart';

/// The 60 digits as 12 groups of 5.
List<String> securityCodeGroups(String digits) => [
  for (var i = 0; i + 5 <= digits.length; i += 5) digits.substring(i, i + 5),
];

enum SecurityCodeStatus { loading, ready, failed }

/// The state of the panel's code. A plain class with no text form: [code]
/// carries the digits and the device counts.
@immutable
class SecurityCodeState {
  const SecurityCodeState({
    this.status = SecurityCodeStatus.loading,
    this.code,
    this.failureText,
  });

  final SecurityCodeStatus status;
  final SecurityCode? code;

  /// The friendly text of a failure that says more than the generic line
  /// (offline); null for the generic one.
  final String? failureText;
}

/// Loads the security code of one conversation. The code is held only here:
/// it is not logged, put in a URL or kept after the panel closes.
class SecurityCodeCubit extends Cubit<SecurityCodeState> {
  SecurityCodeCubit({
    required EncryptedMessaging messaging,
    required String conversationId,
    this.onUnexpectedError,
  }) : _messaging = messaging,
       _conversationId = conversationId,
       super(const SecurityCodeState());

  final EncryptedMessaging _messaging;
  final String _conversationId;
  final UnexpectedErrorReporter? onUnexpectedError;
  int _generation = 0;

  /// Shows `loading` (no code), then the answer. An answer (or error) of an
  /// older request is dropped.
  Future<void> load() async {
    final mine = ++_generation;
    emit(const SecurityCodeState());
    try {
      final code = await _messaging.securityCode(_conversationId);
      if (mine != _generation || isClosed) return;
      emit(SecurityCodeState(status: SecurityCodeStatus.ready, code: code));
    } catch (error, stack) {
      if (mine != _generation || isClosed) return;
      if (error is NetworkException) {
        emit(
          SecurityCodeState(
            status: SecurityCodeStatus.failed,
            failureText: encryptionErrorMessage(error),
          ),
        );
        return;
      }
      // Reported without the thrown object: nothing of the conversation.
      onUnexpectedError?.call(StateError('securityCode'), stack);
      emit(const SecurityCodeState(status: SecurityCodeStatus.failed));
    }
  }
}

bool _securityChanged(ConversationSecurity? a, ConversationSecurity? b) {
  if (a == null || b == null) return (a == null) != (b == null);
  return a.state != b.state ||
      a.myDevices != b.myDevices ||
      a.theirDevices != b.theirDevices;
}

/// Opens the panel of [conversationId] in the presentation of the layout:
/// phone (< 600): a full-height bottom sheet; the tablet layout (600-1199 dp
/// with `ui_shell` and `ui_tablet`): the side sheet; desktop (>= 1200): a
/// dialog 560 dp wide at most. The same content and actions in all three.
///
/// [securityChanges] is the thread's security: the code reloads whenever it
/// emits another state or other device counts than the last one seen
/// ([initialSecurity] seeds that). The port, the access, the platform and
/// the presentation are read from [context] unless given. Nothing is shown
/// without a port or with access `hidden`.
Future<void> showConversationEncryption(
  BuildContext context, {
  required String conversationId,
  required String peerName,
  required Stream<ConversationSecurity?> securityChanges,
  ConversationSecurity? initialSecurity,
  EncryptedMessaging? messaging,
  EncryptionAccess? access,
  bool? isWeb,
  bool? tabletLayout,
}) {
  final resolvedAccess = access ?? EncryptionAccessBuilder.of(context);
  final port =
      messaging ??
      (resolvedAccess == EncryptionAccess.hidden
          ? null
          : context.read<EncryptedMessaging?>());
  if (port == null || resolvedAccess == EncryptionAccess.hidden) {
    return Future<void>.value();
  }
  UnexpectedErrorReporter? report;
  try {
    report = context.read<UnexpectedErrorReporter?>();
  } on ProviderNotFoundException {
    report = null;
  }
  final router = GoRouter.maybeOf(context);
  final width = MediaQuery.sizeOf(context).width;
  final band = ShellBand.of(width);
  final tablet =
      tabletLayout ??
      (band.isTablet &&
          featureEnabledSnapshot(context, kFeatureUiShell) &&
          featureEnabledSnapshot(context, kFeatureUiTablet));
  Widget host() => ConversationEncryptionHost(
    messaging: port,
    conversationId: conversationId,
    peerName: peerName,
    access: resolvedAccess,
    securityChanges: securityChanges,
    initialSecurity: initialSecurity,
    isWeb: isWeb ?? kIsWeb,
    router: router,
    onUnexpectedError: report,
  );
  if (tablet) {
    return showAppSideSheet<void>(
      context: context,
      semanticLabel: kEncryptionEntryLabel,
      builder: (_) => host(),
    );
  }
  if (band == ShellBand.desktop) {
    return showAppDialog<void>(
      context: context,
      maxWidth: AppSize.dialogMax,
      builder: (_) => Semantics(
        scopesRoute: true,
        namesRoute: true,
        explicitChildNodes: true,
        label: kEncryptionEntryLabel,
        child: host(),
      ),
    );
  }
  return showAppSheet<void>(
    context: context,
    semanticLabel: kEncryptionEntryLabel,
    builder: (_) => SizedBox(height: double.infinity, child: host()),
  );
}

/// Owns the cubit and the subscription of one open panel.
class ConversationEncryptionHost extends StatefulWidget {
  const ConversationEncryptionHost({
    super.key,
    required this.messaging,
    required this.conversationId,
    required this.peerName,
    required this.access,
    required this.securityChanges,
    this.initialSecurity,
    this.isWeb = kIsWeb,
    this.router,
    this.onUnexpectedError,
  });

  final EncryptedMessaging messaging;
  final String conversationId;
  final String peerName;
  final EncryptionAccess access;
  final Stream<ConversationSecurity?> securityChanges;
  final ConversationSecurity? initialSecurity;
  final bool isWeb;
  final GoRouter? router;
  final UnexpectedErrorReporter? onUnexpectedError;

  @override
  State<ConversationEncryptionHost> createState() =>
      _ConversationEncryptionHostState();
}

class _ConversationEncryptionHostState
    extends State<ConversationEncryptionHost> {
  late final SecurityCodeCubit _cubit;
  StreamSubscription<ConversationSecurity?>? _subscription;
  ConversationSecurity? _last;

  @override
  void initState() {
    super.initState();
    _last = widget.initialSecurity;
    _cubit = SecurityCodeCubit(
      messaging: widget.messaging,
      conversationId: widget.conversationId,
      onUnexpectedError: widget.onUnexpectedError,
    );
    unawaited(_cubit.load());
    _subscription = widget.securityChanges.listen((next) {
      if (!_securityChanged(_last, next)) return;
      _last = next;
      unawaited(_cubit.load());
    });
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    unawaited(_cubit.close());
    super.dispose();
  }

  void _checkDevices() {
    final router = widget.router ?? GoRouter.maybeOf(context);
    Navigator.of(context).pop();
    if (router != null) {
      unawaited(router.push<void>(AppRouter.encryptionSettingsPath));
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider<SecurityCodeCubit>.value(
      value: _cubit,
      child: ConversationEncryptionPanel(
        peerName: widget.peerName,
        access: widget.access,
        isWeb: widget.isWeb,
        onCheckDevices: _checkDevices,
      ),
    );
  }
}

/// The content of the panel, presentation-agnostic: the title, then (top to
/// bottom) the encryption note, the security code with its limits, the
/// device counts, the link to the device list and the help. Reads the
/// [SecurityCodeCubit] above it.
class ConversationEncryptionPanel extends StatelessWidget {
  const ConversationEncryptionPanel({
    super.key,
    required this.peerName,
    required this.access,
    required this.onCheckDevices,
    this.isWeb = kIsWeb,
  });

  final String peerName;
  final EncryptionAccess access;

  /// Closes the panel and opens the device list; null hides the link.
  final VoidCallback? onCheckDevices;
  final bool isWeb;

  static const _helpBeforeWeb = [
    kEncryptionHelp1,
    kEncryptionHelp2,
    kEncryptionHelp3,
  ];
  static const _helpAfterWeb = [
    kEncryptionHelp4,
    kEncryptionHelp5,
    kEncryptionHelp6,
    kEncryptionHelp7,
    kEncryptionHelp8,
    kEncryptionHelp9,
    kEncryptionHelp10,
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const AppSideSheetHeader(title: kEncryptionEntryLabel),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.sm,
              AppSpacing.md,
              AppSpacing.lg,
            ),
            child: BlocBuilder<SecurityCodeCubit, SecurityCodeState>(
              builder: (context, state) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const ConversationEncryptionNote(encrypted: true),
                  const SizedBox(height: AppSpacing.md),
                  if (!_pending(state)) ..._code(context, theme, state),
                  _header(theme, kEncryptionHowItWorksLabel),
                  for (final line in _helpBeforeWeb) _help(theme, line),
                  if (isWeb) _help(theme, kEncryptionHelpWeb),
                  for (final line in _helpAfterWeb) _help(theme, line),
                  if (isWeb) _help(theme, kWebStorageNote),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  bool _pending(SecurityCodeState state) =>
      state.code?.reason == NoCodeReason.pendingRequest;

  Widget _header(ThemeData theme, String text) => Padding(
    padding: const EdgeInsets.only(top: AppSpacing.md, bottom: AppSpacing.sm),
    child: Semantics(
      header: true,
      child: Text(text, style: theme.textTheme.titleMedium),
    ),
  );

  Widget _help(ThemeData theme, String text) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
    child: Text(
      text,
      style: theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    ),
  );

  Widget _line(ThemeData theme, String text, {bool live = false}) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
    child: Semantics(
      liveRegion: live,
      child: Text(text, style: theme.textTheme.bodyMedium),
    ),
  );

  List<Widget> _code(
    BuildContext context,
    ThemeData theme,
    SecurityCodeState state,
  ) {
    final code = state.code;
    final digits = code?.digits;
    final reason = code?.reason;
    final width = MediaQuery.sizeOf(context).width;
    final desktop = width >= AppBreakpoints.tablet;
    final figure = desktop
        ? 20.0
        : width >= AppBreakpoints.mobile
        ? 16.0
        : 18.0;
    final showCounts =
        code != null &&
        (digits != null ||
            reason == NoCodeReason.unknownDevice ||
            reason == NoCodeReason.listUnverifiable);
    return [
      _header(theme, kSecurityCodeHeader),
      switch (state.status) {
        SecurityCodeStatus.loading => const _CodeSkeleton(),
        SecurityCodeStatus.failed => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _line(theme, state.failureText ?? kSecurityCodeFailed, live: true),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: AppPillButton(
                label: kStatusTryAgain,
                variant: AppButtonVariant.outline,
                onPressed: () => context.read<SecurityCodeCubit>().load(),
              ),
            ),
          ],
        ),
        SecurityCodeStatus.ready when digits != null => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _line(theme, securityCodeIntro(peerName)),
            _CodeGrid(
              digits: digits,
              figureSize: figure,
              maxWidth: desktop ? 360 : double.infinity,
            ),
            const SizedBox(height: AppSpacing.sm),
            _line(theme, kSecurityCodeMeaning),
            _line(theme, kSecurityCodeMoment),
          ],
        ),
        SecurityCodeStatus.ready => _line(
          theme,
          _noCodeText(reason),
          live: true,
        ),
      },
      if (showCounts) ...[
        _line(theme, securityCodeMine(code.myDevices)),
        _line(theme, securityCodeTheirs(code.theirDevices)),
      ],
      if (onCheckDevices != null && access != EncryptionAccess.unsupported)
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton(
            style: TextButton.styleFrom(
              minimumSize: const Size(0, AppSpacing.minTapTarget),
            ),
            onPressed: onCheckDevices,
            child: const Text(kOwnDeviceAlertAction),
          ),
        ),
    ];
  }

  String _noCodeText(NoCodeReason? reason) => switch (reason) {
    NoCodeReason.sentRequest => kNoCodeSentRequest,
    NoCodeReason.notAMember => kNoCodeNotAMember,
    NoCodeReason.unknownDevice => kNoCodeUnknownDevice,
    NoCodeReason.listUnverifiable => kNoCodeUnverifiable,
    _ => kNoCodeUnavailable,
  };
}

/// Twelve quiet blocks while the code loads.
class _CodeSkeleton extends StatelessWidget {
  const _CodeSkeleton();

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.surfaceContainerHighest;
    return Semantics(
      label: kSecurityCodeLoading,
      liveRegion: true,
      excludeSemantics: true,
      child: Column(
        children: [
          for (var row = 0; row < 4; row++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
              child: Row(
                children: [
                  for (var col = 0; col < 3; col++) ...[
                    if (col > 0) const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(AppRadius.sm),
                        ),
                        child: const SizedBox(height: AppSpacing.lg),
                      ),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The 12 groups, row by row, 3 columns (2 when 3 do not fit at the text
/// scale in effect). Plain `Text`, never selectable.
class _CodeGrid extends StatelessWidget {
  const _CodeGrid({
    required this.digits,
    required this.figureSize,
    required this.maxWidth,
  });

  final String digits;
  final double figureSize;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = AppTextStyles.securityCodeFigure(theme, size: figureSize);
    final groups = securityCodeGroups(digits);
    final painter = TextPainter(
      text: TextSpan(text: '00000', style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final cell = painter.width;
    painter.dispose();
    return LayoutBuilder(
      builder: (context, constraints) {
        const gutter = AppSpacing.md;
        final available = math.min(constraints.maxWidth, maxWidth);
        final columns = 3 * cell + 2 * gutter <= available ? 3 : 2;
        final rows = (groups.length / columns).ceil();
        return Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: Column(
              children: [
                for (var r = 0; r < rows; r++)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: AppSpacing.xs,
                    ),
                    child: Row(
                      children: [
                        for (var c = 0; c < columns; c++) ...[
                          if (c > 0) const SizedBox(width: gutter),
                          Expanded(
                            child: _group(r * columns + c, groups, style),
                          ),
                        ],
                      ],
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _group(int i, List<String> groups, TextStyle style) {
    if (i >= groups.length) return const SizedBox.shrink();
    return Semantics(
      key: ValueKey('security-code-group-$i'),
      label: securityCodeGroupLabel(i + 1, groups[i]),
      excludeSemantics: true,
      child: SelectionContainer.disabled(
        child: Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(groups[i], style: style, maxLines: 1),
          ),
        ),
      ),
    );
  }
}
