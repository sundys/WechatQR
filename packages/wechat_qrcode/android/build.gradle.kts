group = "com.sundys.wechat_qrcode"
version = "1.0-SNAPSHOT"

buildscript {
    val kotlinVersion = "2.3.20"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:9.0.1")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
}

android {
    namespace = "com.sundys.wechat_qrcode"

    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
        getByName("test") {
            java.srcDirs("src/test/kotlin")
        }
    }

    defaultConfig {
        minSdk = 24
    }

    testOptions {
        unitTests {
            isIncludeAndroidResources = true
            all {
                it.useJUnitPlatform()

                it.outputs.upToDateWhen { false }

                it.testLogging {
                    events("passed", "skipped", "failed", "standardOut", "standardError")
                    showStandardStreams = true
                }
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // CameraX plumbing and the Analyzer contract used by the vendored frame
    // analyser. Apache-2.0. Brings CameraX in transitively.
    implementation("com.github.jenly1314:camera-scan:1.5.0")

    // OpenCV Java bindings (org.opencv.*) required by the vendored detector.
    // These are the artifacts jenly1314 publishes for WeChatQRCode 2.6.0 and are
    // the "necessary dependency of the WeChatQRCode implementation" described in
    // docs/decisions/0002-opencv-dependency.md — no other OpenCV module or API is
    // called anywhere in this project.
    implementation("com.github.jenly1314.WeChatQRCode:opencv:2.6.0")

    // Native libopencv_java4.so, arm64-v8a only: that is the ABI the app ships.
    implementation("com.github.jenly1314.WeChatQRCode:opencv-armv64:2.6.0")

    // x86_64 native library for debug builds only, so the engine can be exercised
    // on an emulator. Never part of a release artifact.
    debugImplementation("com.github.jenly1314.WeChatQRCode:opencv-x86_64:2.6.0")
}
