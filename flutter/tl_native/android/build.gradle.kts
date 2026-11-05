group = "org.twimshelf.tl_native"
version = "1.0"

plugins {
    id("com.android.library")
}

// AGP 9 compiles Kotlin itself; older ones need the Kotlin plugin
val agpMajor = com.android.Version.ANDROID_GRADLE_PLUGIN_VERSION.substringBefore('.').toInt()
if (agpMajor < 9) {
    apply(plugin = "org.jetbrains.kotlin.android")
}

android {
    namespace = "org.twimshelf.tl_native"
    compileSdk = 36
    defaultConfig { minSdk = 24 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    implementation("androidx.core:core:1.13.1")
}
