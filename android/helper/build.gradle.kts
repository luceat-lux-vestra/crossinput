buildscript {
    dependencies {
        // AGP 9.x ships built-in Kotlin, but its bundled KGP is older than the
        // Java 25 bytecode target. AGP explicitly supports overriding KGP via
        // the buildscript classpath; Kotlin 2.4.20 is the current stable line.
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:2.4.20")
    }
}

plugins {
    id("com.android.application") version "9.4.0" apply false
}
