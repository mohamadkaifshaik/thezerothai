import 'package:flutter_web_plugins/url_strategy.dart';

import 'app/bootstrap.dart';

Future<void> main() async {
  // Web: `/post/<id>` instead of `/#/post/<id>`, so a shared link is a real
  // path (Firebase Hosting rewrites `**` to `/index.html`). Must run before
  // runApp; a no-op on iOS and Android.
  usePathUrlStrategy();
  await bootstrap();
}
