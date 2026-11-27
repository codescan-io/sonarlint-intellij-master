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
package org.sonarlint.intellij.its.tests

import com.intellij.remoterobot.utils.waitFor
import java.time.Duration
import org.assertj.core.api.Assertions.assertThat
import org.junit.jupiter.api.AfterAll
import org.junit.jupiter.api.BeforeAll
import org.junit.jupiter.api.Tag
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.condition.EnabledIf
import org.sonarlint.intellij.its.BaseUiTest
import org.sonarlint.intellij.its.tests.domain.CurrentFileTabTests.Companion.enableConnectedModeFromCurrentFilePanel
import org.sonarlint.intellij.its.tests.domain.CurrentFileTabTests.Companion.isProjectBoundInSettings
import org.sonarlint.intellij.its.tests.domain.SecurityHotspotTabTests.Companion.waitForSecurityHotspotTabMessage
import org.sonarlint.intellij.its.utils.CodeScanWireMock
import org.sonarlint.intellij.its.utils.OpeningUtils.Companion.openExistingProject
import org.sonarlint.intellij.its.utils.OpeningUtils.Companion.openFile
import org.sonarlint.intellij.its.utils.SettingsUtils.Companion.addCodeScanConnection
import org.sonarlint.intellij.its.utils.SettingsUtils.Companion.clearConnections

// Connected mode against the WireMock copy of CodeScan (utils/CodeScanWireMock.kt), in place of upstream's SonarQube
// Developer edition run by Orchestrator, which needs a SonarSource licence.
@Tag("ConnectedAnalysisTests")
@EnabledIf("isIdea")
class ConnectedAnalysisTests : BaseUiTest() {

    companion object {
        private const val CONNECTION = "CodeScan-WireMock"

        @JvmStatic
        @BeforeAll
        fun addCodeScanConnection() {
            CodeScanWireMock.start()
            clearConnections()
            addCodeScanConnection(CodeScanWireMock.TOKEN, CONNECTION, CodeScanWireMock.ORGANIZATION)
        }

        @JvmStatic
        @AfterAll
        fun removeCodeScanConnection() {
            try {
                clearConnections()
            } finally {
                CodeScanWireMock.stop()
            }
        }
    }

    @Test
    fun should_bind_to_codescan_then_sync_then_unbind() = uiTest {
        openExistingProject("codescan-sample")
        // Open a file first: with no file opened since the project opened, the tab keeps its first card, "CodeScan service
        // encountered an issue and has stopped working" (SecurityHotspotsPanel; seen on 2023.1.7).
        openFile("src/main/java/sample/Greeter.java", "Greeter.java")
        waitForSecurityHotspotTabMessage("is not bound")

        // CodeScan has no Taint Vulnerabilities tab (SonarLintUtils.isTaintVulnerabilitiesEnabled), so bind from the Current File tab.
        enableConnectedModeFromCurrentFilePanel(CodeScanWireMock.PROJECT_KEY, true, CONNECTION)
        waitFor(Duration.ofSeconds(60), Duration.ofSeconds(2), "the plugin never asked CodeScan for the bound project's quality profiles") {
            CodeScanWireMock.wasCalled("/api/qualityprofiles/search.protobuf", "project", CodeScanWireMock.PROJECT_KEY)
        }
        assertThat(isProjectBoundInSettings()).isTrue()
        // To the backend CodeScan is SonarCloud, where Security Hotspots are found locally once the project is bound.
        waitForSecurityHotspotTabMessage("No Security Hotspots found")

        enableConnectedModeFromCurrentFilePanel(CodeScanWireMock.PROJECT_KEY, false, CONNECTION)
        assertThat(isProjectBoundInSettings()).isFalse()
        waitForSecurityHotspotTabMessage("is not bound")
    }

}
