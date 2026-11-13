import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.dsl.KotlinVersion

val intellijBuildVersion: String by project
val ideaHome: String? = System.getenv("IDEA_HOME")

plugins {
    id("org.jetbrains.intellij.platform.module")
    alias(libs.plugins.cyclonedx)
    alias(libs.plugins.license)
    alias(libs.plugins.kotlin)
}

apply(from = "${rootProject.projectDir}/gradle/module-conventions.gradle")

// The oldest supported IDE (2023.1, since-build 231) bundles the Kotlin 1.8 standard library, and the plugin uses the
// IDE's copy (kotlin.stdlib.default.dependency=false). Newer library calls would fail at run time there.
kotlin {
    compilerOptions {
        apiVersion.set(KotlinVersion.KOTLIN_1_8)
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

dependencies {
    intellijPlatform {
        if (!ideaHome.isNullOrBlank()) {
            local(ideaHome)
        } else {
            intellijIdeaCommunity(intellijBuildVersion)
        }
        pluginComposedModule(implementation(project(":common")))
        bundledPlugins("Git4Idea")
    }
}
