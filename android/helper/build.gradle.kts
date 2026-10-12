buildscript {
    dependencies {
        // AGP 9.x ships built-in Kotlin, but its bundled KGP is older than the
        // Java 25 bytecode target. AGP explicitly supports overriding KGP via
        // the buildscript classpath; keep the KGP pin aligned with reviewed updates.
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:2.4.21")
    }
}

plugins {
    id("com.android.application") version "9.4.1" apply false
}
