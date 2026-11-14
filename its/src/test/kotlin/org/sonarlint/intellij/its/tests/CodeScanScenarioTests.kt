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

import com.intellij.remoterobot.utils.keyboard
import com.intellij.remoterobot.utils.waitFor
import java.awt.event.KeyEvent
import java.time.Duration
import org.junit.jupiter.api.Tag
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.condition.EnabledIf
import org.sonarlint.intellij.its.BaseUiTest
import org.sonarlint.intellij.its.fixtures.editor
import org.sonarlint.intellij.its.fixtures.idea
import org.sonarlint.intellij.its.tests.domain.CurrentFileTabTests.Companion.waitForCurrentFileTabMessage
import org.sonarlint.intellij.its.utils.OpeningUtils.Companion.openExistingProject
import org.sonarlint.intellij.its.utils.OpeningUtils.Companion.openFile
import org.sonarlint.intellij.its.utils.SettingsUtils.Companion.sonarLintGlobalSettings

// What a user does in the first minute, without waiting for the IDE to settle. The IDE log check that runs after the
// UI tests (its checkIdeLog task) is what reports any thread-rule break this provokes.
@Tag("CodeScanScenarios")
@EnabledIf("isIdea")
class CodeScanScenarioTests : BaseUiTest() {

    @Test
    fun openProjectDuringIndexing() = uiTest {
        openExistingProject("codescan-sample", waitForIndexing = false)
        openFile("src/main/java/sample/Greeter.java", "Greeter.java", waitForBackgroundTasks = false)

        typeLineBelowMarker("Greeter.java", "int typed = 0;")
        saveAll()

        // Greeter.java has 2 issues (unused local, System.out); the typed line adds a second unused local.
        waitForCurrentFileTabMessage("Found 3 issues in 1 file", Duration.ofMinutes(5))

        sonarLintGlobalSettings {
            findText("Rules").click()
            searchRule("java:S106")
            waitFor(Duration.ofSeconds(60), Duration.ofSeconds(2), "the Rules tab never listed java:S106") {
                hasText("Standard outputs should not be used directly to log anything")
            }
            pressCancel()
        }
    }

    private fun typeLineBelowMarker(fileName: String, line: String) {
        with(remoteRobot) {
            idea {
                editor(fileName, Duration.ofSeconds(60)) {
                    click()
                    runJs(
                        """
                        const editor = component.getEditor();
                        const document = editor.getDocument();
                        const marker = document.getText().indexOf("the UI test types a line below this one");
                        if (marker < 0) {
                            throw "marker line not found in $fileName";
                        }
                        editor.getCaretModel().moveToOffset(document.getLineEndOffset(document.getLineNumber(marker)));
                        """, true
                    )
                    keyboard {
                        enter()
                        enterText(line)
                        escape()
                    }
                }
            }
        }
    }

    private fun saveAll() {
        val modifier = if (remoteRobot.isMac()) KeyEvent.VK_META else KeyEvent.VK_CONTROL
        remoteRobot.keyboard { hotKey(modifier, KeyEvent.VK_S) }
    }

}
