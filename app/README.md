# dzeroth

## Local Chrome login (Windows)

Running Flutter alone does not start Firebase Auth or the API. Keep these
two terminals running from the repository root:

1. Start Firebase in a private temporary directory (requires Git Bash):

   ```powershell
   & 'C:\Program Files\Git\bin\bash.exe' scripts/with-private-tmp.sh firebase emulators:start --project demo-dzeroth-local --only firestore,auth,pubsub,storage
   ```

2. After "All emulators ready", start the API:

   ```powershell
   powershell -File scripts/start-local-api.ps1
   ```

Select **Flutter Chrome (local emulators)** in VS Code, then **Run Without
Debugging**. Alternatively, from `app/`:

```powershell
flutter run -d chrome --web-port=7357 --dart-define=USE_EMULATORS=true --dart-define=API_BASE_URL=http://127.0.0.1:8081 --dart-define=AUTH_EMULATOR_HOST=127.0.0.1:9099
```

The emulator warning is expected. Use disposable local email/password accounts,
created through Sign up or the [Auth emulator UI](http://127.0.0.1:4000/auth).
Verification links appear in the emulator terminal; no real email is sent.
Existing hosted Firebase accounts do not exist in this local project.
Emulator data is temporary unless explicitly exported/imported.

Emulator builds use `demo-dzeroth-local` for Firebase Auth, matching the API.
App Check, telemetry collection, and FCM are disabled in this mode. Fully stop
and relaunch Flutter after changing startup configuration; hot reload is not
sufficient.

## Android release signing

`android/app/build.gradle.kts` signs the `release` build type with an upload
key when one is configured, from `android/key.properties` (gitignored; never
commit it or the keystore) or the environment:

```properties
# android/key.properties
storeFile=/absolute/path/to/upload.jks   # or relative to android/app
storePassword=...
keyAlias=...
keyPassword=...
```

or `DZEROTH_UPLOAD_STORE_FILE`, `DZEROTH_UPLOAD_STORE_PASSWORD`,
`DZEROTH_UPLOAD_KEY_ALIAS` and `DZEROTH_UPLOAD_KEY_PASSWORD`. `key.properties`
wins per field. Secret values are never printed.

Without a key the release build falls back to the debug key and Gradle logs a
warning; such a build cannot be published. Set the Gradle property
`dzerothRequireReleaseSigning=true` to fail the build with a clear message
instead of falling back. `flutter build` has no `-P` flag, so use the
environment form Gradle maps to project properties (for example in the release
workflow):

```
ORG_GRADLE_PROJECT_dzerothRequireReleaseSigning=true flutter build appbundle --release
```

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
