import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// True when this browser exposes both `navigator.share` and
/// `navigator.canShare` (the Web Share API; secure contexts only). Anything
/// else, including a missing `navigator`, is false.
bool webHasNativeShare() {
  final navigator = globalContext['navigator'];
  if (navigator == null || !navigator.isA<JSObject>()) return false;
  final object = navigator as JSObject;
  return object.has('share') && object.has('canShare');
}
