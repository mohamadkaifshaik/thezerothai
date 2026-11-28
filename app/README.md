# dzeroth

## Local Chrome login (Windows)

Running Flutter alone does not start Firebase Auth or the API. Keep these
two terminals running from the repository root:

1. Start Firebase in a private temporary directory (requires Git Bash):

   ```powershell
   & 'C:\Program Files\Git\bin\bash.exe' scripts/with-private-tmp.sh firebase emulators:start --project demo-dzeroth-local --only firestore,auth,pubsub,storage
   ```

2. After "All emulators ready", start the API on port 8081, pointed at the
   emulators:

   ```powershell
   $env:FIREBASE_PROJECT_ID = 'demo-dzeroth-local'
   $env:PORT = '8081'
   $env:FIRESTORE_EMULATOR_HOST = '127.0.0.1:8080'
   $env:FIREBASE_AUTH_EMULATOR_HOST = '127.0.0.1:9099'
   $env:PUBSUB_EMULATOR_HOST = '127.0.0.1:8085'
   $env:STORAGE_EMULATOR_HOST = '127.0.0.1:9199'
   cd backend; go run ./cmd/api
   ```

   Or skip both steps and run `make dev` from the repository root (Git Bash):
   it starts the emulators, the API (`scripts/dev.sh`) and Flutter web in Chrome
   together.

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

## Composer media editor

Dzeroth covers the core photo and video editing workflow. The table tracks
parity with the X Android editor audited on a Redmi K20 Pro.

| Area | Implemented | Remaining gaps |
| --- | --- | --- |
| Photos | Crop, rotate, enhance, filters, movable stickers, text, drawing, pixelation, manual blackout, photo overlays, collages, alt text, and Android gallery export. | Automatic text detection and redaction, photo-specific sensitive-content warnings, people and location tagging, and Grok editing controls. |
| Videos | Preview, trim before and after import, mute, styled text, automatic and imported timed captions, cover frame selection, uploaded covers, Android gallery export, sensitive-content warnings, Made with AI disclosure, and an Android in-app download toggle. | Grok permissions, multiple video attachments, and importing source files larger than 96 MiB even when the final trim would fit. |

Tap an attached photo and choose **Tools** to edit it. Tap the pencil on an
attached video to open **Trim**, **Text**, **Captions**, **Cover**, and
**Settings**. Text and captions are rendered into the exported clip. The
download toggle controls the in-app action. Published media URLs remain public.

The X workflow was verified on the Redmi K20 Pro. Dzeroth verification covered
Android and web builds, 500 Flutter tests, and the relevant Go suites. A
device test of the upgraded Dzeroth APK and a live Google transcription test
remain pending.

### Automatic video captions

Enable the Speech-to-Text API (`speech.googleapis.com`) in the Google Cloud
project and set `VIDEO_CAPTIONS=true` on the Go API. The API uses Application
Default Credentials from its runtime identity. The editor sends only the
audio from the selected trim range when the author chooses **Generate
captions**. SRT and WebVTT import also work with the provider disabled.

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

The tagged Android release job requires four GitHub Actions secrets in the `prod` environment.
Set `DZEROTH_UPLOAD_STORE_BASE64` to the base64-encoded upload keystore and
set `DZEROTH_UPLOAD_STORE_PASSWORD`, `DZEROTH_UPLOAD_KEY_ALIAS`, and
`DZEROTH_UPLOAD_KEY_PASSWORD` for its upload key. A separate signing job signs the compiled AAB and verifies its signer against
this alias before publishing the release artifact.

See the [repository README](../README.md) for the project overview and commands.
