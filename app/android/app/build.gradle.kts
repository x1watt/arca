import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing key: android/key.properties (storeFile, storePassword,
// keyAlias, keyPassword) when present, as the release workflow writes it
// from repository secrets. Without it, release builds use the debug key.
val keyProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}

android {
    namespace = "org.arca.arca"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "org.arca.arca"
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

        // Speech recognition always optimized, even in debug builds.
        externalNativeBuild {
            cmake {
                // Few compile jobs at a time: ggml is heavy to compile and the
                // Gradle daemon shares the memory.
                arguments += listOf(
                    "-DCMAKE_BUILD_TYPE=Release",
                    "-DCMAKE_JOB_POOLS=compile=4",
                    "-DCMAKE_JOB_POOL_COMPILE=compile",
                )
            }
        }
    }

    // libarca_whisper.so: whisper.cpp for subtitles (native/arca_whisper).
    externalNativeBuild {
        cmake {
            path = file("../../../native/arca_whisper/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    signingConfigs {
        if (!keyProperties.isEmpty) {
            create("release") {
                storeFile = rootProject.file(keyProperties.getProperty("storeFile"))
                storePassword = keyProperties.getProperty("storePassword")
                keyAlias = keyProperties.getProperty("keyAlias")
                keyPassword = keyProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // The release key when key.properties exists, otherwise the
            // debug key, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName(if (keyProperties.isEmpty) "debug" else "release")
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
