group = "org.twimshelf.tl_llama"
version = "1.0"

plugins {
    id("com.android.library")
}

android {
    namespace = "org.twimshelf.tl_llama"
    compileSdk = 36
    // Vulkan 1.2 (llama.cpp's GPU backend) is checked at run time; older devices use the CPU
    defaultConfig {
        // as the app; the Vulkan backend links functions the libvulkan of older levels does not have
        minSdk = 31
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
        externalNativeBuild {
            cmake {
                arguments += listOf("-DANDROID_STL=c++_shared", "-DTL_LLAMA_VULKAN=ON", "-DTL_LLAMA_OPENCL=ON")
                // a local llama.cpp checkout instead of the download: -PtlLlamaSource=/path
                (project.findProperty("tlLlamaSource") as String?)?.let { arguments += "-DTL_LLAMA_SOURCE=$it" }
            }
        }
    }
    externalNativeBuild {
        cmake {
            path = file("../src/CMakeLists.txt")
            version = "3.31.6"
            // where .cxx really is (build.dir): llama.cpp's shader step cannot take a path with spaces
            buildStagingDirectory = file(".cxx").canonicalFile
        }
    }
}
