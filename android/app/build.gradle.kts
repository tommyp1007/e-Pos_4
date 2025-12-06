import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android") // ✅ Kotlin plugin for AGP
    id("dev.flutter.flutter-gradle-plugin")
}

// Load keystore properties
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()

if (keystorePropertiesFile.exists()) {
    FileInputStream(keystorePropertiesFile).use { keystoreProperties.load(it) }
} else {
    println("⚠️ Warning: key.properties file not found at ${keystorePropertiesFile.absolutePath}!")
}

android {
    namespace = "lhdn.myinvois.epos.preprod"

    // ✅ Match Flutter/AGP requirements
    compileSdk = 36
    ndkVersion = "27.0.12077973"

    defaultConfig {
        applicationId = "lhdn.myinvois.epos.preprod"
        minSdk = 26
        targetSdk = 36

        versionCode = flutter.versionCode
        versionName = flutter.versionName

        vectorDrawables.useSupportLibrary = true

        // =================================================================
        // == ADD THIS LINE FOR BETTER COMPATIBILITY ==
        // =================================================================
        multiDexEnabled = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    // ✅ Force Gradle Java toolchain to use Java 17
    java {
        toolchain {
            languageVersion.set(JavaLanguageVersion.of(17))
        }
    }

    // Suppress obsolete option warnings
    tasks.withType<JavaCompile> {
        options.compilerArgs.add("-Xlint:-options")
    }

    signingConfigs {
        create("release") {
            storeFile = keystoreProperties["storeFile"]?.toString()?.let { file(it) }
            storePassword = keystoreProperties["storePassword"]?.toString()
            keyAlias = keystoreProperties["keyAlias"]?.toString()
            keyPassword = keystoreProperties["keyPassword"]?.toString()
        }
    }

    buildTypes {
        getByName("release") {
            signingConfig = signingConfigs.findByName("release")?.takeIf { it.storeFile != null }
                ?: run {
                    println("⚠️ Warning: release signing config is not set. APK will be unsigned!")
                    null
                }

            isMinifyEnabled = false
            isShrinkResources = false
            // If you enable shrinking later:
            // proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }

        getByName("debug") {
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
            isDebuggable = true
        }
    }
}

dependencies {
    // This line is for enabling modern Java APIs on older Android versions
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")

    // The Firebase BOM (Bill of Materials) manages compatible versions for Google/Firebase libraries.
    implementation(platform("com.google.firebase:firebase-bom:33.1.2"))
    // This forces Gradle to use a modern version of the core Play Services library.
    implementation("com.google.android.gms:play-services-basement:18.4.0")
}

flutter {
    source = "../.."
}

// =================================================================
// == ADD THIS ENTIRE BLOCK TO FORCE THE DEPENDENCY VERSION ==
// =================================================================
// This block applies a resolution strategy to all configurations.
configurations.all {
    resolutionStrategy {
        // This is a non-negotiable command to Gradle.
        force("com.google.android.gms:play-services-basement:18.4.0")
    }
}