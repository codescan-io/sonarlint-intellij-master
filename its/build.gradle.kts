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
// The port of the WireMock copy of CodeScan: the tests start it there and the UI-test IDE uses it as its CodeScan URL.
val wiremockPort: String = providers.gradleProperty("wiremockPort").getOrElse("18089")
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
    testImplementation(libs.wiremock)
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
        systemProperty("its.wiremock.port", wiremockPort)
        // Each run drives a live IDE: an earlier result, from this build or from the build cache, never counts.
        outputs.upToDateWhen { false }
        outputs.doNotCacheIf("it drives a live IDE") { true }
        finalizedBy("checkIdeLog")
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
                // Any slow operation on the UI thread is logged as an error, which checkIdeLog then reports.
                "-Dide.slow.operations.assertion=true",
                "-Didea.is.internal=true",
                // CodeScan is the WireMock copy the tests start (no WebSocket: CodeScan has none).
                "-Dsonarlint.internal.sonarcloud.url=http://localhost:$wiremockPort",
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

// The UI tests fail if the IDE they drove logged a slow operation on the UI thread, wrong-thread access, a freeze or a
// CodeScan error (scripts/qa/scan-ide-logs.sh). It also runs when the tests fail. -PideLogDir=<folder> checks another
// IDE log folder instead of the runIdeForUiTests sandbox one.
// Run after :its:test, it reads the log while the IDE is still running, so it misses what the IDE logs while closing.
// scripts/qa/run-ide-scenarios.sh checks the log again after the IDE has stopped.
val checkIdeLog by tasks.registering(Exec::class) {
    group = "verification"
    description = "Checks the UI-test IDE's idea.log for slow operations on the UI thread and CodeScan errors."
    val logDir = providers.gradleProperty("ideLogDir").map { file(it) }
        .orElse(runIdeForUiTests.flatMap { it.task }.flatMap { it.sandboxLogDirectory }.map { it.asFile })
    val script = rootProject.file("scripts/qa/scan-ide-logs.sh")
    val report = layout.buildDirectory.file("reports/ide-log-check/scan.txt")
    executable = "bash"
    argumentProviders += CommandLineArgumentProvider {
        listOf(script.path, logDir.get().path, report.get().asFile.path)
    }
    // The IDE keeps writing its log while it runs, so an earlier result never counts.
    outputs.upToDateWhen { false }
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
    // The CodeScan recordings are WireMock JSON copied unchanged from sonarlint-core; JSON has no comment syntax for a header.
    excludes(listOf("**/*.jar", "**/*.png", "**/README", "**.xml", "**/codescan-wiremock/*.json"))
}
