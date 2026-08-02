plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.crossinput.helper"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.crossinput.helper"
        minSdk = 24
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildTypes {
        debug {
            // app_process 실행을 위해 debug build 사용 (release는 path 하드코딩 문제 회피)
        }
    }
}
