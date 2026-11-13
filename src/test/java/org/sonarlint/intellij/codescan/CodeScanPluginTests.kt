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

import com.intellij.ide.plugins.PluginManagerCore
import com.intellij.notification.NotificationGroupManager
import com.intellij.openapi.actionSystem.ActionManager
import com.intellij.openapi.actionSystem.ex.ActionManagerEx
import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.extensions.PluginId
import com.intellij.openapi.options.Configurable
import com.intellij.openapi.wm.ToolWindowEP
import com.intellij.util.ui.UIUtil
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths
import javax.swing.JCheckBox
import kotlin.io.path.extension
import kotlin.io.path.readText
import org.assertj.core.api.Assertions.assertThat
import org.junit.jupiter.api.Test
import org.mockito.Mockito.mock
import org.mockito.Mockito.verifyNoInteractions
import org.sonarlint.intellij.AbstractSonarLintHeavyTests
import org.sonarlint.intellij.SonarLintPlugin
import org.sonarlint.intellij.actions.MarkAsResolvedAction
import org.sonarlint.intellij.actions.ReviewSecurityHotspotAction
import org.sonarlint.intellij.common.analysis.AnalysisConfigurator
import org.sonarlint.intellij.common.analysis.FileExclusionContributor
import org.sonarlint.intellij.common.analysis.FilesContributor
import org.sonarlint.intellij.common.util.SonarLintUtils.getService
import org.sonarlint.intellij.common.vcs.VcsRepoProvider
import org.sonarlint.intellij.config.SonarLintColorSettingsPage
import org.sonarlint.intellij.config.global.SonarLintAboutPanel
import org.sonarlint.intellij.config.global.SonarLintGlobalConfigurable
import org.sonarlint.intellij.java.JavaAnalysisConfigurator
import org.sonarlint.intellij.telemetry.SonarLintTelemetry
import org.sonarlint.intellij.ui.CurrentFilePanel
import org.sonarlint.intellij.ui.SonarLintToolWindowFactory

/**
 * How the plugin presents itself to the IDE, read from the plugin the test IDE has loaded.
 */
class CodeScanPluginTests : AbstractSonarLintHeavyTests() {

    @Test
    fun pluginIsInstalledUnderTheCodeScanId() {
        val plugin = PluginManagerCore.getPlugin(PluginId.getId(CODESCAN_PLUGIN_ID))

        assertThat(plugin).`as`("plugin $CODESCAN_PLUGIN_ID").isNotNull
        assertThat(plugin!!.name).isEqualTo("CodeScan")
        assertThat(getService(SonarLintPlugin::class.java).path).isEqualTo(plugin.pluginPath)
    }

    @Test
    fun backendFilesAreInThePluginFolder() {
        // BackendService starts the backend from <plugin folder>/sloop/lib. If the test IDE skips the sandbox copy of the plugin
        // (for example because the IDE is older than since-build) it falls back to build/resources/main, which has no such folder,
        // and every test that needs the backend waits until it times out.
        val backendJars = getService(SonarLintPlugin::class.java).path.resolve("sloop/lib")

        assertThat(backendJars).isDirectory
        assertThat(Files.list(backendJars).use { files -> files.map { it.fileName.toString() }.toList() })
            .anyMatch { it.startsWith("sonarlint-backend-cli-") }
    }

    @Test
    fun extensionPointsAreFoundUnderThePluginId() {
        listOf(AnalysisConfigurator.EP_NAME, FileExclusionContributor.EP_NAME, FilesContributor.EP_NAME, VcsRepoProvider.EP_NAME).forEach {
            assertThat(it.name).startsWith("$CODESCAN_PLUGIN_ID.")
            assertThat(ApplicationManager.getApplication().extensionArea.hasExtensionPoint(it)).`as`("extension point ${it.name} is declared").isTrue()
        }
        assertThat(AnalysisConfigurator.EP_NAME.extensionList).hasAtLeastOneElementOfType(JavaAnalysisConfigurator::class.java)
    }

    @Test
    fun gitBranchProviderIsRegistered() {
        // the :git module is only on the runtime class path, so the class is checked by name
        assertThat(VcsRepoProvider.EP_NAME.extensionList.map { it.javaClass.name }).contains("org.sonarlint.intellij.git.GitRepoProvider")
    }

    @Test
    fun vendorAndDescriptionAreCodeScan() {
        val plugin = PluginManagerCore.getPlugin(PluginId.getId(CODESCAN_PLUGIN_ID))!!

        assertThat(plugin.vendor).isEqualTo("CodeScan")
        assertThat(plugin.vendorEmail).isEqualTo("support@codescan.io")
        assertThat(plugin.vendorUrl).isEqualTo("https://codescan.io")
        assertThat(plugin.url).isEqualTo("https://codescan.io")
        assertThat(plugin.description).contains("CodeScan").doesNotContainIgnoringCase("sonar")
    }

    @Test
    fun pluginInstallsOnlyInIntelliJIdea() {
        // CodeScan supports IntelliJ IDEA only, so the Java plugin is required and the Go and database extras are not declared
        val dependencies = PluginManagerCore.getPlugin(PluginId.getId(CODESCAN_PLUGIN_ID))!!.dependencies

        assertThat(dependencies.filterNot { it.isOptional }.map { it.pluginId.idString })
            .contains("com.intellij.modules.platform", "com.intellij.modules.lang", "com.intellij.modules.java")
        assertThat(dependencies.map { it.pluginId.idString }).doesNotContain("org.jetbrains.plugins.go", "com.intellij.database")
    }

    @Test
    fun aboutPageOffersNoStatisticsChoice() {
        // telemetry is off; ticking or clearing the box would still make the backend call SonarSource's telemetry address
        val aboutPanel = SonarLintAboutPanel()
        val telemetry = mock(SonarLintTelemetry::class.java)

        assertThat(UIUtil.findComponentsOfType(aboutPanel.component, JCheckBox::class.java)).isEmpty()
        aboutPanel.load(telemetry)
        aboutPanel.save(telemetry)
        assertThat(aboutPanel.isModified(telemetry)).isFalse()
        verifyNoInteractions(telemetry)
    }

    @Test
    fun toolWindowIsCalledCodeScan() {
        val ours = ToolWindowEP.EP_NAME.extensionList.filter { it.pluginDescriptor.pluginId == PluginId.getId(CODESCAN_PLUGIN_ID) }

        assertThat(ours.map { it.id }).containsExactly("CodeScan")
        assertThat(SonarLintToolWindowFactory.TOOL_WINDOW_ID).isEqualTo("CodeScan")
        assertThat(CurrentFilePanel.SONARLINT_TOOLWINDOW_ID).isEqualTo("CodeScan")
    }

    @Test
    fun settingsPagesAreCalledCodeScan() {
        val pluginId = PluginId.getId(CODESCAN_PLUGIN_ID)
        val application = Configurable.APPLICATION_CONFIGURABLE.extensionList.filter { it.pluginDescriptor.pluginId == pluginId }
        val project = Configurable.PROJECT_CONFIGURABLE.getExtensions(project).filter { it.pluginDescriptor.pluginId == pluginId }

        assertThat(application.map { it.displayName }).containsExactly("CodeScan")
        assertThat(project.map { it.displayName }).isNotEmpty.noneMatch { it.contains("sonar", ignoreCase = true) }
    }

    @Test
    fun settingsPageTitlesAreCodeScan() {
        assertThat(SonarLintGlobalConfigurable().displayName).isEqualTo("CodeScan")
        assertThat(SonarLintColorSettingsPage().displayName).isEqualTo("CodeScan")
    }

    @Test
    fun notificationGroupsAreCalledCodeScan() {
        val ours = NotificationGroupManager.getInstance().registeredNotificationGroups
            .filter { it.pluginId == PluginId.getId(CODESCAN_PLUGIN_ID) }
            .map { it.displayId }

        assertThat(ours).isNotEmpty.allMatch { it == "CodeScan" || it.startsWith("CodeScan: ") }
        assertThat(ours).contains(ReviewSecurityHotspotAction.REVIEW_HOTSPOT_GROUP, MarkAsResolvedAction.REVIEW_ISSUE_GROUP)
    }

    @Test
    fun actionsAreCalledCodeScan() {
        val ids = ActionManagerEx.getInstanceEx().getPluginActions(PluginId.getId(CODESCAN_PLUGIN_ID)).toList()

        assertThat(ids).isNotEmpty.allMatch { it.startsWith("CodeScan.") }
        ids.forEach { id ->
            val presentation = ActionManager.getInstance().getAction(id).templatePresentation
            assertThat("${presentation.text} / ${presentation.description}").`as`(id).doesNotContainIgnoringCase("sonar")
        }
    }

    @Test
    fun everyActionAndNotificationGroupLookedUpByNameExists() {
        val lookups = sourceFiles().flatMap { file ->
            val text = file.readText()
            ACTION_LOOKUP.findAll(text).map { "action" to it.groupValues[1] } +
                GROUP_LOOKUP.findAll(text).map { "group" to it.groupValues[1] }
        }.toSet()

        assertThat(lookups).isNotEmpty
        lookups.forEach { (kind, name) ->
            val exists = if (kind == "action") ActionManager.getInstance().getAction(name) != null else NotificationGroupManager.getInstance().isGroupRegistered(name)
            assertThat(exists).`as`("$kind '$name' looked up by the code is declared in plugin.xml").isTrue()
        }
    }

    private fun sourceFiles(): List<Path> = listOf("src/main/java", "common/src/main/java", "git/src/main/java")
        .map { Paths.get(it) }
        .filter { Files.isDirectory(it) }
        .flatMap { root -> Files.walk(root).use { paths -> paths.filter { it.extension == "java" || it.extension == "kt" }.toList() } }

    companion object {
        private const val CODESCAN_PLUGIN_ID = "com.code-scan.intellij"
        private val ACTION_LOOKUP = Regex("""getAction\("([^"]+)"\)""")
        private val GROUP_LOOKUP = Regex("""getNotificationGroup\("([^"]+)"\)""")
    }
}
