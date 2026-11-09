import java.util.Properties

plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    id("com.google.firebase.crashlytics")
    // END: FlutterFire Configuration
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// android/key.properties is gitignored (see android/.gitignore); never commit it.
val releaseKeyProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) {
        file.inputStream().use { load(it) }
    }
}

fun releaseSigningValue(property: String, envVar: String): String? =
    (releaseKeyProperties.getProperty(property) ?: System.getenv(envVar))
        ?.takeIf { it.isNotBlank() }

android {
    namespace = "com.dzeroth.dzeroth"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.dzeroth.dzeroth"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        // Upload key for release builds. Sources, first match wins per field:
        // android/key.properties (gitignored; storeFile, storePassword,
        // keyAlias, keyPassword) then the DZEROTH_UPLOAD_* environment
        // variables. Values are never printed or logged.
        create("release") {
            val storeFileValue = releaseSigningValue("storeFile", "DZEROTH_UPLOAD_STORE_FILE")
            val storePasswordValue = releaseSigningValue("storePassword", "DZEROTH_UPLOAD_STORE_PASSWORD")
            val keyAliasValue = releaseSigningValue("keyAlias", "DZEROTH_UPLOAD_KEY_ALIAS")
            val keyPasswordValue = releaseSigningValue("keyPassword", "DZEROTH_UPLOAD_KEY_PASSWORD")
            if (
                storeFileValue != null && storePasswordValue != null &&
                keyAliasValue != null && keyPasswordValue != null
            ) {
                // Absolute, or relative to android/app (as in Flutter's signing docs).
                storeFile = file(storeFileValue)
                storePassword = storePasswordValue
                keyAlias = keyAliasValue
                keyPassword = keyPasswordValue
            }
        }
    }

    buildTypes {
        release {
            val releaseSigning = signingConfigs.getByName("release")
            if (releaseSigning.storeFile != null) {
                signingConfig = releaseSigning
            } else if (project.findProperty("dzerothRequireReleaseSigning") == "true") {
                throw GradleException(
                    "Release signing is required (-PdzerothRequireReleaseSigning=true) but no upload " +
                        "key is configured. Provide android/key.properties (storeFile, storePassword, " +
                        "keyAlias, keyPassword) or set DZEROTH_UPLOAD_STORE_FILE, " +
                        "DZEROTH_UPLOAD_STORE_PASSWORD, DZEROTH_UPLOAD_KEY_ALIAS and " +
                        "DZEROTH_UPLOAD_KEY_PASSWORD. See app/README.md."
                )
            } else {
                logger.warn(
                    "WARNING: no release upload key configured; signing the release build with the " +
                        "DEBUG key. This build cannot be published. See app/README.md."
                )
                signingConfig = signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
