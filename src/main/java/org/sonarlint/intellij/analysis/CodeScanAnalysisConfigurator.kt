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
package org.sonarlint.intellij.analysis

import com.intellij.openapi.module.Module
import com.intellij.openapi.vfs.VirtualFile
import org.sonarlint.intellij.common.analysis.AnalysisConfigurator
import org.sonarlint.intellij.common.analysis.AnalysisConfigurator.AnalysisConfiguration
import org.sonarlint.intellij.config.Settings.getGlobalSettings
import org.sonarlint.intellij.config.Settings.getSettingsFor

/**
 * CodeScan: the analysis settings CodeScan's analyzers need to fetch rules and metadata from the server, plus the IDE type.
 * Registered in plugin.xml, so it runs in every IDE, not only in IDEs with the Java plugin.
 */
class CodeScanAnalysisConfigurator : AnalysisConfigurator {

    override fun configure(module: Module, filesToAnalyze: Collection<VirtualFile>): AnalysisConfiguration {
        val config = AnalysisConfiguration()
        val properties = config.extraProperties
        val projectSettings = getSettingsFor(module.project)
        val connectionName = projectSettings.connectionName
        if (projectSettings.isBindingEnabled && connectionName != null) {
            getGlobalSettings().getServerConnectionByName(connectionName).ifPresent { connection ->
                properties[SONAR_HOST_URL] = connection.hostUrl
                properties[SONAR_ORGANIZATION] = connection.organizationKey ?: ""
                connection.token?.let {
                    properties[SONAR_LOGIN] = it
                    properties[SONAR_PASSWORD] = ""
                }
            }
        }
        properties[CODESCAN_IDE_TYPE] = "IntelliJ IDEA"
        return config
    }

    companion object {
        private const val SONAR_HOST_URL = "sonar.host.url"
        private const val SONAR_ORGANIZATION = "sonar.organization"
        private const val SONAR_LOGIN = "sonar.login"
        private const val SONAR_PASSWORD = "sonar.password"
        private const val CODESCAN_IDE_TYPE = "codescan.ide.type"
        private const val MASK = "******"
        private val SECRET_KEYS = setOf(SONAR_LOGIN, SONAR_PASSWORD, "sonar.token")

        /**
         * The backend prints the analysis settings at the start of every analysis, token included.
         * This hides the token of every connection, so no log line shows one.
         */
        @JvmStatic
        fun maskSecrets(text: String): String =
            getGlobalSettings().serverConnections
                .mapNotNull { it.token }
                .filter { it.isNotBlank() }
                .fold(text) { masked, token -> masked.replace(token, MASK) }

        /** Whether the value of this analysis setting is a secret that must never be printed. */
        @JvmStatic
        fun isSecret(key: String) = key in SECRET_KEYS
    }
}
