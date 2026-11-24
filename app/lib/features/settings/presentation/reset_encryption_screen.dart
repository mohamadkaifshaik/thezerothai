import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/session_wiring.dart' show UnexpectedErrorReporter;
import '../../auth/presentation/bloc/auth_bloc.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/vault/vault_session.dart';
import '../../../core/widgets/shell_bottom_inset_sliver.dart';
import '../../../core/widgets/shell_geometry.dart';
import '../../../shared/widgets/primitives/app_alert_confirm.dart';
import '../../../shared/widgets/primitives/app_pill_button.dart';
import '../../../shared/widgets/primitives/headline_message.dart';
import '../../messages/presentation/e2ee/encryption_copy.dart';
import '../../messages/presentation/e2ee/encryption_status.dart';
import 'settings_up.dart';

/// Where a reset is in its life.
enum ResetEncryptionPhase { idle, running, done, failed }

/// Runs the reset once at a time. It takes a closure, so the one reference to the session's destructive member
/// is the tear-off in [ResetEncryptionScreen]. A throw is [ResetEncryptionPhase.failed] and is reported by type
/// only (a fixed `StateError('resetByUser')`), never with the error's message.
class ResetEncryptionCubit extends Cubit<ResetEncryptionPhase> {
  ResetEncryptionCubit({
    required Future<bool> Function() reset,
    void Function(Object error, StackTrace stack)? onUnexpectedError,
  }) : _reset = reset,
       _onUnexpectedError = onUnexpectedError,
       super(ResetEncryptionPhase.idle);

  final Future<bool> Function() _reset;
  final void Function(Object error, StackTrace stack)? _onUnexpectedError;

  /// idle or failed -> running -> done (the reset returned true) or failed (false or a throw). Ignored while
  /// running and after done.
  Future<void> run() async {
    if (isClosed ||
        state == ResetEncryptionPhase.running ||
        state == ResetEncryptionPhase.done) {
      return;
    }
    emit(ResetEncryptionPhase.running);
    var ok = false;
    try {
      ok = await _reset();
    } catch (_, stack) {
      _onUnexpectedError?.call(StateError('resetByUser'), stack);
    }
    if (isClosed) return;
    emit(ok ? ResetEncryptionPhase.done : ResetEncryptionPhase.failed);
  }

  /// Back to idle after an outcome was shown (a held cubit outlives screens,
  /// so a later reset, for example after another key loss, can run). Never
  /// while running.
  void rearm() {
    if (isClosed || state == ResetEncryptionPhase.running) return;
    if (state != ResetEncryptionPhase.idle) emit(ResetEncryptionPhase.idle);
  }
}

/// Holds the run of the vault reset above the route (Plan 5b Task 14,
/// "hold the in-flight reset above the route"): `AppWidget` provides one, so
/// leaving the screen while a reset runs neither loses its outcome nor shows
/// a false failure on return. This file is the ONE place that references the
/// session's destructive member (the vault guard names it); the widget tree
/// only ever sees this holder, so `app_widget.dart` has no reference.
///
/// Decision: the outcome of a run that ends while no screen is attached is
/// kept once ([attach] returns it), so the screen that comes back shows the
/// snackbar and goes where an outcome would have sent it; why: the run's
/// effect (a wiped vault) happened either way, and a silent return hides it.
class ResetEncryptionHolder {
  ResetEncryptionHolder({
    required VaultSession session,
    void Function(Object error, StackTrace stack)? onUnexpectedError,
  }) : _session = session,
       _onUnexpectedError = onUnexpectedError;

  final VaultSession _session;
  final void Function(Object error, StackTrace stack)? _onUnexpectedError;
  ResetEncryptionCubit? _cubit;
  StreamSubscription<ResetEncryptionPhase>? _sub;
  int _attached = 0;
  ResetEncryptionPhase? _unseen;

  /// The run's cubit when one was made, without making it.
  ResetEncryptionCubit? get cubitIfCreated => _cubit;

  /// Created on the first read (nothing is called until `run`).
  ResetEncryptionCubit get cubit {
    final existing = _cubit;
    if (existing != null) return existing;
    final cubit = ResetEncryptionCubit(
      reset: _session.resetByUser,
      onUnexpectedError: _onUnexpectedError,
    );
    _cubit = cubit;
    _sub = cubit.stream.listen((phase) {
      final finished =
          phase == ResetEncryptionPhase.done ||
          phase == ResetEncryptionPhase.failed;
      // Only a state that is still finished: a stale event of an outcome
      // that attach already handed over (or reset forgot) is not kept.
      if (finished && _attached == 0 && cubit.state == phase) _unseen = phase;
    });
    return cubit;
  }

  /// A screen starts showing the run. Returns an outcome that arrived while
  /// no screen was attached (once), and re-arms a finished run.
  ResetEncryptionPhase? attach() {
    // The cubit's own state is read too: an outcome emitted but not yet
    // delivered to the stream listener (it lands a microtask later) is still
    // unseen. A screen that saw its outcome is detached with the state
    // re-armed (see [detach]), so a state that is finished here was not seen.
    var unseen = _unseen;
    final current = _cubit?.state;
    if (unseen == null && _attached == 0 && _isFinished(current)) {
      unseen = current;
    }
    _attached++;
    _unseen = null;
    _cubit?.rearm();
    return unseen;
  }

  static bool _isFinished(ResetEncryptionPhase? phase) =>
      phase == ResetEncryptionPhase.done ||
      phase == ResetEncryptionPhase.failed;

  void detach() {
    if (_attached > 0) _attached--;
    // The last screen saw whatever the run ended with: back to idle, so a
    // later attach does not hand it over a second time.
    if (_attached == 0) _cubit?.rearm();
  }

  /// Per-account reset (fix round D): an outcome of the previous account's
  /// run is not shown to the next one.
  void reset() {
    _unseen = null;
    _cubit?.rearm();
  }

  void dispose() {
    unawaited(_sub?.cancel());
    unawaited(_cubit?.close());
  }
}

/// Settings > Encrypted messages > Reset (`/settings/encryption/reset`, R15). Reached from the status card's
/// Reset... action. Opened any other way (a typed URL, no status cubit, a status that does not offer a reset) it
/// shows "Nothing to reset" and cannot call anything: the session is read only once a reset is offered.
///
/// Nothing is deleted before every confirmation the status needs (one; two when the device may not start again,
/// read again after the first closes) has been given. While it runs the button is busy and leaving is disabled.
/// (Stateful, not stateless as first briefed: it keeps the run's cubit, the confirmation latch and the status.)
class ResetEncryptionScreen extends StatefulWidget {
  const ResetEncryptionScreen({super.key});

  @override
  State<ResetEncryptionScreen> createState() => _ResetEncryptionScreenState();
}

class _ResetEncryptionScreenState extends State<ResetEncryptionScreen> {
  ResetEncryptionCubit? _cubit;
  StreamSubscription<ResetEncryptionPhase>? _sub;
  EncryptionStatusCubit? _status;
  bool _asking = false;

  /// The run held above the route (provided by `AppWidget`), or this screen's own holder (made the first time a
  /// reset is offered, closed with the screen) when none is provided (screen tests).
  ResetEncryptionHolder? _holder;
  ResetEncryptionHolder? _ownHolder;

  @override
  void initState() {
    super.initState();
    final holder = context.read<ResetEncryptionHolder?>();
    _holder = holder;
    // An outcome that arrived while no screen was showing the run is shown now (once).
    final unseen = holder?.attach();
    if (unseen != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _onPhase(unseen);
      });
    }
  }

  ResetEncryptionCubit _bind(ResetEncryptionCubit cubit) {
    if (identical(_cubit, cubit)) return cubit;
    unawaited(_sub?.cancel());
    _cubit = cubit;
    _sub = cubit.stream.listen(_onPhase);
    return cubit;
  }

  /// Takes the run's cubit the first time a reset is offered (the only place the session is read) and keeps it
  /// after, so a status change caused by the wipe itself cannot drop a running reset. It runs inside `build` on
  /// purpose: it only reads providers, never emits or calls the session, and the cubit must exist for the very
  /// build that shows the form.
  ResetEncryptionCubit _ensureCubit(
    BuildContext context,
    EncryptionStatusCubit status,
  ) {
    _status = status;
    var holder = _holder;
    if (holder == null) {
      holder = _ownHolder = _holder = ResetEncryptionHolder(
        session: context.read<VaultSession>(),
        onUnexpectedError: context.read<UnexpectedErrorReporter?>(),
      );
      holder.attach();
    }
    return _bind(holder.cubit);
  }

  void _onPhase(ResetEncryptionPhase phase) {
    if (!mounted) return;
    // The app bar and back handling depend on the phase too.
    setState(() {});
    final messenger = ScaffoldMessenger.of(context);
    switch (phase) {
      case ResetEncryptionPhase.done:
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text(kResetDoneText)));
        context.go(AppRouter.encryptionSettingsPath);
      case ResetEncryptionPhase.failed:
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text(kResetFailedText)));
        // A failed wipe can leave a status that no longer offers a reset (for example `unavailable`): this page
        // would then say "Nothing to reset" beside the failure, so go where the status card explains it.
        final status = _status;
        if (status != null) {
          status.refresh();
          if (!status.state.offersReset) {
            context.go(AppRouter.encryptionSettingsPath);
          }
        }
      case ResetEncryptionPhase.idle:
      case ResetEncryptionPhase.running:
        break;
    }
  }

  /// One confirmation dialog. A dialog that cannot be shown is `false` (nothing is deleted) and reports a fixed
  /// `StateError('resetConfirm')`, never the error itself.
  Future<bool> _confirm(
    UnexpectedErrorReporter? report, {
    required String title,
    required String message,
    required String confirmLabel,
  }) async {
    try {
      return await showAppAlertConfirm(
        context,
        title: title,
        message: message,
        confirmLabel: confirmLabel,
        destructive: true,
      );
    } catch (_, stack) {
      report?.call(StateError('resetConfirm'), stack);
      return false;
    }
  }

  /// Asks, then runs. One tap at a time (the guard covers the dialogs). Nothing runs unless every required
  /// dialog is confirmed, the same account is still signed in and a status read afresh still offers the reset.
  /// The status cubit only changes on a listener or `refresh()`, so it is refreshed before each decision.
  Future<void> _start(
    EncryptionStatusCubit status,
    ResetEncryptionCubit cubit,
  ) async {
    if (_asking || cubit.state == ResetEncryptionPhase.running) return;
    _asking = true;
    try {
      // Read before the first await (the sign-out flow does the same): the account the user confirmed for.
      final auth = context.read<AuthBloc>();
      final uid = auth.state.user?.uid;
      final report = context.read<UnexpectedErrorReporter?>();
      final first = await _confirm(
        report,
        title: kResetConfirmTitle,
        message: kResetConfirmMessage,
        confirmLabel: kResetConfirmLabel,
      );
      if (!first || !mounted) return;
      // The flag may have changed since the status was last computed.
      status.refresh();
      if (!status.state.mayStart) {
        final second = await _confirm(
          report,
          title: kResetSecondTitle,
          message: '$kResetNoRestartWarning.',
          confirmLabel: kResetSecondLabel,
        );
        if (!second || !mounted) return;
      }
      // No await from here to the call. A different account, or a status that no longer offers the reset
      // (the vault reopened while a dialog was open), deletes nothing.
      if (auth.state.user?.uid != uid) return;
      status.refresh();
      if (!status.state.offersReset) return;
      await cubit.run();
    } finally {
      _asking = false;
    }
  }

  void _cancel() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRouter.encryptionSettingsPath);
    }
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    // A provided holder keeps its run (above the route); only an own one ends here.
    _holder?.detach();
    _ownHolder?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final status = context.watch<EncryptionStatusCubit?>();
    final state = status?.state;
    // A run held above the route that is still going shows the form, whatever the status says now.
    final held = _cubit ?? _holder?.cubitIfCreated;
    final existing = held == null ? null : _bind(held);
    final running = existing?.state == ResetEncryptionPhase.running;
    final offered = state != null && state.offersReset;
    final showForm = status != null && (offered || running);
    final cubit = showForm ? _ensureCubit(context, status) : null;
    final up = settingsUpButton(context, AppRouter.encryptionSettingsPath);
    // While it runs, the arrow is shown disabled only where one would be shown at all.
    final hasArrow = up != null || (ModalRoute.of(context)?.canPop ?? false);
    return PopScope(
      canPop: !running,
      child: Scaffold(
        appBar: AppBar(
          leading: running
              ? (hasArrow
                    ? const IconButton(
                        onPressed: null,
                        icon: Icon(Icons.arrow_back),
                      )
                    : null)
              : up,
          title: const Text(kResetTitle),
        ),
        body: SafeArea(
          bottom: false,
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: ShellGeometry.readableMaxWidth(context),
              ),
              child: cubit == null
                  ? ListView(
                      padding:
                          const EdgeInsets.all(AppSpacing.md) +
                          shellBottomInsets(context),
                      children: const [
                        HeadlineMessage(
                          title: kResetNothingTitle,
                          body: kResetNothingBody,
                        ),
                      ],
                    )
                  : BlocBuilder<ResetEncryptionCubit, ResetEncryptionPhase>(
                      bloc: cubit,
                      builder: (context, phase) => _Form(
                        mayStart: state?.mayStart ?? false,
                        running: phase == ResetEncryptionPhase.running,
                        onReset: () => unawaited(_start(status!, cubit)),
                        onCancel: _cancel,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Form extends StatelessWidget {
  const _Form({
    required this.mayStart,
    required this.running,
    required this.onReset,
    required this.onCancel,
  });

  final bool mayStart;
  final bool running;
  final VoidCallback onReset;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final phone = width < AppBreakpoints.mobile;
    final points = [
      kResetPoint1,
      kResetPoint2,
      if (mayStart) kResetPoint3,
      kResetPoint4,
    ];
    final reset = AppPillButton(
      label: kResetAction,
      variant: AppButtonVariant.danger,
      size: phone ? AppButtonSize.large : AppButtonSize.regular,
      busy: running,
      busySemanticsLabel: kResetRunningLabel,
      onPressed: running ? null : onReset,
    );
    final cancel = AppPillButton(
      label: 'Cancel',
      variant: phone ? AppButtonVariant.text : AppButtonVariant.outline,
      onPressed: running ? null : onCancel,
    );
    return ListView(
      padding:
          const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.md,
            AppSpacing.md,
            AppSpacing.lg,
          ) +
          shellBottomInsets(context),
      children: [
        Text(kResetLead, style: theme.textTheme.bodyLarge),
        const SizedBox(height: AppSpacing.md),
        for (final point in points)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const ExcludeSemantics(child: Text('•  ')),
                Expanded(child: Text(point, style: theme.textTheme.bodyMedium)),
              ],
            ),
          ),
        if (!mayStart)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm),
            child: Semantics(
              liveRegion: true,
              container: true,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    color: theme.colorScheme.error,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      kResetNoRestartWarning,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.error,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: AppSpacing.lg),
        if (phone)
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              reset,
              const SizedBox(height: AppSpacing.sm),
              cancel,
            ],
          )
        else
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            // Desktop and tablet alike: the destructive action first.
            children: [reset, cancel],
          ),
      ],
    );
  }
}
