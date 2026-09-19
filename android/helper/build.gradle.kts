buildscript {
    dependencies {
        // AGP 9.x ships built-in Kotlin, but its bundled KGP is older than the
        // Java 25 bytecode target. AGP explicitly supports overriding KGP via
        // the buildscript classpath; Kotlin 2.4.10 is the current stable line.
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:2.4.10")
    }
}

plugins {
    id("com.android.application") version "9.4.0" apply false
}
