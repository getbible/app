import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// CI supplies a temporary keystore path. Developers may use the ignored
// android/key.properties file instead; never mix credentials from both sources.
val signingEnvironment = mapOf(
    "storeFile" to System.getenv("ANDROID_KEYSTORE_PATH"),
    "storePassword" to System.getenv("ANDROID_KEYSTORE_PASSWORD"),
    "keyAlias" to System.getenv("ANDROID_KEY_ALIAS"),
    "keyPassword" to System.getenv("ANDROID_KEY_PASSWORD"),
)
val signingProperties = Properties()
val signingPropertiesFile = rootProject.file("key.properties")
val useSigningEnvironment = signingEnvironment.values.any { !it.isNullOrEmpty() }
if (useSigningEnvironment) {
    signingEnvironment.forEach { (name, value) ->
        if (!value.isNullOrEmpty()) signingProperties.setProperty(name, value)
    }
} else if (signingPropertiesFile.exists()) {
    signingPropertiesFile.inputStream().use { signingProperties.load(it) }
}
val hasReleaseSigning = useSigningEnvironment || signingPropertiesFile.exists()
if (hasReleaseSigning) {
    val missing = signingEnvironment.keys.filter {
        signingProperties.getProperty(it).isNullOrEmpty()
    }
    require(missing.isEmpty()) {
        "Incomplete Android release signing configuration; missing fields: ${missing.joinToString()}. See docs/SIGNING_ANDROID_WINDOWS.md."
    }
    require(rootProject.file(signingProperties.getProperty("storeFile")).isFile) {
        "Android release keystore file is unavailable."
    }
}

android {
    namespace = "life.getbible.mobile"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "life.getbible.mobile"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = rootProject.file(signingProperties.getProperty("storeFile"))
                storePassword = signingProperties.getProperty("storePassword")
                keyAlias = signingProperties.getProperty("keyAlias")
                keyPassword = signingProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // No release-to-debug signing fallback: the regular validation
            // matrix remains explicitly unsigned when credentials are absent.
            if (hasReleaseSigning) signingConfig = signingConfigs.getByName("release")
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
