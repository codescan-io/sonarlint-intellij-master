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
import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.extensions.PluginId
import org.assertj.core.api.Assertions.assertThat
import org.junit.jupiter.api.Test
import org.sonarlint.intellij.AbstractSonarLintHeavyTests
import org.sonarlint.intellij.SonarLintPlugin
import org.sonarlint.intellij.common.analysis.AnalysisConfigurator
import org.sonarlint.intellij.common.analysis.FileExclusionContributor
import org.sonarlint.intellij.common.analysis.FilesContributor
import org.sonarlint.intellij.common.util.SonarLintUtils.getService
import org.sonarlint.intellij.common.vcs.VcsRepoProvider
import org.sonarlint.intellij.java.JavaAnalysisConfigurator

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

    companion object {
        private const val CODESCAN_PLUGIN_ID = "com.code-scan.intellij"
    }
}
