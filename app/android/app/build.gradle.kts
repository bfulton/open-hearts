import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// The release key, from android/key.properties — storeFile, storePassword,
// keyAlias, keyPassword — which is never checked in (android/.gitignore)
// and is written from the store's secrets wherever a release is built.
// A release is signed with it or not built at all: signed with the debug
// key it would install as this app anywhere, and could never be updated
// by the real one.
val releaseKeys: Properties? = rootProject.file("key.properties").takeIf { it.exists() }?.let { keys ->
    Properties().apply { FileInputStream(keys).use { load(it) } }
}

android {
    namespace = "game.openhearts"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // The Play Store's package name; the service knows it as OH_PLAY_PACKAGE.
        applicationId = "game.openhearts"
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
        if (releaseKeys != null) {
            create("release") {
                storeFile = file(releaseKeys.getProperty("storeFile"))
                storePassword = releaseKeys.getProperty("storePassword")
                keyAlias = releaseKeys.getProperty("keyAlias")
                keyPassword = releaseKeys.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release")
        }
    }
}

// No key, no release: said before anything is built, rather than left
// as an unsigned package for someone to wonder about. A debug build
// needs no key and is untouched.
gradle.taskGraph.whenReady {
    val releasing = allTasks.any { it.project == project && (it.name == "packageRelease" || it.name == "bundleRelease") }
    // Every live table is sealed, so a release without the deal's native
    // library is a phone that plays alone and cannot say why.
    // crypto/build_android.sh puts it, and Schnorr's beside it, here.
    val missing = listOf("arm64-v8a", "armeabi-v7a", "x86_64").filter { !file("src/main/jniLibs/$it/libdeal.so").exists() }
    if (releasing && missing.isNotEmpty()) {
        throw GradleException("No libdeal.so for ${missing.joinToString()}: run crypto/build_android.sh first.")
    }
    if (releaseKeys == null && releasing) {
        throw GradleException(
            "No android/key.properties: a release is signed with the release key or not built. " +
                "It names storeFile, storePassword, keyAlias and keyPassword, and is never checked in.",
        )
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
