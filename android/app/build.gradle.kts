import java.util.Properties
import java.io.FileInputStream



plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    // END: FlutterFire Configuration
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    // file: android/app/build.gradle.kts
    // Apply the Firebase and Crashlytics plugins
    id("com.google.firebase.crashlytics")

}
val keystoreProperties = Properties().apply {
    val keystorePropertiesFile = rootProject.file("key.properties")
    if (keystorePropertiesFile.exists()) {
        load(FileInputStream(keystorePropertiesFile))
    }
}

android {
    namespace = "com.aitechapps.fitnesschallenge"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "27.0.12077973"

    compileOptions {
        //sourceCompatibility = JavaVersion.VERSION_11
        //targetCompatibility = JavaVersion.VERSION_11
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
        // THIS IS THE LINE YOU NEED TO ADD
        isCoreLibraryDesugaringEnabled = true
    }

   // kotlinOptions {
   //     jvmTarget = JavaVersion.VERSION_11.toString()
   // }
   kotlinOptions {
        jvmTarget = "1.8" // Must match compileOptions
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.aitechapps.fitnesschallenge"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 23
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }
    signingConfigs {
        create("release") {
            storeFile = file(keystoreProperties["storeFile"] as String)
            storePassword = keystoreProperties["storePassword"] as String
            keyAlias = keystoreProperties["keyAlias"] as String
            keyPassword = keystoreProperties["keyPassword"] as String
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            //signingConfig = signingConfigs.getByName("debug")
            
            isMinifyEnabled = false
            isShrinkResources = false
            signingConfig = signingConfigs.getByName("release")
        
        }
    }
}

flutter {
    source = "../.."
}
// file: android/app/build.gradle.kts

dependencies {
    implementation(platform("com.google.firebase:firebase-bom:32.8.1")) // Check for the latest version
    implementation("com.google.firebase:firebase-crashlytics-ktx")
    implementation("com.google.firebase:firebase-analytics-ktx") // Analytics is recommended
    // ... other dependencies
    // THIS IS THE DEPENDENCY YOU NEED TO ADD FOR DESUGARING
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
