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
import java.io.File
import java.time.Duration
import org.assertj.core.api.Assertions.assertThat
import org.junit.jupiter.api.Assumptions.assumeTrue
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
// UI tests (its checkIdeLog task) is what reports any thread-rule break this provokes. Each test writes its start and
// end into idea.log ("CodeScan UI test start/end: <name>"), so a hit in the log can be matched to its scenario.
@Tag("CodeScanScenarios")
@EnabledIf("isIdea")
class CodeScanScenarioTests : BaseUiTest() {

    // The log check only sees slow operations that the IDE checks for. Each kind of code has its own switch, a registry
    // key "ide.slow.operations.assertion[.<kind>]"; its/build.gradle.kts turns on the ones that are off by default
    // (action handlers and write actions among them). A switch that is off hides a whole kind, so none may be off.
    @Test
    fun slowOperationChecksAreOn() {
        val switches: List<String> = remoteRobot.callJs(
            """
            const result = new java.util.ArrayList();
            com.intellij.openapi.util.registry.Registry.getAll().forEach((value) => {
                if (value.getKey().startsWith("ide.slow.operations.assertion")) {
                    result.add(value.getKey() + "=" + value.asBoolean());
                }
            });
            result
            """
        )
        println("Slow-operation switches: $switches")
        assertThat(switches).describedAs("the IDE's slow-operation switches")
            .contains("ide.slow.operations.assertion.action.perform=true", "ide.slow.operations.assertion.write.action=true")
        assertThat(switches.filter { it.endsWith("=false") }).describedAs("slow-operation switches that are off").isEmpty()
    }

    @Test
    fun openProjectDuringIndexing() = uiTest {
        markInIdeLog("start", "openProjectDuringIndexing")
        openExistingProject("codescan-sample", waitForIndexing = false)
        waitForProject()
        // A small project can finish indexing before the file is open, so the IDE is held in indexing ("dumb") mode
        // until the file is saved. (openLargeProjectDuringRealIndexing does the same during real indexing.)
        setIndexingHold(true)
        try {
            waitFor(Duration.ofSeconds(10), Duration.ofMillis(500), "the IDE did not enter indexing mode") { isIndexing() }
            openFile("src/main/java/sample/Greeter.java", "Greeter.java", waitForBackgroundTasks = false)

            typeLineBelowMarker("Greeter.java", "int typed = 0;")
            saveAll()
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
        markInIdeLog("end", "openProjectDuringIndexing")
    }

    // The same steps while the IDE really indexes a larger project: a copy of the folder given with -PindexingProject
    // (for example apex-recipes; never written to) beside the sample project, plus generated Java files
    // (-PindexingFiles, default 6000) so that indexing outlasts the steps. Skipped without -PindexingProject.
    @Test
    fun openLargeProjectDuringRealIndexing() = uiTest {
        val source = System.getProperty("its.indexing.project")
        assumeTrue(!source.isNullOrBlank()) {
            "skipped: no larger project to index; give one with -PindexingProject=<folder> (run-ide-scenarios.sh --indexing-project <folder>)"
        }
        assumeTrue(File(source).isDirectory) { "skipped: the -PindexingProject folder does not exist: $source" }
        val fileCount = System.getProperty("its.indexing.files")?.toIntOrNull() ?: 6000
        val project = createIndexingProject(File(source), fileCount)
        println("Real-indexing project: ${project.absolutePath} (${project.walkTopDown().count { it.isFile }} files)")

        markInIdeLog("start", "openLargeProjectDuringRealIndexing")
        openExistingProject("codescan-indexing", copyProjectFiles = false, waitForIndexing = false)
        waitForProject()
        waitFor(Duration.ofSeconds(60), Duration.ofMillis(500), "the IDE never started indexing the project") { isIndexingRunning() }
        openFile("src/main/java/sample/Greeter.java", "Greeter.java", waitForBackgroundTasks = false)
        typeLineBelowMarker("Greeter.java", "int typed = 0;")
        saveAll()
        assertThat(isIndexingRunning())
            .describedAs("indexing was still running after Greeter.java was opened, typed in and saved; if it was over, raise -PindexingFiles (now $fileCount)")
            .isTrue()

        sonarLintGlobalSettings {
            findText("Rules").click()
            searchRule("java:S106")
            waitFor(Duration.ofSeconds(90), Duration.ofSeconds(2), "the Rules tab never listed java:S106") {
                hasText("Standard outputs should not be used directly to log anything")
            }
            pressCancel()
        }
        println("Indexing still running after the settings were closed: ${isIndexingRunning()}")

        waitForCurrentFileTabMessage("Found 3 issues in 1 file", Duration.ofMinutes(10))
        markInIdeLog("end", "openLargeProjectDuringRealIndexing")
    }

    // projects/codescan-indexing-tmp: the sample project, a copy of [source] under apex-recipes/ (without version
    // control, IDE and package-manager folders), and [fileCount] generated Java classes under src/main/java/generated.
    private fun createIndexingProject(source: File, fileCount: Int): File {
        val project = File("projects/codescan-indexing-tmp")
        project.deleteRecursively()
        File("projects/codescan-sample").copyRecursively(project)
        val skipped = setOf(".git", ".idea", "node_modules", ".sfdx", ".sf")
        val copy = project.resolve("apex-recipes")
        source.walkTopDown().onEnter { it == source || it.name !in skipped }.filter { it.isFile }.forEach {
            it.copyTo(copy.resolve(it.relativeTo(source).path))
        }
        val generated = project.resolve("src/main/java/generated")
        for (i in 0 until fileCount) {
            val pkg = "p${i / 100}"
            generated.resolve(pkg).apply { mkdirs() }.resolve("Gen$i.java").writeText(generatedClass(pkg, i))
        }
        return project
    }

    private fun generatedClass(pkg: String, i: Int): String {
        val methods = (0 until 12).joinToString("\n") { m ->
            """
            |    public int compute$m(int input) {
            |        int total = input + VALUE + $m;
            |        for (int k = 0; k < $m; k++) {
            |            total += helper$m(k);
            |        }
            |        return total;
            |    }
            |
            |    private static int helper$m(int k) {
            |        return k * ${i % 97 + 1};
            |    }
            |""".trimMargin()
        }
        return "package generated.$pkg;\n\n/** Generated for the real-indexing UI test. */\npublic class Gen$i {\n" +
            "    public static final int VALUE = $i;\n\n$methods}\n"
    }

    private fun waitForProject() {
        waitFor(Duration.ofSeconds(60), Duration.ofSeconds(1), "the project never opened") {
            remoteRobot.idea().callJs<Boolean>("component.project != null", true)
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

    // Indexing runs: the IDE is in indexing ("dumb") mode, or a background task's text says it indexes or scans files
    // (newer IDEs scan files without dumb mode). The running task texts are printed to the test log.
    private fun isIndexingRunning(): Boolean {
        val state: String = remoteRobot.idea().callJs(
            """
            const project = component.project;
            let texts = "";
            com.intellij.openapi.progress.impl.CoreProgressManager.getCurrentIndicators().forEach((indicator) => {
                texts += " [" + indicator.getText() + "]";
            });
            (project != null && com.intellij.openapi.project.DumbService.isDumb(project) ? "dumb" : "smart") + texts
            """, true
        )
        println("Indexing state: $state")
        val tasks = state.substringAfter(" ", "").lowercase()
        return state.startsWith("dumb") || "index" in tasks || "scann" in tasks
    }

    // Writes a line into idea.log, so that a hit there can be matched to the scenario that was running.
    private fun markInIdeLog(event: String, test: String) {
        remoteRobot.runJs(
            "com.intellij.openapi.diagnostic.Logger.getInstance(\"CodeScanUiTest\").info(\"CodeScan UI test $event: $test\")"
        )
    }

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
