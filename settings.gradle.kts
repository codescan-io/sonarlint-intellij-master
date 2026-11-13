import org.jetbrains.intellij.platform.gradle.extensions.intellijPlatform

plugins {
    id("org.jetbrains.intellij.platform.settings") version "2.7.2"
    id("org.gradle.toolchains.foojay-resolver-convention") version "0.9.0"
}

rootProject.name = "codescan-intellij"

// CodeScan libraries come from AWS CodeArtifact. Run `eval "$(./scripts/codeartifact-bootstrap.sh)"` first to set
// CODEARTIFACT_MAVEN_URL and CODEARTIFACT_AUTH_TOKEN, or put codeartifactAuthToken in ~/.gradle/gradle.properties.
val codeartifactMavenUrl: String = providers.environmentVariable("CODEARTIFACT_MAVEN_URL")
    .getOrElse("https://autorabit-artifacts-domain-261140574810.d.codeartifact.us-east-1.amazonaws.com/maven/codescan-libs-release/")
val codeartifactAuthToken: String = providers.environmentVariable("CODEARTIFACT_AUTH_TOKEN")
    .orElse(providers.gradleProperty("codeartifactAuthToken"))
    .getOrElse("")

dependencyResolutionManagement {
    @Suppress("UnstableApiUsage")
    repositoriesMode = RepositoriesMode.FAIL_ON_PROJECT_REPOS

    @Suppress("UnstableApiUsage")
    repositories {
        // The CodeScan build of sonarlint-core is installed locally (`./mvnw install` in sonarlint-core)
        mavenLocal {
            content {
                includeVersionByRegex("org\\.sonarsource\\.sonarlint\\.core", ".*", ".*-CODESCAN")
            }
        }
        maven(codeartifactMavenUrl) {
            name = "codeartifact"
            credentials {
                username = "aws"
                password = codeartifactAuthToken
            }
            content {
                includeGroup("com.villagechief.codescan.thirdparty")
                includeVersionByRegex(".*", ".*", ".*-CODESCAN")
            }
        }
        mavenCentral {
            content {
                // avoid dependency confusion
                excludeGroupByRegex("com\\.sonarsource.*")
            }
        }
        intellijPlatform {
            defaultRepositories()
        }
    }
}

include("its", "common", "git")

val isCiServer = System.getenv().containsKey("CIRRUS_CI")
val isMasterBranch = System.getenv()["CIRRUS_BRANCH"] == "master"
val buildCacheHost: String = System.getenv().getOrDefault("CIRRUS_HTTP_CACHE_HOST", "localhost:12321")
buildCache {
    local {
        isEnabled = !isCiServer
    }
    remote<HttpBuildCache> {
        url = uri("http://${buildCacheHost}/")
        isEnabled = isCiServer
        isPush = isMasterBranch
    }
}
