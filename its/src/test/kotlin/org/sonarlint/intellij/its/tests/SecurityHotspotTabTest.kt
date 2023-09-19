/*
 * CodeScan for IntelliJ IDEA
 * Copyright (C) 2015-2023 SonarSource
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
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02
 */
package org.sonarlint.intellij.its.tests

import com.intellij.remoterobot.RemoteRobot
import com.sonar.orchestrator.Orchestrator
import com.sonar.orchestrator.container.Edition
import com.sonar.orchestrator.locator.FileLocation
import org.assertj.core.api.Assertions.assertThat
import org.junit.jupiter.api.AfterAll
import org.junit.jupiter.api.BeforeAll
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.condition.DisabledIf
import org.sonarlint.intellij.its.BaseUiTest
import org.sonarlint.intellij.its.fixtures.dialog
import org.sonarlint.intellij.its.fixtures.firstNotification
import org.sonarlint.intellij.its.fixtures.idea
import org.sonarlint.intellij.its.fixtures.tool.window.toolWindow
import org.sonarlint.intellij.its.utils.OrchestratorUtils.Companion.defaultBuilderEnv
import org.sonarlint.intellij.its.utils.OrchestratorUtils.Companion.executeBuildWithMaven
import org.sonarlint.intellij.its.utils.OrchestratorUtils.Companion.generateToken
import org.sonarlint.intellij.its.utils.OrchestratorUtils.Companion.newAdminWsClientWithUser
import org.sonarlint.intellij.its.utils.ProjectBindingUtils.Companion.bindProjectToSonarQube


const val SECURITY_HOTSPOT_PROJECT_KEY = "sample-java-hotspot"

@DisabledIf("isCLionOrGoLand", disabledReason = "No Java Security Hotspots in CLion or GoLand")
class SecurityHotspotTabTest : BaseUiTest() {

    @Test
    fun should_request_the_user_to_bind_project_when_not_bound() = uiTest {
        openExistingProject("sample-java-hotspot", true)
        verifySecurityHotspotTabContainsMessages(this, "The project is not bound, please bind it to SonarQube 9.7+ or SonarCloud")
    }

    @Test
    fun should_display_security_hotspots_and_review_it_successfully() = uiTest {
        openExistingProject("sample-java-hotspot", true)
        bindProjectFromPanel()

        openFile("src/main/java/foo/Foo.java", "Foo.java")
        verifySecurityHotspotTreeContainsMessages(this, "Make sure using this hardcoded IP address is safe here.")

        openReviewDialogFromList(this, "Make sure using this hardcoded IP address is safe here.")
        changeStatusAndPressChange(this, "Acknowledged")
        verifyStatusWasSuccessfullyChanged(this)
    }

    private fun bindProjectFromPanel() {
        with(remoteRobot) {
            idea {
                toolWindow("CodeScan") {
                    ensureOpen()
                    tab("Security Hotspots") { select() }
                    content("SecurityHotspotsPanel") {
                        findText("Configure Binding").click()
                    }
                }
                bindProjectToSonarQube(
                    ORCHESTRATOR.server.url,
                    token,
                    SECURITY_HOTSPOT_PROJECT_KEY
                )
            }
        }
    }

    private fun openReviewDialogFromList(remoteRobot: RemoteRobot, securityHotspotMessage: String) {
        with(remoteRobot) {
            idea {
                toolWindow("CodeScan") {
                    ensureOpen()
                    tabTitleContains("Security Hotspots") { select() }
                    content("SecurityHotspotTree") {
                        findText(securityHotspotMessage).rightClick()
                    }
                }
                actionMenuItem("Review Security Hotspot") {
                    click()
                }
            }
        }
    }

    private fun changeStatusAndPressChange(remoteRobot: RemoteRobot, status: String) {
        with(remoteRobot) {
            idea {
                dialog("Change Security Hotspot Status on SonarQube") {
                    content(status) {
                        click()
                    }
                    pressButton("Change Status")
                }
            }
        }
    }

    private fun verifyStatusWasSuccessfullyChanged(remoteRobot: RemoteRobot) {
        with(remoteRobot) {
            idea {
                firstNotification {
                    hasText("The Security Hotspot status was successfully updated")
                }
                toolWindow("CodeScan") {
                    content("SecurityHotspotsPanel") {
                        hasText("No Security Hotspot found.")
                    }
                }
            }
        }
    }

    private fun verifySecurityHotspotTabContainsMessages(remoteRobot: RemoteRobot, vararg expectedMessages: String) {
        with(remoteRobot) {
            idea {
                toolWindow("CodeScan") {
                    ensureOpen()
                    tabTitleContains("Security Hotspots") { select() }
                    content("SecurityHotspotsPanel") {
                        expectedMessages.forEach { assertThat(hasText(it)).isTrue() }
                    }
                }
            }
        }
    }

    private fun verifySecurityHotspotTreeContainsMessages(remoteRobot: RemoteRobot, vararg expectedMessages: String) {
        with(remoteRobot) {
            idea {
                toolWindow("CodeScan") {
                    ensureOpen()
                    tabTitleContains("Security Hotspots") { select() }
                    content("SecurityHotspotTree") {
                        expectedMessages.forEach { assertThat(hasText(it)).isTrue() }
                    }
                }
            }
        }
    }

    companion object {

        lateinit var token: String

        private val ORCHESTRATOR: Orchestrator = defaultBuilderEnv()
            .setEdition(Edition.DEVELOPER)
            .activateLicense()
            .keepBundledPlugins()
            .restoreProfileAtStartup(FileLocation.ofClasspath("/java-sonarlint-with-hotspot.xml"))
            .build()

        @BeforeAll
        @JvmStatic
        fun prepare() {
            ORCHESTRATOR.start()

            val adminWsClient = newAdminWsClientWithUser(ORCHESTRATOR.server)

            ORCHESTRATOR.server.provisionProject(SECURITY_HOTSPOT_PROJECT_KEY, "Sample Java Hotspot")
            ORCHESTRATOR.server.associateProjectToQualityProfile(
                SECURITY_HOTSPOT_PROJECT_KEY,
                "java",
                "SonarLint IT Java Hotspot"
            )

            // Build and analyze project to raise hotspot
            executeBuildWithMaven("projects/sample-java-hotspot/pom.xml", ORCHESTRATOR);

            token = generateToken(adminWsClient)
        }

        @AfterAll
        @JvmStatic
        fun teardown() {
            ORCHESTRATOR.stop()
        }
    }
}
