import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing material lives outside the repository. Point
// KOE_ANDROID_SIGNING at a properties file (storeFile, storePassword,
// keyAlias, keyPassword) or keep it at the default path below; without it,
// release builds fall back to the debug key.
val signingFile = file(
    System.getenv("KOE_ANDROID_SIGNING")
        ?: "${System.getProperty("user.home")}/.config/koe/android-signing.properties",
)
val releaseSigning = signingFile.takeIf { it.isFile }?.let { file ->
    Properties().apply { file.inputStream().use { load(it) } }
}
if (releaseSigning == null) {
    logger.warn("Koe: no release signing at ${signingFile.path}; release builds use the debug key.")
}

android {
    namespace = "com.semanticcraft.soundcore"
    // Android 17 (API 37) on the Pixel 11 Pro; Flutter's default is still 36.
    // The SDK names this platform android-37.0, so give the minor level too.
    compileSdk {
        version = release(37) { minorApiLevel = 0 }
    }
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.semanticcraft.soundcore"
        minSdk = 34
        targetSdk = 37
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (releaseSigning != null) {
            create("release") {
                storeFile = file(releaseSigning.getProperty("storeFile"))
                storePassword = releaseSigning.getProperty("storePassword")
                keyAlias = releaseSigning.getProperty("keyAlias")
                keyPassword = releaseSigning.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        debug {
            // Integration tests uninstall their package on exit. Keep the
            // user's recordings and settings in the production application.
            if (System.getenv("KOE_ANDROID_VERIFICATION") == "1") {
                applicationIdSuffix = ".verification"
            }
        }
        release {
            signingConfig = signingConfigs.getByName(
                if (releaseSigning != null) "release" else "debug",
            )
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
