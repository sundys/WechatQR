plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ---------------------------------------------------------------------------
// Release signing
//
// The upload key is never stored in this repository. CI supplies it through
// environment variables, populated from repository secrets
// (.github/workflows/release.yml):
//
//   ANDROID_KEYSTORE_PATH      path to the .jks file written by the CI step
//   ANDROID_KEYSTORE_PASSWORD  store password
//   ANDROID_KEY_ALIAS          key alias
//   ANDROID_KEY_PASSWORD       key password
//
// When any of them is missing the release build falls back to the debug key so
// that `flutter build apk --release` still works locally. That fallback is
// loud on purpose: an accidentally debug-signed release must be obvious.
//
// The `env` prefix is not cosmetic. Inside `signingConfigs { create("release") { … } }`
// the implicit receiver is the SigningConfig, which has its own
// `storePassword` / `keyAlias` / `keyPassword` properties — so bare names there
// resolve to the receiver and silently become self-assignments of null, and the
// build then fails at packaging with "missing required property keyPassword".
// ---------------------------------------------------------------------------
val envKeystorePath: String? = System.getenv("ANDROID_KEYSTORE_PATH")
val envKeystorePassword: String? = System.getenv("ANDROID_KEYSTORE_PASSWORD")
val envKeyAlias: String? = System.getenv("ANDROID_KEY_ALIAS")
val envKeyPassword: String? = System.getenv("ANDROID_KEY_PASSWORD")

val hasReleaseSigning: Boolean =
    !envKeystorePath.isNullOrBlank() &&
        !envKeystorePassword.isNullOrBlank() &&
        !envKeyAlias.isNullOrBlank() &&
        !envKeyPassword.isNullOrBlank() &&
        file(envKeystorePath).exists()

android {
    namespace = "com.sundys.wechatqr"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.sundys.wechatqr"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // The WeChatQRCode engine is shipped as a prebuilt native library, so
        // only the ABIs that library exists for may be packaged. Without this
        // filter a fat build would also emit a 32-bit ARM slice with no
        // libopencv_java4.so in it, which installs fine and then fails at
        // runtime on those devices.
        //
        // arm64-v8a is what release builds ship. x86_64 is included so the
        // engine can be exercised on an emulator (see
        // packages/wechat_qrcode/android/build.gradle.kts); it costs nothing in
        // a release build, which is arm64-v8a only.
        ndk {
            abiFilters.clear()
            abiFilters.addAll(listOf("arm64-v8a", "x86_64"))
        }
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                // Qualified on purpose: see the note above about SigningConfig
                // shadowing these names in this scope.
                storeFile = file(envKeystorePath!!)
                storePassword = envKeystorePassword
                keyAlias = envKeyAlias
                keyPassword = envKeyPassword
            }
        }
    }

    buildTypes {
        release {
            // Release artifacts are arm64-v8a only: that is the ABI the OpenCV
            // native library is shipped for. The release workflow additionally
            // passes `--target-platform android-arm64`.
            ndk {
                abiFilters.clear()
                abiFilters.add("arm64-v8a")
            }

            // `ndk.abiFilters` constrains what the NDK builds and what Flutter
            // packages, but prebuilt jniLibs coming from plugin AARs still land
            // in the APK for every ABI those AARs ship. They are dead weight —
            // the app cannot run there without libflutter.so and
            // libopencv_java4.so — so they are excluded explicitly, which is
            // what makes "release is arm64-only" checkable in CI.
            packaging {
                jniLibs {
                    excludes += listOf(
                        "**/armeabi-v7a/**",
                        "**/x86/**",
                        "**/x86_64/**",
                    )
                }
            }

            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                logger.warn(
                    "ANDROID_KEYSTORE_PATH / ANDROID_KEYSTORE_PASSWORD / " +
                        "ANDROID_KEY_ALIAS / ANDROID_KEY_PASSWORD are not all set. " +
                        "Falling back to the DEBUG signing key: this APK is NOT " +
                        "suitable for distribution.",
                )
                signingConfigs.getByName("debug")
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
