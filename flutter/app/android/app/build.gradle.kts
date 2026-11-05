import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// name, package and the share target: from config.yaml (scripts/apply.py)
val identity = Properties().apply { rootProject.file("identity.properties").inputStream().use { load(it) } }

android {
    buildFeatures { buildConfig = true }
    namespace = "org.twimshelf.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = identity.getProperty("applicationId")
        manifestPlaceholders["appName"] = identity.getProperty("appName")
        manifestPlaceholders["shareEnabled"] = identity.getProperty("shareEnabled")
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 31
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // a release keystore when the build has one (android/key.properties, written by the release
    // workflow from its secrets; never committed); otherwise the debug key
    val keys = rootProject.file("key.properties").takeIf { it.exists() }?.let { f -> Properties().apply { f.inputStream().use { load(it) } } }
    signingConfigs {
        if (keys != null) create("release") {
            storeFile = file(keys.getProperty("storeFile"))
            storePassword = keys.getProperty("storePassword")
            keyAlias = keys.getProperty("keyAlias")
            keyPassword = keys.getProperty("keyPassword")
        }
    }

    // on disk, not inside the APK: llama.cpp finds its backends (CPU, Vulkan) by listing the folder
    packaging {
        jniLibs {
            useLegacyPackaging = true
            // the phone's own OpenCL, not the loader built only to link against: it looks for
            // drivers where Android keeps none. And llama.cpp's command line tools, not used here.
            excludes += listOf("**/libOpenCL.so", "**/libllama-*-impl.so")
        }
    }

    buildTypes {
        debug {
            applicationIdSuffix = ".debug"
        }
        release {
            signingConfig = signingConfigs.getByName(if (keys != null) "release" else "debug")
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

// Android's chooser needs a resource before the Flutter engine is running.
// Generate it from the same catalogs, never from a second hard-coded translation.
abstract class GenerateShareCatalogTask : DefaultTask() {
    @get:InputDirectory
    abstract val catalogsDirectory: DirectoryProperty
    @get:OutputDirectory
    abstract val outputDirectory: DirectoryProperty
    @get:Input
    abstract val appName: Property<String>

    @TaskAction
    fun generate() {
        mapOf("en" to "values", "ja" to "values-ja", "zh-Hans" to "values-b+zh+Hans",
            "zh-Hant" to "values-b+zh+Hant").forEach { (tag, qualifier) ->
            val catalog = groovy.json.JsonSlurper().parse(catalogsDirectory.file("$tag.json").get().asFile) as Map<*, *>
            val title = (catalog["share.title"] as String).replace("{app}", appName.get()).replace("&", "&amp;")
                .replace("<", "&lt;").replace("\"", "\\\"").replace("'", "\\'")
            val destination = outputDirectory.file("$qualifier/share_catalog.xml").get().asFile
            destination.parentFile.mkdirs()
            destination.writeText("<resources><string name=\"share_title\">\"$title\"</string></resources>")
        }
    }
}
val generateShareCatalog = tasks.register<GenerateShareCatalogTask>("generateShareCatalog") {
    catalogsDirectory.set(layout.projectDirectory.dir("../../assets/l10n"))
    outputDirectory.set(layout.buildDirectory.dir("generated/res/shareCatalog"))
    appName.set(identity.getProperty("appName"))
}
androidComponents.onVariants { variant ->
    variant.sources.res?.addGeneratedSourceDirectory(generateShareCatalog,
        GenerateShareCatalogTask::outputDirectory)
}
