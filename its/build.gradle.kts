import org.jetbrains.intellij.platform.gradle.TestFrameworkType

plugins {
    id("org.jetbrains.intellij.platform")
    alias(libs.plugins.cyclonedx)
    alias(libs.plugins.license)
    alias(libs.plugins.kotlin)
}

apply(from = "${rootProject.projectDir}/gradle/module-conventions.gradle")

val intellijBuildVersion: String by project
val ijVersion: String by project
val runIdeDirectory: String by project
group = "org.sonarsource.sonarlint.intellij.its"
description = "ITs for SonarLint IntelliJ"

intellijPlatform {
    projectName = "sonarlint-intellij-its"
    buildSearchableOptions = false
}

dependencies {
    intellijPlatform {
        if (project.hasProperty("ijVersion")) {
            val type = ijVersion.split('-')[0]
            val version = ijVersion.split('-')[1]
            create(type, version)
        } else {
            intellijIdeaCommunity(intellijBuildVersion)
        }
        testFramework(TestFrameworkType.Platform)
        testFramework(TestFrameworkType.Bundled)
    }
    testImplementation("org.sonarsource.orchestrator:sonar-orchestrator-junit5:5.1.0.2254") {
        exclude(group = "org.slf4j", module = "log4j-over-slf4j")
    }
    testImplementation(libs.its.sonar.scala)
    testImplementation(libs.its.sonar.ws)
    testImplementation(libs.bundles.its.remote)
    testImplementation(libs.junit.jupiter)
    testImplementation(libs.assertj.core)
    testImplementation(libs.junit.four)
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}

tasks {
    test {
        useJUnitPlatform {
            val tag = System.getenv("TEST_SUITE")
            if (tag != null && (tag == "OpenInIdeTests" || tag == "ConnectedAnalysisTests"
                    || tag == "ConfigurationTests" || tag == "Standalone")) {
                includeTags(tag)
            }
        }
        testLogging.showStandardStreams = true
    }
    // This project is a test helper, not a shipped plugin, and has no IDE list for the plugin verifier.
    // Without this, a root-level `./gradlew verifyPlugin` fails with "No IDE resolved for verification".
    verifyPlugin {
        enabled = false
    }
    // UI tests start their IDE through runIdeForUiTests. Without this, a root-level `./gradlew runIde` would also start
    // a second, plugin-less IDE from this project.
    runIde {
        enabled = false
    }
}

// Started by the root `./gradlew runIde -PrunIdeDirectory=<IDE folder>`: runs the CodeScan plugin in that installed IDE.
// It lives here, not in the root project, because plugin 2.7.2 mixes up bundled-plugin paths when one project knows
// two IDEs (see the runIde comment in the root build.gradle.kts).
val runLocalIde by intellijPlatformTesting.runIde.registering {
    if (project.hasProperty("runIdeDirectory")) {
        localPath = file(runIdeDirectory)
    }
    sandboxDirectory = rootProject.layout.buildDirectory.dir("codescan-local-ide")

    prepareSandboxTask {
        // Keep only CodeScan: without this, this test helper project would load as a plugin as well.
        doLast {
            delete(destinationDir.resolve(pluginName.get()))
        }
    }

    task {
        onlyIf("runIdeDirectory is set") { project.hasProperty("runIdeDirectory") }
        systemProperty("sonarlint.telemetry.disabled", "true")
        maxHeapSize = "2g"
        // Debugging is off by default. `-Pdebug` opens port 5005 for a debugger; the IDE does not wait for it.
        if (project.hasProperty("debug")) {
            debugOptions {
                enabled = true
                port = 5005
                suspend = false
            }
        }
    }

    plugins {
        localPlugin(rootProject.dependencies.project(":"))
    }
}

val runIdeForUiTests by intellijPlatformTesting.runIde.registering {
    if (project.hasProperty("runIdeDirectory")) {
        localPath = file(runIdeDirectory)
    }

    task {
        jvmArgumentProviders += CommandLineArgumentProvider {
            listOf(
                "-Xmx1G",
                "-Drobot-server.port=8082",
                "-Dsonarlint.internal.sonarcloud.url=https://sc-staging.io",
                "-Dsonarlint.internal.sonarcloud.websocket.url=wss://events-api.sc-staging.io/",
                "-Dsonarlint.telemetry.disabled=true",
                "-Dsonarlint.logs.verbose=true",
                "-Didea.trust.all.projects=true",
                "-Dide.show.tips.on.startup.default.value=false",
                "-Dide.experimental.ui.navbar.scroll=true",
                "-Djb.privacy.policy.text=<!--999.999-->",
                "-Djb.consents.confirmation.enabled=false",
                "-Deap.require.license=true"
            )
        }

        doFirst {
            if (project.hasProperty("slPluginDirectory")) {
                copy {
                    from(project.property("slPluginDirectory"))
                    into(sandboxPluginsDirectory)
                }
            }
        }
    }

    plugins {
        robotServerPlugin(libs.versions.its.remote.get())
        // Only depend on building the root project plugin if slPluginDirectory is not provided
        if (!project.hasProperty("slPluginDirectory")) {
            localPlugin(rootProject.dependencies.project(":"))
        }
    }
}

intellijPlatform {
    pluginConfiguration {
        ideaVersion {
            sinceBuild = "231"
        }
        name = "sonarlint-intellij-its"
    }
    instrumentCode.set(false)
}

license {
    // exclude file from resources (workaround for https://github.com/hierynomus/license-gradle-plugin/issues/145)
    excludes(listOf("**/*.jar", "**/*.png", "**/README", "**.xml"))
}
