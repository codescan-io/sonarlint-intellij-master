import com.jetbrains.plugin.blockmap.core.BlockMap
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.FileInputStream
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.Paths
import java.util.EnumSet
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import java.util.zip.ZipOutputStream
import org.apache.commons.compress.archivers.tar.TarArchiveInputStream
import org.apache.commons.compress.compressors.gzip.GzipCompressorInputStream
import org.jetbrains.intellij.platform.gradle.IntelliJPlatformType
import org.jetbrains.intellij.platform.gradle.TestFrameworkType
import org.jetbrains.intellij.platform.gradle.models.ProductRelease
import org.jetbrains.intellij.platform.gradle.tasks.RunIdeTask
import org.jetbrains.intellij.platform.gradle.tasks.VerifyPluginTask
import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.dsl.KotlinVersion

plugins {
    java
    alias(libs.plugins.kotlin)
    id("org.jetbrains.intellij.platform")
    alias(libs.plugins.sonarqube)
    jacoco
    alias(libs.plugins.license)
    alias(libs.plugins.artifactory)
    idea
    signing
    alias(libs.plugins.cyclonedx)
}

buildscript {
    repositories {
        mavenCentral()
    }
    dependencies {
        "classpath"(group = "org.jetbrains.intellij", name = "blockmap", version = "1.0.7")
    }
}

group = "com.villagechief.sonarlint.intellij"
description = "CodeScan for IntelliJ IDEA"

val intellijBuildVersion: String by project
val ideaHome: String? = System.getenv("IDEA_HOME")
val runIdeDirectory: String by project
val verifierVersions: String by project
val verifierEnv: String by project

configurations {
    val sqplugins = create("sqplugins") { isTransitive = false }
    register("sqplugins_deps") {
        extendsFrom(sqplugins)
        isTransitive = true
    }
    register("sloop")
}

java {
    toolchain {
        languageVersion.set(JavaLanguageVersion.of(17))
    }
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    intellijPlatform {
        if (!ideaHome.isNullOrBlank()) {
            local(ideaHome)
        } else {
            intellijIdeaCommunity(intellijBuildVersion)
        }
        pluginComposedModule(implementation(project(":common")))
        pluginComposedModule(runtimeOnly(project(":git")))
        bundledPlugins("com.intellij.java", "Git4Idea")
        testFramework(TestFrameworkType.Platform)
        pluginVerifier()
    }
    implementation(libs.sonarlint.java.client.utils)
    implementation(libs.sonarlint.rpc.java.client)
    implementation(libs.sonarlint.rpc.impl)
    implementation(libs.commons.langs3)
    implementation(libs.commons.text)
    compileOnly(libs.findbugs.jsr305)
    testImplementation(libs.junit.four)
    testImplementation(libs.junit.jupiter)
    testImplementation(libs.assertj.core)
    testImplementation(libs.mockito.core)
    testImplementation(libs.mockito.kotlin)
    testImplementation(libs.awaitility)
    testImplementation(libs.wiremock)
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
    "sqplugins"(libs.bundles.sonar.analyzers)
    "sloop"("org.sonarsource.sonarlint.core:sonarlint-backend-cli:${libs.versions.sonarlint.core.get()}:no-arch@zip")
}

val bomFile = layout.buildDirectory.file("reports/bom.json")
artifacts.add("archives", bomFile.get().asFile) {
    name = "codescan-intellij"
    type = "json"
    classifier = "cyclonedx"
    builtBy("cyclonedxBom")
}

license {
    header = rootProject.file("HEADER")
    mapping(
        mapOf(
            "java" to "SLASHSTAR_STYLE",
            "kt" to "SLASHSTAR_STYLE",
            "svg" to "XML_STYLE",
            "form" to "XML_STYLE"
        )
    )
    excludes(
        listOf("**/*.jar", "**/*.png", "**/README")
    )
    strictCheck = true
}

intellijPlatform {
    // The sandbox folder, the plugin folder inside the zip and the zip name (CodeScan-<version>.zip) all use this name.
    projectName = "CodeScan"
    pluginConfiguration {
        name = "CodeScan"
        ideaVersion {
            // 2023.1 is the oldest supported IDE. No until-build: the plugin also loads in newer IDEs.
            sinceBuild = "231"
            untilBuild = provider { null }
        }
    }
    buildSearchableOptions = true
    pluginVerification {
        // The published plugin ID com.code-scan.intellij contains the word "intellij", which the verifier rejects for new
        // plugins. Changing the ID would cut existing users off from updates, so this one check is muted.
        freeArgs = listOf("-mute", "TemplateWordInPluginId")
        // These are the only problems we tolerate; any other kind (compatibility problems, internal API use, ...) fails the task.
        val tolerated = EnumSet.of(
            VerifyPluginTask.FailureLevel.DEPRECATED_API_USAGES,
            VerifyPluginTask.FailureLevel.EXPERIMENTAL_API_USAGES,
            VerifyPluginTask.FailureLevel.NOT_DYNAMIC,
            VerifyPluginTask.FailureLevel.OVERRIDE_ONLY_API_USAGES,
            VerifyPluginTask.FailureLevel.MISSING_DEPENDENCIES,
            VerifyPluginTask.FailureLevel.SCHEDULED_FOR_REMOVAL_API_USAGES,
        )
        failureLevel = EnumSet.complementOf(tolerated).toList()

        val ideTypes = listOf(IntelliJPlatformType.IntellijIdeaCommunity, IntelliJPlatformType.IntellijIdeaUltimate)

        when {
            // -PverifierVersions=IC-2023.1.7,IU-2026.1.5 checks exactly these IDEs
            project.hasProperty("verifierVersions") -> ides {
                verifierVersions.split(',').map { it.trim() }.filter { it.isNotEmpty() }.forEach {
                    create(it.substringBefore('-'), it.substringAfter('-'))
                }
            }
            // -PverifierEnv=MINIMAL|LATEST|EAP checks every IntelliJ IDEA release of that line
            project.hasProperty("verifierEnv") -> when (verifierEnv) {
                "EAP" -> ides {
                    select {
                        types = ideTypes
                        channels = listOf(ProductRelease.Channel.EAP)
                        sinceBuild = "261"
                    }
                }
                "MINIMAL" -> ides {
                    select {
                        types = ideTypes
                        channels = listOf(ProductRelease.Channel.RELEASE)
                        sinceBuild = "231"
                        untilBuild = "231.*"
                    }
                }
                "LATEST" -> ides {
                    select {
                        types = ideTypes
                        channels = listOf(ProductRelease.Channel.RELEASE)
                        sinceBuild = "261"
                    }
                }
                else -> throw GradleException("Unknown verifierEnv '$verifierEnv', use MINIMAL, LATEST or EAP")
            }
            // Default: the oldest supported IDE, some releases in between, the last Community release and a recent one
            else -> ides {
                create(IntelliJPlatformType.IntellijIdeaCommunity, "2023.1.7")
                create(IntelliJPlatformType.IntellijIdeaCommunity, "2024.1.7")
                create(IntelliJPlatformType.IntellijIdeaCommunity, "2024.3.6")
                select {
                    types = listOf(IntelliJPlatformType.IntellijIdeaCommunity)
                    channels = listOf(ProductRelease.Channel.RELEASE)
                    sinceBuild = "252"
                    untilBuild = "252.*"
                }
                create(IntelliJPlatformType.IntellijIdeaUltimate, "2026.1.5")
            }
        }
    }
}

intellijPlatformTesting {
    runIde {
        // Used by `./gradlew runIde -PrunIdeDirectory=<IDE folder>`, see tasks.runIde below
        register("runLocalIde") {
            if (project.hasProperty("runIdeDirectory")) {
                localPath = file(runIdeDirectory)
            }
            sandboxDirectory = project.layout.buildDirectory.dir("codescan-local-ide")
            prepareSandboxTask {
                doLast {
                    setupSandbox(destinationDir, pluginName)
                }
            }
        }
    }
}

fun setupSandbox(destinationDir: File, pluginName: Property<String>) {
    val pluginsDir = file("$destinationDir/${pluginName.get()}/plugins")

    copyPlugins(pluginsDir)
    copySloop(destinationDir, pluginName)
    unzipEslintBridgeBundle(pluginsDir)
}

fun copyPlugins(pluginsDir: File) {
    copy {
        from(project.configurations["sqplugins"])
        into(pluginsDir)
    }
}

fun copySloop(destinationDir: File, pluginName: Property<String>) {
    configurations["sloop"].resolvedConfiguration.resolvedArtifacts.forEach { artifact ->
        copy {
            from(zipTree(artifact.file))
            into(file("$destinationDir/${pluginName.get()}/sloop/"))
        }
    }
}

fun unzipEslintBridgeBundle(pluginsDir: File) {
    val jarPath = pluginsDir.listFiles()?.find {
        it.name.startsWith("sonar-javascript-plugin-") && it.name.endsWith(".jar")
    } ?: throw GradleException("sonar-javascript-plugin-* JAR not found in $pluginsDir")

    ZipFile(jarPath).use { zipFile ->
        val entry = zipFile.entries().asSequence().find { it.name.matches(Regex("sonarjs-.*\\.tgz")) }
            ?: throw GradleException("eslint bridge server bundle not found in JAR $jarPath")

        val outputFolderPath = Paths.get("$pluginsDir/eslint-bridge")
        val outputFilePath = outputFolderPath.resolve(entry.name)

        Files.createDirectories(outputFolderPath)

        zipFile.getInputStream(entry).use { input ->
            Files.copy(input, outputFilePath)
        }

        GzipCompressorInputStream(Files.newInputStream(outputFilePath)).use { gzipInput ->
            TarArchiveInputStream(gzipInput).use { tarInput ->
                generateSequence { tarInput.nextEntry }
                    .forEach { tarEntry ->
                        val outputFile = outputFolderPath.resolve(tarEntry.name).toFile()
                        if (tarEntry.isDirectory) {
                            outputFile.mkdirs()
                        } else {
                            outputFile.parentFile.mkdirs()
                            Files.copy(tarInput, outputFile.toPath())
                        }
                    }
            }
        }
        Files.deleteIfExists(outputFilePath)
    }
}

configurations.archives.get().isCanBeResolved = true

tasks {
    compileKotlin {
        compilerOptions {
            // 2023.1 (since-build 231) bundles the Kotlin 1.8 standard library, which the plugin uses at run time
            apiVersion.set(KotlinVersion.KOTLIN_1_8)
            jvmTarget.set(JvmTarget.JVM_17)
        }
    }

    compileTestKotlin {
        compilerOptions {
            apiVersion.set(KotlinVersion.KOTLIN_1_8)
            jvmTarget.set(JvmTarget.JVM_17)
        }
    }

    jar {
        archiveClassifier = ""
    }

    withType<RunIdeTask>().configureEach {
        systemProperty("sonarlint.telemetry.disabled", "true")
        // uncomment to customize the SonarCloud URL
        //systemProperty("sonarlint.internal.sonarcloud.url", "https://sonarcloud.io/")
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

    runIde {
        // With -PrunIdeDirectory, start that installed IDE instead of the downloaded one (through runLocalIde).
        if (project.hasProperty("runIdeDirectory")) {
            dependsOn("runLocalIde")
            onlyIf("runLocalIde started the IDE from runIdeDirectory instead") { false }
        }
    }

    test {
        useJUnitPlatform()
        systemProperty("sonarlint.telemetry.disabled", "true")
        // On macOS the temp folder /var/folders/... is a link to /private/var/folders/..., and JavaAnalysisConfiguratorTests compares
        // the paths it sets up with their real paths. Use the real path of the same folder; on Linux nothing changes.
        systemProperty("java.io.tmpdir", File(System.getProperty("java.io.tmpdir")).canonicalPath)
    }

    prepareSandbox {
        doLast {
            setupSandbox(destinationDir, pluginName)
        }
    }

    prepareTestSandbox {
        doLast {
            setupSandbox(destinationDir, pluginName)
        }
    }

    cyclonedxBom {
        setIncludeConfigs(listOf("runtimeClasspath", "sqplugins_deps"))
        inputs.files(configurations.runtimeClasspath, configurations.archives.get())
        mustRunAfter(
            getTasksByName("buildPluginBlockmap", true)
        )
    }

    val buildPluginBlockmap by registering {
        inputs.file(buildPlugin.get().archiveFile)
        doLast {
            val distribZip = buildPlugin.get().archiveFile.get().asFile
            artifacts.add("archives", distribZip) {
                name = project.name
                extension = "zip"
                type = "zip"
                builtBy("buildPluginBlockmap")
            }
            val blockMapBytes =
                com.fasterxml.jackson.databind.ObjectMapper().writeValueAsBytes(BlockMap(distribZip.inputStream()))
            val blockMapFile = File(distribZip.parentFile, "blockmap.json")
            blockMapFile.writeBytes(blockMapBytes)
            val blockMapFileZipFile = file(distribZip.absolutePath + ".blockmap.zip")
            val blockMapFileZip = ZipOutputStream(BufferedOutputStream(FileOutputStream(blockMapFileZipFile)))
            val fi = FileInputStream(blockMapFile)
            val origin = BufferedInputStream(fi)
            val entry = ZipEntry(blockMapFile.name)
            blockMapFileZip.putNextEntry(entry)
            origin.copyTo(blockMapFileZip, 1024)
            origin.close()
            blockMapFileZip.close()
            artifacts.add("archives", blockMapFileZipFile) {
                name = project.name
                extension = "zip.blockmap.zip"
                type = "zip"
                builtBy("buildPluginBlockmap")
            }
            val fileHash = com.fasterxml.jackson.databind.ObjectMapper()
                .writeValueAsString(com.jetbrains.plugin.blockmap.core.FileHash(distribZip.inputStream()))
            val fileHashJsonFile = file(distribZip.absolutePath + ".hash.json")
            fileHashJsonFile.writeText(fileHash)
            artifacts.add("archives", fileHashJsonFile) {
                name = project.name
                extension = "zip.hash.json"
                type = "json"
                builtBy("buildPluginBlockmap")
            }
        }
    }

    buildPlugin {
        finalizedBy(buildPluginBlockmap)
    }

    withType<Test> {
        configure<JacocoTaskExtension> {
            isIncludeNoLocationClasses = true
            excludes = listOf("jdk.internal.*")
        }
    }

    jacocoTestReport {
        classDirectories.setFrom(files("build/instrumented/instrumentCode"))
        reports {
            xml.required.set(true)
        }
    }

    artifactoryPublish {
        mustRunAfter(
            getTasksByName("cyclonedxBom", true),
            buildPlugin,
            getTasksByName("buildPluginBlockmap", true)
        )
    }
}

sonar {
    properties {
        property("sonar.projectName", "CodeScan for IntelliJ IDEA")
    }
}

artifactory {
    clientConfig.info.buildName = "codescan-intellij"
    clientConfig.info.buildNumber = System.getenv("BUILD_ID")
    clientConfig.isIncludeEnvVars = true
    clientConfig.envVarsExcludePatterns = "*password*,*PASSWORD*,*secret*,*MAVEN_CMD_LINE_ARGS*,sun.java.command,*token*,*TOKEN*,*LOGIN*,*login*,*key*,*KEY*,*PASSPHRASE*,*signing*"
    clientConfig.info.addEnvironmentProperty(
        "ARTIFACTS_TO_DOWNLOAD",
        "com.villagechief.sonarlint.intellij:codescan-intellij:zip,com.villagechief.sonarlint.intellij:codescan-intellij:json:cyclonedx"
    )
    setContextUrl(System.getenv("ARTIFACTORY_URL"))
    publish {
        repository {
            setProperty("repoKey", System.getenv("ARTIFACTORY_DEPLOY_REPO"))
            setProperty("username", System.getenv("ARTIFACTORY_DEPLOY_USERNAME"))
            setProperty("password", System.getenv("ARTIFACTORY_DEPLOY_PASSWORD"))
        }
        defaults {
            setProperties(
                mapOf(
                    "vcs.revision" to System.getenv("CIRRUS_CHANGE_IN_REPO"),
                    "vcs.branch" to (System.getenv("CIRRUS_BASE_BRANCH")
                        ?: System.getenv("CIRRUS_BRANCH")),
                    "build.name" to "codescan-intellij",
                    "build.number" to System.getenv("BUILD_ID")
                )
            )
            publishConfigs("archives")
            setPublishPom(true)
            setPublishIvy(false)
        }
    }
}

signing {
    setRequired {
        val branch = System.getenv("CIRRUS_BRANCH") ?: ""
        val pr = System.getenv("CIRRUS_PR") ?: ""
        (branch == "master" || branch.matches("branch-[\\d.]+".toRegex())) &&
            pr == "" &&
            gradle.taskGraph.hasTask(":artifactoryPublish")
    }
    val signingKeyId: String? by project
    val signingKey: String? by project
    val signingPassword: String? by project
    useInMemoryPgpKeys(signingKeyId, signingKey, signingPassword)
    sign(configurations.archives.get())
}
