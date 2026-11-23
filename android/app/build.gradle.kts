import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android Gradle plugin.
    // Kotlin support is built into the Android plugin, so no Kotlin plugin line.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
} else {
    logger.warn(
        "WARNING: android/key.properties not found; release builds are signed " +
            "with the DEBUG key. Do not install such an APK on the TV: later " +
            "release-signed updates would be rejected."
    )
}

android {
    namespace = "com.codedbykay.tvsaver"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.codedbykay.tvsaver"
        minSdk = maxOf(flutter.minSdkVersion, 26)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Two apps from one project. TV: com.codedbykay.tvsaver.tv (lib/main_tv.dart),
    // phone: com.codedbykay.tvsaver (later stories). The TV-only manifest entries
    // (leanback launcher, banner, full-screen theme) live in src/tv/.
    flavorDimensions += "app"
    productFlavors {
        create("tv") {
            dimension = "app"
            applicationIdSuffix = ".tv"
        }
        create("phone") {
            dimension = "app"
        }
    }

    // Strip non-32-bit-ARM native libraries from plugins when building the TV APK
    // (`--target-platform android-arm`) so the Sony TV APK stays small.
    packaging {
        jniLibs {
            if (project.findProperty("target-platform") == "android-arm") {
                excludes += setOf("lib/x86_64/**", "lib/arm64-v8a/**", "lib/x86/**")
            }
        }
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            // Falls back to the debug key when android/key.properties is absent.
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
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
