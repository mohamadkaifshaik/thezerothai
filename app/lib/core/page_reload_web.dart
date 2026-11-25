import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// Reloads the current page (`window.location.reload()`). Does nothing when the
/// browser exposes no `location`.
void reloadPage() {
  final location = globalContext['location'];
  if (location == null || !location.isA<JSObject>()) return;
  (location as JSObject).callMethod('reload'.toJS);
}
