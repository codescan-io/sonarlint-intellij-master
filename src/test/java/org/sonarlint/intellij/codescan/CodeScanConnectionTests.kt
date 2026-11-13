/*
 * CodeScan for IntelliJ IDEA
 * Copyright (C) 2015-2023 SonarSource SA
 * sonarlint@sonarsource.com
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 3 of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 */
package org.sonarlint.intellij.codescan

import com.github.tomakehurst.wiremock.WireMockServer
import com.github.tomakehurst.wiremock.client.WireMock.get
import com.github.tomakehurst.wiremock.client.WireMock.notFound
import com.github.tomakehurst.wiremock.client.WireMock.okJson
import com.github.tomakehurst.wiremock.core.WireMockConfiguration.wireMockConfig
import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.progress.EmptyProgressIndicator
import com.intellij.testFramework.replaceService
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.PrintStream
import java.net.URI
import java.nio.file.Files
import java.time.Duration
import java.time.Instant
import java.util.concurrent.Callable
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit
import kotlin.io.path.createTempDirectory
import org.assertj.core.api.Assertions.assertThat
import org.assertj.core.api.Assertions.entry
import org.assertj.core.api.Assertions.tuple
import org.awaitility.Awaitility.await
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.mockito.Mockito.mock
import org.mockito.Mockito.verify
import org.mockito.Mockito.`when`
import org.mockito.kotlin.any
import org.mockito.kotlin.argumentCaptor
import org.mockito.kotlin.timeout
import org.sonarlint.intellij.AbstractSonarLintHeavyTests
import org.sonarlint.intellij.SonarLintIntelliJClient
import org.sonarlint.intellij.SonarLintPlugin
import org.sonarlint.intellij.analysis.AnalysisState
import org.sonarlint.intellij.analysis.SonarLintAnalyzer
import org.sonarlint.intellij.common.analysis.AnalysisConfigurator
import org.sonarlint.intellij.common.ui.SonarLintConsole
import org.sonarlint.intellij.common.util.CodeScanServerCheck
import org.sonarlint.intellij.common.util.SonarLintUtils
import org.sonarlint.intellij.common.util.SonarLintUtils.getService
import org.sonarlint.intellij.config.global.ServerConnection
import org.sonarlint.intellij.config.global.ServerConnectionMgmtPanel
import org.sonarlint.intellij.config.global.wizard.WizardModel
import org.sonarlint.intellij.core.BackendService
import org.sonarlint.intellij.java.JavaAnalysisConfigurator
import org.sonarlint.intellij.ui.SonarLintConsoleTestImpl
import org.sonarlint.intellij.util.GlobalLogOutput
import org.sonarsource.sonarlint.core.rpc.client.Sloop
import org.sonarsource.sonarlint.core.rpc.client.SloopLauncher
import org.sonarsource.sonarlint.core.rpc.protocol.SonarLintRpcServer
import org.sonarsource.sonarlint.core.rpc.protocol.backend.binding.BindingRpcService
import org.sonarsource.sonarlint.core.rpc.protocol.backend.branch.SonarProjectBranchRpcService
import org.sonarsource.sonarlint.core.rpc.protocol.backend.config.ConfigurationRpcService
import org.sonarsource.sonarlint.core.rpc.protocol.backend.connection.ConnectionRpcService
import org.sonarsource.sonarlint.core.rpc.protocol.backend.connection.check.CheckSmartNotificationsSupportedParams
import org.sonarsource.sonarlint.core.rpc.protocol.backend.connection.config.DidUpdateConnectionsParams
import org.sonarsource.sonarlint.core.rpc.protocol.backend.connection.org.GetOrganizationParams
import org.sonarsource.sonarlint.core.rpc.protocol.backend.connection.org.ListUserOrganizationsParams
import org.sonarsource.sonarlint.core.rpc.protocol.backend.connection.projects.GetAllProjectsParams
import org.sonarsource.sonarlint.core.rpc.protocol.backend.connection.validate.ValidateConnectionParams
import org.sonarsource.sonarlint.core.rpc.protocol.backend.hotspot.HotspotRpcService
import org.sonarsource.sonarlint.core.rpc.protocol.backend.initialize.InitializeParams
import org.sonarsource.sonarlint.core.rpc.protocol.backend.issue.IssueRpcService
import org.sonarsource.sonarlint.core.rpc.protocol.backend.rules.RulesRpcService
import org.sonarsource.sonarlint.core.rpc.protocol.backend.tracking.ListAllResponse
import org.sonarsource.sonarlint.core.rpc.protocol.backend.tracking.TaintVulnerabilityTrackingRpcService
import org.sonarsource.sonarlint.core.rpc.protocol.client.log.LogLevel
import org.sonarsource.sonarlint.core.rpc.protocol.client.log.LogParams
import org.sonarsource.sonarlint.core.rpc.protocol.common.Language

/**
 * The CodeScan behaviour of the plugin, checked through the code paths users hit:
 * the connection wizard model, the settings sent to the backend at start-up, the analysis settings and the icons.
 * The backend process is replaced by a mock, so these tests read what the plugin sends to it.
 */
class CodeScanConnectionTests : AbstractSonarLintHeavyTests() {

    private lateinit var server: WireMockServer

    override fun initApplication() {
        super.initApplication()
        // Keep the real backend process out of these tests: the application-level service talks to a mock.
        ApplicationManager.getApplication().replaceService(BackendService::class.java, BackendService(launcherFor(mockRpcServer())), testRootDisposable)
        // Each test starts with no kept answers: WireMock ports can repeat between tests.
        ApplicationManager.getApplication().replaceService(CodeScanServerCheck::class.java, CodeScanServerCheck(), testRootDisposable)
    }

    @BeforeEach
    fun startServer() {
        server = WireMockServer(wireMockConfig().dynamicPort())
        server.start()
    }

    @AfterEach
    fun stopServer() {
        server.stop()
        globalSettings.serverConnections = emptyList()
    }

    @Test
    fun defaultCloudAddressIsCodeScan() {
        val connection = WizardModel()
            .setServerType(WizardModel.ServerType.SONARCLOUD)
            .setName("cs")
            .setToken("token")
            .setOrganizationKey("org")
            .createConnection()

        assertThat(connection.hostUrl).isEqualTo(CODESCAN_CLOUD_URL)
        assertThat(connection.isSonarCloud).isTrue()
    }

    @Test
    fun backendStartsWithCodeScanCloudAddress() {
        globalSettings.serverConnections = listOf(
            ServerConnection.newBuilder().setName("cloud").setHostUrl(CODESCAN_CLOUD_URL).setToken("token").setOrganizationKey("org").build()
        )

        withSystemProperties(CLOUD_URL_PROPERTY to null, CLOUD_WEBSOCKET_URL_PROPERTY to null) {
            val params = startBackendAndCaptureInitializeParams()

            assertThat(params.alternativeSonarCloudEnvironment).isNotNull
            assertThat(params.alternativeSonarCloudEnvironment?.uri).isEqualTo(URI.create(CODESCAN_CLOUD_URL))
            assertThat(params.sonarCloudConnections).extracting("connectionId", "organization").containsExactly(tuple("cloud", "org"))
            assertThat(params.sonarQubeConnections).isEmpty()
        }

        withSystemProperties(CLOUD_URL_PROPERTY to "https://eu.codescan.io", CLOUD_WEBSOCKET_URL_PROPERTY to null) {
            val params = startBackendAndCaptureInitializeParams()

            assertThat(params.alternativeSonarCloudEnvironment).isNotNull
            assertThat(params.alternativeSonarCloudEnvironment?.uri).isEqualTo(URI.create("https://eu.codescan.io"))
        }
    }

    @Test
    fun backendFeatureFlagsMatchCodeScan() {
        val flags = startBackendAndCaptureInitializeParams().featureFlags

        assertThat(flags.areTaintVulnerabilitiesEnabled()).`as`("taint vulnerabilities").isFalse()
        assertThat(flags.shouldManageServerSentEvents()).`as`("server-sent events").isFalse()
    }

    @Test
    fun salesforceLanguagesAreAnalysedInConnectedModeOnly() {
        val params = startBackendAndCaptureInitializeParams()

        assertThat(params.extraEnabledLanguagesInConnectedMode).contains(Language.APEX, Language.SF_META, Language.VF)
        assertThat(params.enabledLanguagesInStandaloneMode).doesNotContain(Language.APEX, Language.SF_META, Language.VF)
    }

    @Test
    fun connectedModeUsesOnlyTheServerAnalyzers() {
        val pluginHome = createTempDirectory("codescan-plugin")
        val bundled = Files.createDirectories(pluginHome.resolve("plugins"))
        listOf("sonar-html-plugin-1.0.jar", "sonar-javascript-plugin-1.0.jar", "sonar-xml-plugin-1.0.jar").forEach { Files.createFile(bundled.resolve(it)) }
        val plugin = mock(SonarLintPlugin::class.java)
        `when`(plugin.path).thenReturn(pluginHome)
        `when`(plugin.version).thenReturn("1.0")
        ApplicationManager.getApplication().replaceService(SonarLintPlugin::class.java, plugin, testRootDisposable)

        try {
            val params = startBackendAndCaptureInitializeParams()

            assertThat(params.embeddedPluginPaths).hasSize(3)
            assertThat(params.connectedModeEmbeddedPluginPathsByKey).isEmpty()
        } finally {
            pluginHome.toFile().deleteRecursively()
        }
    }

    @Test
    fun taintTabIsNotShown() {
        // SonarLintToolWindowFactory adds the taint tab only when this is true (script row P8 checks that guard)
        assertThat(SonarLintUtils.isTaintVulnerabilitiesEnabled()).isFalse()
    }

    @Test
    fun codeScanAnalysisSettingsAreSentWithoutTheJavaPlugin() {
        connectProjectTo(cloudConnection(), "projectKey")

        assertThat(settingsFromConfiguratorsOtherThanJava())
            .containsEntry("codescan.ide.type", "IntelliJ IDEA")
            .containsEntry("sonar.host.url", CODESCAN_CLOUD_URL)
            .containsEntry("sonar.organization", "org")
            .containsEntry("sonar.login", TOKEN)
            .containsEntry("sonar.password", "")
    }

    @Test
    fun onlyTheIdeTypeIsSentWhenTheProjectIsNotBound() {
        globalSettings.serverConnections = listOf(cloudConnection())

        assertThat(settingsFromConfiguratorsOtherThanJava()).containsExactly(entry("codescan.ide.type", "IntelliJ IDEA"))
    }

    @Test
    fun tokenIsMaskedInBackendLogs() {
        connectProjectTo(cloudConnection(), "projectKey")
        val globalLog = mock(GlobalLogOutput::class.java)
        ApplicationManager.getApplication().replaceService(GlobalLogOutput::class.java, globalLog, testRootDisposable)
        // the line the backend writes at the start of every analysis
        val line = "Triggering analysis with configuration: [\n  extraProperties: {sonar.login=$TOKEN, codescan.ide.type=IntelliJ IDEA}\n]"

        SonarLintIntelliJClient.log(LogParams(LogLevel.INFO, line, moduleBackendId(module), "stack $TOKEN", Instant.now()))
        SonarLintIntelliJClient.log(LogParams(LogLevel.INFO, line, null, null, Instant.now()))

        assertThat(projectConsoleText()).contains("Triggering analysis").contains("codescan.ide.type=IntelliJ IDEA").doesNotContain(TOKEN)
        val captor = argumentCaptor<String>()
        verify(globalLog).log(captor.capture(), any())
        assertThat(captor.firstValue).contains("Triggering analysis").doesNotContain(TOKEN)
    }

    @Test
    fun tokenIsNotPrintedWhenTheProjectSettingsOverrideIt() {
        connectProjectTo(cloudConnection(), "projectKey")
        projectSettings.additionalProperties = mapOf("sonar.login" to "typed-secret-value")

        // no files: the analysis stops right after the settings are collected
        getService(project, SonarLintAnalyzer::class.java).analyzeModule(module, emptyList(), mock(AnalysisState::class.java), EmptyProgressIndicator(), false)

        assertThat(projectConsoleText()).contains("sonar.login").doesNotContain(TOKEN).doesNotContain("typed-secret-value")
    }

    @Test
    fun invalidDomainIsRejectedByWizard() {
        server.stubFor(get(HEALTH_PATH).willReturn(notFound()))

        // Real CodeScan hosts are recognised from the address alone
        listOf(CODESCAN_CLOUD_URL, "https://eu.codescan.io/", "https://codescan.io", "https://acme.autorabit.com").forEach {
            assertThat(isCodeScanServerOffUiThread(it)).`as`(it).isTrue()
        }
        // Look-alike addresses are not, and neither is a server that does not answer the CodeScan health check
        listOf(
            "https://codescan.io.example.invalid",
            "https://example.invalid/?x=codescan.io",
            "https://example.invalid/codescan.io",
            "https://notcodescan.io.example.invalid",
            "${server.baseUrl()}/?x=codescan.io",
        ).forEach {
            assertThat(isCodeScanServerOffUiThread(it)).`as`(it).isFalse()
        }
        val lookalike = ServerConnection.newBuilder().setName("x").setHostUrl("https://codescan.io.example.invalid").setToken("t").build()
        assertThat(WizardModel(lookalike).serverType).isEqualTo(WizardModel.ServerType.SONARQUBE)
    }

    @Test
    fun selfHostedServerIsRecognisedByItsHealthCheck() {
        server.stubFor(get(HEALTH_PATH).willReturn(okJson("""{"status":"UP"}""")))
        val selfHosted = server.baseUrl()

        assertThat(isCodeScanServerOffUiThread(selfHosted)).isTrue()
        assertThat(isCodeScanServerOffUiThread("$selfHosted/")).isTrue()
        // the answer is kept, so the server is asked only once
        assertThat(server.allServeEvents).hasSize(1)
    }

    @Test
    fun healthCheckNeverBlocksTheUiThread() {
        server.stubFor(get(HEALTH_PATH).willReturn(okJson("""{"status":"UP"}""").withFixedDelay(2_000)))
        val selfHosted = server.baseUrl()

        // This test runs on the UI thread. A server not asked yet counts as "no" at once and is asked in the background.
        val started = System.nanoTime()
        assertThat(SonarLintUtils.isSonarCloudAlias(selfHosted)).isFalse()
        assertThat(Duration.ofNanos(System.nanoTime() - started)).isLessThan(Duration.ofSeconds(1))

        // checked on this (UI) thread too, so the answer must come from the background check
        await().pollInSameThread().atMost(Duration.ofSeconds(15)).until { SonarLintUtils.isSonarCloudAlias(selfHosted) }
        assertThat(server.allServeEvents).hasSize(1)
    }

    @Test
    fun wizardTurnsASelfHostedCodeScanAddressIntoACloudConnection() {
        server.stubFor(get(HEALTH_PATH).willReturn(okJson("""{"status":"UP"}""")))
        val selfHosted = server.baseUrl()

        val codeScan = offUiThread { WizardModel().useServer("$selfHosted/") }
        assertThat(codeScan.serverType).isEqualTo(WizardModel.ServerType.SONARCLOUD)
        assertThat(codeScan.serverUrl).isEqualTo(selfHosted)

        // nothing answers the health check under this path
        val other = offUiThread { WizardModel().useServer("$selfHosted/other") }
        assertThat(other.serverType).isEqualTo(WizardModel.ServerType.SONARQUBE)
        assertThat(other.serverUrl).isEqualTo("$selfHosted/other")
    }

    @Test
    fun selfHostedCustomDomainIsUsedForAllCalls() {
        server.stubFor(get(HEALTH_PATH).willReturn(okJson("""{"status":"UP"}""")))
        val selfHosted = server.baseUrl()
        val connection = ServerConnection.newBuilder().setName("self-hosted").setHostUrl(selfHosted).setToken("token").setOrganizationKey("org").build()
        globalSettings.serverConnections = listOf(connection)

        val params = startBackendAndCaptureInitializeParams()

        // The backend must call the connection's own address, not the global cloud address
        assertThat(params.sonarCloudConnections).extracting("connectionId", "serverUrl").containsExactly(tuple("self-hosted", selfHosted))
        assertThat(connection.links().formattingSyntaxDoc()).startsWith(selfHosted)
        assertThat(server.allServeEvents).allSatisfy { assertThat(it.request.absoluteUrl).startsWith(selfHosted) }
    }

    @Test
    fun wizardCallsForASelfHostedServerGoToThatServer() {
        server.stubFor(get(HEALTH_PATH).willReturn(okJson("""{"status":"UP"}""")))
        val selfHosted = server.baseUrl()
        val model = offUiThread { WizardModel().useServer(selfHosted) }.setName("self-hosted").setToken("token").setOrganizationKey("org")

        val connection = model.createConnection()
        assertThat(connection.hostUrl).isEqualTo(selfHosted)
        assertThat(model.createConnectionWithoutOrganization().hostUrl).isEqualTo(selfHosted)

        val rpcServer = mockRpcServer()
        val service = BackendService(launcherFor(rpcServer))
        service.validateConnection(connection)
        service.checkSmartNotificationsSupported(connection)
        service.getAllProjects(connection)
        service.listUserOrganizations(connection)
        service.getOrganization(connection, "org")

        // The backend must send each of these calls to the connection's own address, not the global cloud address
        val connections = rpcServer.connectionService
        val validate = argumentCaptor<ValidateConnectionParams>()
        verify(connections, timeout(30_000)).validateConnection(validate.capture())
        assertThat(validate.firstValue.transientConnection.right.cloudServerUrl).isEqualTo(selfHosted)
        val notifications = argumentCaptor<CheckSmartNotificationsSupportedParams>()
        verify(connections, timeout(30_000)).checkSmartNotificationsSupported(notifications.capture())
        assertThat(notifications.firstValue.transientConnection.right.cloudServerUrl).isEqualTo(selfHosted)
        val projects = argumentCaptor<GetAllProjectsParams>()
        verify(connections, timeout(30_000)).getAllProjects(projects.capture())
        assertThat(projects.firstValue.transientConnection.right.cloudServerUrl).isEqualTo(selfHosted)
        val organizations = argumentCaptor<ListUserOrganizationsParams>()
        verify(connections, timeout(30_000)).listUserOrganizations(organizations.capture())
        assertThat(organizations.firstValue.serverUrl).isEqualTo(selfHosted)
        val organization = argumentCaptor<GetOrganizationParams>()
        verify(connections, timeout(30_000)).getOrganization(organization.capture())
        assertThat(organization.firstValue.serverUrl).isEqualTo(selfHosted)
    }

    @Test
    fun cloudConnectionWithoutOrganizationDoesNotBlockConnectionUpdates() {
        // e.g. saved as a SonarQube connection while the self-hosted CodeScan server was down; now it answers as CodeScan
        server.stubFor(get(HEALTH_PATH).willReturn(okJson("""{"status":"UP"}""")))
        val selfHosted = server.baseUrl()
        assertThat(isCodeScanServerOffUiThread(selfHosted)).isTrue()
        val withoutOrganization = ServerConnection.newBuilder().setName("no-org").setHostUrl(selfHosted).setToken("token").build()
        val cloud = ServerConnection.newBuilder().setName("cloud").setHostUrl(CODESCAN_CLOUD_URL).setToken("token").setOrganizationKey("org").build()
        val rpcServer = mockRpcServer()
        val service = BackendService(launcherFor(rpcServer))

        service.connectionsUpdated(listOf(withoutOrganization, cloud))

        val update = argumentCaptor<DidUpdateConnectionsParams>()
        verify(rpcServer.connectionService, timeout(30_000)).didUpdateConnections(update.capture())
        assertThat(update.firstValue.sonarCloudConnections).extracting("connectionId").containsExactly("cloud")
    }

    @Test
    fun editingASelfHostedConnectionKeepsItsAddress() {
        server.stubFor(get(HEALTH_PATH).willReturn(okJson("""{"status":"UP"}""")))
        val selfHosted = server.baseUrl()
        val existing = ServerConnection.newBuilder().setName("self-hosted").setHostUrl(selfHosted).setToken("token").setOrganizationKey("org").build()

        val model = offUiThread { WizardModel(existing) }
        assertThat(model.serverType).isEqualTo(WizardModel.ServerType.SONARCLOUD)
        assertThat(model.serverUrl).isEqualTo(selfHosted)
        assertThat(model.usesDefaultCloudServer()).isFalse()
        assertThat(model.createConnection().hostUrl).isEqualTo(selfHosted)
        // the connection list shows the address too, so the user can tell the server apart from the default cloud
        assertThat(ServerConnectionMgmtPanel.shownAddress(existing)).isEqualTo(selfHosted)

        val cloud = ServerConnection.newBuilder().setName("cloud").setHostUrl(CODESCAN_CLOUD_URL).setToken("token").setOrganizationKey("org").build()
        assertThat(WizardModel(cloud).usesDefaultCloudServer()).isTrue()
        assertThat(WizardModel(cloud).createConnection().hostUrl).isEqualTo(CODESCAN_CLOUD_URL)
        assertThat(ServerConnectionMgmtPanel.shownAddress(cloud)).isNull()
        assertThat(WizardModel().usesDefaultCloudServer()).isTrue()
    }

    @Test
    fun noSonarQubeBrandedIconsInUse() {
        val iconsSource = sourceFile("src/main/java/org/sonarlint/intellij/SonarLintIcons.kt").readText()
        val imageByField = Regex("""val\s+(\w+)\s*=\s*getIcon\(\s*"([^"]+)"""").findAll(iconsSource)
            .associate { it.groupValues[1] to it.groupValues[2] }

        CODESCAN_IMAGES.forEach {
            assertThat(sourceFile("src/main/resources$it")).`as`("image file $it").exists()
        }
        assertThat(imageByField.values.toList()).`as`("images loaded by SonarLintIcons.kt").containsAll(CODESCAN_IMAGES)

        val pluginXmls = sourceFile("src/main/resources/META-INF").listFiles { f -> f.name.startsWith("plugin") && f.name.endsWith(".xml") }!!.toList()
        assertThat(pluginXmls).isNotEmpty
        pluginXmls.forEach { xml ->
            val text = xml.readText()
            Regex("""icon="org\.sonarlint\.intellij\.SonarLintIcons\.(\w+)"""").findAll(text).map { it.groupValues[1] }.forEach { field ->
                assertThat(field).`as`("${xml.name} icon field").doesNotContainIgnoringCase("SONARQUBE")
                assertThat(imageByField).`as`("${xml.name} icon field $field").containsKey(field)
                assertThat(imageByField[field]).`as`("${xml.name} icon field $field").doesNotContainPattern(BRANDED)
            }
            Regex("""icon="(/[^"]+)"""").findAll(text).map { it.groupValues[1] }.forEach { path ->
                assertThat(path).`as`("${xml.name} icon path").doesNotContainPattern(BRANDED)
            }
        }

        val pluginXml = sourceFile("src/main/resources/META-INF/plugin.xml").readText()
        val toolWindowField = Regex("""<toolWindow[^>]*icon="org\.sonarlint\.intellij\.SonarLintIcons\.(\w+)"""").find(pluginXml)!!.groupValues[1]
        assertThat(imageByField[toolWindowField]).`as`("tool window icon").isEqualTo("/images/CodeScanToolWindow.svg")
        val toolWindowSwitch = sourceFile("src/main/java/org/sonarlint/intellij/ui/CurrentFilePanel.java").readText()
        Regex("""toolWindow\.setIcon\(([^;]+)\);""").find(toolWindowSwitch)!!.groupValues[1].let { expression ->
            Regex("""SonarLintIcons\.(\w+)""").findAll(expression).map { it.groupValues[1] }.forEach { field ->
                assertThat(imageByField[field]).`as`("tool window icon $field").isEqualTo("/images/CodeScanToolWindow.svg")
            }
        }

        val widget = sourceFile("src/main/java/org/sonarlint/intellij/ui/traffic/light/SonarLintTrafficLightWidget.kt").readText()
        val widgetFields = Regex("""SonarLintIcons\.(\w+)""").findAll(widget).map { it.groupValues[1] }.toSet()
        assertThat(widgetFields).isNotEmpty
        widgetFields.forEach { field ->
            assertThat(imageByField[field]).`as`("status-bar icon $field").isEqualTo("/images/CodeScanAction.svg")
        }

        listOf("src/main", "common/src/main", "git/src/main").map { sourceFile(it) }.filter { it.exists() }.forEach { root ->
            root.walkTopDown().filter { it.isFile && (it.name.endsWith(".kt") || it.name.endsWith(".java")) }.forEach { file ->
                Regex(""""([^"]*images/[^"]*)"""").findAll(file.readText()).map { it.groupValues[1] }.forEach { path ->
                    assertThat(path).`as`("image path in ${file.path}").doesNotContainPattern(BRANDED)
                }
            }
        }
    }

    private fun cloudConnection() =
        ServerConnection.newBuilder().setName("cs").setHostUrl(CODESCAN_CLOUD_URL).setToken(TOKEN).setOrganizationKey("org").build()

    private fun settingsFromConfiguratorsOtherThanJava(): Map<String, String> =
        AnalysisConfigurator.EP_NAME.extensionList
            .filterNot { it is JavaAnalysisConfigurator }
            .flatMap { it.configure(module, emptyList()).extraProperties.entries }
            .associate { it.key to it.value }

    private fun projectConsoleText(): String {
        val out = ByteArrayOutputStream()
        (getService(project, SonarLintConsole::class.java) as SonarLintConsoleTestImpl).flushTo(PrintStream(out, true, Charsets.UTF_8))
        return out.toString(Charsets.UTF_8)
    }

    private fun isCodeScanServerOffUiThread(url: String): Boolean = offUiThread { SonarLintUtils.isSonarCloudAlias(url) }

    private fun <T> offUiThread(block: () -> T): T =
        ApplicationManager.getApplication().executeOnPooledThread(Callable { block() }).get(30, TimeUnit.SECONDS)

    private fun startBackendAndCaptureInitializeParams(): InitializeParams {
        val rpcServer = mockRpcServer()
        val service = BackendService(launcherFor(rpcServer))
        // any call starts the backend; an empty list does not touch the connections on this (UI) thread
        service.connectionsUpdated(emptyList())
        val captor = argumentCaptor<InitializeParams>()
        verify(rpcServer, timeout(30_000)).initialize(captor.capture())
        return captor.firstValue
    }

    private fun withSystemProperties(vararg properties: Pair<String, String?>, block: () -> Unit) {
        val previous = properties.associate { it.first to System.getProperty(it.first) }
        try {
            properties.forEach { (key, value) -> if (value == null) System.clearProperty(key) else System.setProperty(key, value) }
            block()
        } finally {
            previous.forEach { (key, value) -> if (value == null) System.clearProperty(key) else System.setProperty(key, value) }
        }
    }

    companion object {
        private const val CODESCAN_CLOUD_URL = "https://app.codescan.io"
        private const val TOKEN = "cs-test-token-0123456789"
        private const val CLOUD_URL_PROPERTY = "sonarlint.internal.sonarcloud.url"
        private const val CLOUD_WEBSOCKET_URL_PROPERTY = "sonarlint.internal.sonarcloud.websocket.url"
        private const val HEALTH_PATH = "/_codescan/actuator/health"
        private val BRANDED = Regex("(?i)sonarqube|sonarlint|sonarcloud|sonarsource").toPattern()
        private val CODESCAN_IMAGES = listOf(
            "/images/CodeScan.png",
            "/images/CodeScanAction.svg",
            "/images/CodeScanToolWindow.svg",
            "/images/codescan-16.png",
            "/images/codescan-round.png",
            "/images/codescan@2x.png",
        )

        private fun sourceFile(relativePath: String) = File(relativePath).absoluteFile

        private fun mockRpcServer(): SonarLintRpcServer {
            val rpcServer = mock(SonarLintRpcServer::class.java)
            `when`(rpcServer.initialize(any())).thenReturn(CompletableFuture.completedFuture(null))
            `when`(rpcServer.connectionService).thenReturn(mock(ConnectionRpcService::class.java))
            `when`(rpcServer.configurationService).thenReturn(mock(ConfigurationRpcService::class.java))
            `when`(rpcServer.rulesService).thenReturn(mock(RulesRpcService::class.java))
            `when`(rpcServer.issueService).thenReturn(mock(IssueRpcService::class.java))
            `when`(rpcServer.bindingService).thenReturn(mock(BindingRpcService::class.java))
            `when`(rpcServer.hotspotService).thenReturn(mock(HotspotRpcService::class.java))
            `when`(rpcServer.sonarProjectBranchService).thenReturn(mock(SonarProjectBranchRpcService::class.java))
            val taintService = mock(TaintVulnerabilityTrackingRpcService::class.java)
            `when`(taintService.listAll(any())).thenReturn(CompletableFuture.completedFuture(ListAllResponse(emptyList())))
            `when`(rpcServer.taintVulnerabilityTrackingService).thenReturn(taintService)
            return rpcServer
        }

        private fun launcherFor(rpcServer: SonarLintRpcServer): SloopLauncher {
            val sloop = mock(Sloop::class.java)
            `when`(sloop.rpcServer).thenReturn(rpcServer)
            // the mocked backend never exits
            `when`(sloop.onExit()).thenReturn(CompletableFuture())
            val launcher = mock(SloopLauncher::class.java)
            `when`(launcher.start(any(), any(), any())).thenReturn(sloop)
            return launcher
        }
    }
}
