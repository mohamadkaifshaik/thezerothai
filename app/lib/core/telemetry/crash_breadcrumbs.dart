/// Every crash breadcrumb the app may log (ADR-0032 F6: compile-time
/// constants only). A runtime string cannot be passed: the reporter takes this
/// enum. Add a value here, and to the policy text, to add a breadcrumb.
enum CrashBreadcrumb {
  appStart('app_start'),
  signedIn('signed_in'),
  signedOut('signed_out'),
  composerOpened('composer_opened'),
  postSubmitted('post_submitted'),
  mediaUploadStarted('media_upload_started');

  const CrashBreadcrumb(this.label);

  /// The text written to the crash log.
  final String label;
}
