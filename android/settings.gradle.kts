pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        // Maven Central rate-limits shared CI runner IPs with HTTP 429. Resolve the
        // Kotlin plugin and all of its build-time dependencies from a full mirror
        // first; the Plugin Portal only carries the marker and the plugin jar, not
        // Kotlin's transitive build dependencies, so it must not be first.
        maven("https://repo1.maven.org/maven2")
        google()
        maven("https://maven-central.storage-download.googleapis.com/maven2/")
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.3.1" apply false
    id("org.jetbrains.kotlin.android") version "2.4.20" apply false
    // Kept from when the widget was Glance (Compose code); see app/build.gradle.kts.
    id("org.jetbrains.kotlin.plugin.compose") version "2.4.20" apply false
}

include(":app")
