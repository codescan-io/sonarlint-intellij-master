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
package org.sonarlint.intellij.its.tests.domain

import com.intellij.remoterobot.utils.waitFor
import java.time.Duration
import org.assertj.core.api.Assertions.assertThat
import org.sonarlint.intellij.its.BaseUiTest.Companion.remoteRobot
import org.sonarlint.intellij.its.fixtures.dialog
import org.sonarlint.intellij.its.fixtures.idea
import org.sonarlint.intellij.its.fixtures.notification
import org.sonarlint.intellij.its.fixtures.tool.window.toolWindow
import org.sonarlint.intellij.its.utils.ProjectBindingUtils.Companion.disableConnectedMode
import org.sonarlint.intellij.its.utils.ProjectBindingUtils.Companion.enableConnectedMode

class SecurityHotspotTabTests {

    companion object {
        fun openSecurityHotspotReviewDialogFromList(securityHotspotMessage: String) {
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

        fun changeSecurityHotspotStatusAndPressChange(status: String) {
            with(remoteRobot) {
                idea {
                    dialog("Change Security Hotspot Status on CodeScan") {
                        content(status) {
                            click()
                        }
                        pressButton("Change Status")
                    }
                }
            }
        }

        fun verifySecurityHotspotStatusWasSuccessfullyChanged() {
            with(remoteRobot) {
                idea {
                    notification("The Security Hotspot status was successfully updated")
                    toolWindow("CodeScan") {
                        content("SecurityHotspotsPanel") {
                            hasText("No Security Hotspots shown due to the current filtering")
                        }
                    }
                }
            }
        }

        // Once the plugin has asked its backend, the tab shows why Security Hotspots are not supported, or the result.
        fun waitForSecurityHotspotTabMessage(fragment: String, timeout: Duration = Duration.ofMinutes(1)) {
            with(remoteRobot) {
                idea {
                    toolWindow("CodeScan") {
                        ensureOpen()
                        tabTitleContains("Security Hotspots") { select() }
                        content("SecurityHotspotsPanel") {
                            var shown = ""
                            waitFor(
                                timeout, Duration.ofSeconds(2), "Security Hotspots tab shows '$fragment'",
                                { "the Security Hotspots tab never showed '$fragment'; it showed '$shown'" }
                            ) {
                                shown = callJs(SHOWN_MESSAGES_JS, true)
                                shown.contains(fragment)
                            }
                        }
                    }
                }
            }
        }

        // Tab messages are the empty texts of child-less panels (SecurityHotspotsPanel.centeredLabel); read them directly.
        // Such a panel paints its empty text only while none of its children is visible.
        private val SHOWN_MESSAGES_JS = """
            const shown = [];
            function isPanelWithEmptyText(c) {
                for (var k = c.getClass(); k != null; k = k.getSuperclass()) {
                    if (k.getName() == "com.intellij.ui.components.JBPanelWithEmptyText") return true;
                }
                return false;
            }
            function hasVisibleChild(c) {
                const children = c.getComponents();
                for (var i = 0; i < children.length; i++) if (children[i].isVisible()) return true;
                return false;
            }
            function collect(c) {
                if (!c.isShowing()) return;
                if (isPanelWithEmptyText(c) && !hasVisibleChild(c)) shown.push(String(c.getEmptyText().getText()));
                const children = c.getComponents();
                for (var i = 0; i < children.length; i++) collect(children[i]);
            }
            collect(component);
            shown.join("\n")
        """.trimIndent()

        fun verifySecurityHotspotTabContainsMessages(vararg expectedMessages: String) {
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

        fun verifySecurityHotspotTreeContainsMessages(vararg expectedMessages: String) {
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

        fun enableConnectedModeFromSecurityHotspotPanel(projectKey: String, enabled: Boolean, connectionName: String) {
            with(remoteRobot) {
                idea {
                    toolWindow("CodeScan") {
                        ensureOpen()
                        tabTitleContains("Security Hotspots") { select() }
                        content("SecurityHotspotsPanel") {
                            toolBarButton("Configure CodeScan").click()
                        }
                    }
                    if (enabled) {
                        enableConnectedMode(projectKey, connectionName)
                    } else {
                        disableConnectedMode()
                    }
                }
            }
        }

        fun verifySecurityHotspotRuleDescriptionTabContains(expectedMessage: String) {
            with(remoteRobot) {
                idea {
                    toolWindow("CodeScan") {
                        ensureOpen()
                        content("SecurityHotspotsPanel") {
                            waitFor(Duration.ofMinutes(1), errorMessage = "Unable to find '$expectedMessage' in: ${findAllText()}") {
                                hasText(expectedMessage)
                            }
                        }
                    }
                }
            }
        }
    }

}
