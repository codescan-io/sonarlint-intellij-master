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
import org.assertj.core.api.Assertions.assertThat
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
        waitFor(Duration.ofSeconds(60), Duration.ofSeconds(1), "the project never opened") {
            remoteRobot.idea().callJs<Boolean>("component.project != null", true)
        }
        // A small project can finish indexing before the file is open, so the IDE is held in indexing ("dumb") mode
        // until the file is saved.
        setIndexingHold(true)
        try {
            waitFor(Duration.ofSeconds(10), Duration.ofMillis(500), "the IDE did not enter indexing mode") { isIndexing() }
            openFile("src/main/java/sample/Greeter.java", "Greeter.java", waitForBackgroundTasks = false)

            typeLineBelowMarker("Greeter.java", "int typed = 0;")
            saveAll()
            assertThat(isIndexing()).describedAs("the IDE was still indexing when the file was opened, typed in and saved").isTrue()
        } finally {
            setIndexingHold(false)
        }

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

    private fun isIndexing(): Boolean = remoteRobot.idea().callJs(
        "component.project != null && com.intellij.openapi.project.DumbService.isDumb(component.project)", true
    )

    // Turns the IDE's internal "Toggle Dumb Mode" action (id DumbMode; needs idea.is.internal=true, set in
    // its/build.gradle.kts) on or off. While on, the IDE stays in indexing mode. The action's own menu entry is greyed
    // out during real indexing, so it is called directly. Its state is a project flag named after the action class.
    // The action changes the IDE's model, which needs the IDE's own invokeAndWait: from the robot's UI-thread runner,
    // 2026.1.5 logs "Write-unsafe context!".
    private fun setIndexingHold(hold: Boolean) {
        remoteRobot.idea().runJs(
            """
            const project = component.project;
            const action = com.intellij.openapi.actionSystem.ActionManager.getInstance().getAction("DumbMode");
            if (action == null) {
                throw "the IDE has no DumbMode action: is idea.is.internal=true set?";
            }
            com.intellij.openapi.application.ApplicationManager.getApplication().invokeAndWait(new java.lang.Runnable({
                run: function () {
                    const key = com.intellij.openapi.util.Key.findKeyByName("ToggleDumbModeAction");
                    const held = key != null && java.lang.Boolean.TRUE.equals(project.getUserData(key));
                    if (held != $hold) {
                        const context = com.intellij.openapi.actionSystem.impl.SimpleDataContext.getProjectContext(project);
                        action.actionPerformed(com.intellij.openapi.actionSystem.AnActionEvent.createFromDataContext("CodeScanUiTest", null, context));
                    }
                }
            }), com.intellij.openapi.application.ModalityState.defaultModalityState());
            """, false
        )
    }

    private fun saveAll() {
        val modifier = if (remoteRobot.isMac()) KeyEvent.VK_META else KeyEvent.VK_CONTROL
        remoteRobot.keyboard { hotKey(modifier, KeyEvent.VK_S) }
    }

}
