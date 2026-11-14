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

import com.intellij.remoterobot.fixtures.CommonContainerFixture
import com.intellij.remoterobot.fixtures.JListFixture
import com.intellij.remoterobot.utils.WaitForConditionTimeoutException
import com.intellij.remoterobot.utils.keyboard
import java.time.Duration
import org.assertj.core.api.Assertions.assertThat
import org.junit.jupiter.api.AfterAll
import org.junit.jupiter.api.Tag
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.condition.EnabledIf
import org.junit.jupiter.api.fail
import org.sonarlint.intellij.its.BaseUiTest
import org.sonarlint.intellij.its.fixtures.DialogFixture
import org.sonarlint.intellij.its.fixtures.clickWhenEnabled
import org.sonarlint.intellij.its.fixtures.dialog
import org.sonarlint.intellij.its.fixtures.idea
import org.sonarlint.intellij.its.fixtures.jPasswordField
import org.sonarlint.intellij.its.fixtures.jRadioButtons
import org.sonarlint.intellij.its.fixtures.jbTextFields
import org.sonarlint.intellij.its.fixtures.tool.window.toolWindow
import org.sonarlint.intellij.its.tests.domain.CurrentFileTabTests.Companion.enableConnectedModeFromCurrentFilePanel
import org.sonarlint.intellij.its.tests.domain.CurrentFileTabTests.Companion.isProjectBoundInSettings
import org.sonarlint.intellij.its.utils.CodeScanStaging
import org.sonarlint.intellij.its.utils.OpeningUtils.Companion.openExistingProject
import org.sonarlint.intellij.its.utils.OpeningUtils.Companion.openFile
import org.sonarlint.intellij.its.utils.SettingsUtils.Companion.clearConnections
import org.sonarlint.intellij.its.utils.SettingsUtils.Companion.sonarLintGlobalSettings
import org.sonarlint.intellij.its.utils.optionalStep

// The real plugin against a live CodeScan server (by default staging): connect with a token, bind the sample project,
// open an Apex file and see CodeScan's issues in the CodeScan tool window. Settings come from the environment (see
// utils/CodeScanStaging.kt); without CODESCAN_TOKEN the test is skipped. Run it with
// scripts/qa/run-ide-scenarios.sh <ide-version> --staging.
// It only reads from the server: no issue or Security Hotspot is changed. Errors and slow operations from CodeScan code
// fail it through BaseUiTest.uiTest (IdeErrors) and the IDE log check after the run (scan-ide-logs.sh).
@Tag("CodeScanStaging")
@EnabledIf(
    value = "org.sonarlint.intellij.its.utils.CodeScanStaging#shouldRun",
    disabledReason = "skipped: CODESCAN_TOKEN is not set (also give CODESCAN_URL, CODESCAN_ORG, CODESCAN_PROJECT), or the IDE is not IntelliJ IDEA"
)
class CodeScanStagingTests : BaseUiTest() {

    companion object {
        private const val CONNECTION = "CodeScan-Staging"
        private const val APEX_FILE = "force-app/main/default/classes/GreeterService.cls"
        private val ISSUE_SUMMARY = Regex("Found (\\d+) (?:new |older )?issues? in \\d+ files?")

        // The first binding downloads the server's analyzers before any analysis. On staging (November 2026) the CodeScan
        // analyzer alone is 275 MB served at about 250 KB/s: 18 minutes with curl.
        private val ISSUES_TIMEOUT: Duration = Duration.ofMinutes(30)
        // A user who sees no issue reopens the file; the test does the same this often, and says so in its output.
        private val REOPEN_AFTER: Duration = Duration.ofSeconds(90)

        private var connectionCreated = false

        @JvmStatic
        @AfterAll
        fun removeStagingConnection() {
            // Only the IDE's own settings: the connection is removed here, nothing on the server. The test clears
            // connections when it starts too, so a failure here is reported but does not fail the run.
            if (connectionCreated) {
                connectionCreated = false
                try {
                    clearConnections()
                } catch (e: Exception) {
                    println("WARNING: could not remove connection '$CONNECTION' from the IDE settings after the test: $e")
                }
            }
        }
    }

    @Test
    fun connectBindAndShowApexIssuesFromLiveServer() = uiTest {
        markInIdeLog("start")
        try {
            val organization = CodeScanStaging.organization
            val projectKey = CodeScanStaging.projectKey
            println("Live CodeScan server: ${CodeScanStaging.url}, organization $organization, project $projectKey")
            assertThat(remoteRobot.callJs<Boolean>("java.lang.System.getenv(\"${CodeScanStaging.TOKEN_VARIABLE}\") != null"))
                .describedAs("the UI-test IDE has ${CodeScanStaging.TOKEN_VARIABLE} in its environment (start it from a shell that has it)")
                .isTrue()

            clearConnections()
            addConnection(CodeScanStaging.url, organization)
            println("Step 1 done: connection '$CONNECTION' created")

            openExistingProject("codescan-sample")
            // With no file opened since the project opened, the CodeScan tool window keeps its first card.
            openFile("src/main/java/sample/Greeter.java", "Greeter.java")
            enableConnectedModeFromCurrentFilePanel(projectKey, true, CONNECTION)
            assertThat(isProjectBoundInSettings()).describedAs("the project is bound").isTrue()
            println("Step 2 done: project bound to $projectKey")

            openFile(APEX_FILE, "GreeterService.cls", waitForBackgroundTasks = false)
            val issues = waitForIssues()
            println("Step 3 done: the CodeScan tool window shows $issues issue(s) in GreeterService.cls")
            assertThat(issues).describedAs("CodeScan issues shown for GreeterService.cls").isGreaterThan(0)
        } finally {
            markInIdeLog("end")
        }
    }

    // The connection wizard with "another address": staging is not the default app.codescan.io. The token is set by the
    // IDE from its own environment, so it never passes through a script or a logged step.
    private fun addConnection(url: String, organization: String) {
        sonarLintGlobalSettings {
            addConnectionButton().clickWhenEnabled()
            dialog("New Connection: Server Details") {
                keyboard { enterText(CONNECTION) }
                jRadioButtons()[1].select()
                jbTextFields()[1].text = url
                button("Next").click()
            }
            dialog("New Connection: Authentication", Duration.ofSeconds(60)) {
                jPasswordField().runJs("component.setText(java.lang.System.getenv(\"${CodeScanStaging.TOKEN_VARIABLE}\"))", true)
                button("Next").click()
            }
            // The token is checked and the organizations are fetched from the server before this step shows.
            val organizationStep = try {
                dialog("New Connection: Organization", Duration.ofSeconds(90))
            } catch (e: WaitForConditionTimeoutException) {
                val openDialogs = openDialogTexts()
                closeFailedWizard()
                pressCancel()
                fail("the connection to $url failed at the authentication step (no Organization step within 90 s). Open dialogs: $openDialogs")
            }
            organizationStep.apply {
                selectOrganization(organization)
                button("Next").click()
            }
            optionalStep {
                dialog("New Connection: Configure Notifications", Duration.ofSeconds(10)) {
                    button("Next").click()
                }
            }
            dialog("New Connection: Configuration completed", Duration.ofSeconds(30)) {
                pressCreate()
            }
            pressOk()
        }
        connectionCreated = true
    }

    // A failed connection leaves the wizard open under its error message, and BaseUiTest closes only the top dialog.
    private fun closeFailedWizard() {
        remoteRobot.findAll<DialogFixture>(DialogFixture.byTitle("Error")).forEach { it.pressOk() }
        remoteRobot.findAll<DialogFixture>(DialogFixture.byTitle("New Connection: Authentication")).forEach { it.pressCancel() }
    }

    // By key, as the list shows "<name> (<key>)" and may hold many organizations.
    private fun CommonContainerFixture.selectOrganization(organization: String) {
        jList(JListFixture.byType()) {
            val found: Boolean = callJs(
                """
                const model = component.getModel();
                var index = -1;
                for (var i = 0; i < model.getSize(); i++) {
                    if (String(model.getElementAt(i).getKey()) === "$organization") { index = i; }
                }
                if (index >= 0) { component.setSelectedIndex(index); component.ensureIndexIsVisible(index); }
                index >= 0
                """, true
            )
            if (!found) {
                fail("organization $organization is not among the ${collectItems().size} the token can see: ${collectItems()}")
            }
        }
    }

    private fun waitForIssues(): Int {
        val deadline = System.nanoTime() + ISSUES_TIMEOUT.toNanos()
        var nextReopen = System.nanoTime() + REOPEN_AFTER.toNanos()
        var lastTexts = emptyList<String>()
        while (System.nanoTime() < deadline) {
            lastTexts = currentFileTabTexts()
            val count = lastTexts.sumOf { text -> ISSUE_SUMMARY.find(text)?.groupValues?.get(1)?.toInt() ?: 0 }
            if (count > 0) {
                println("Current File tab: ${lastTexts.filter { ISSUE_SUMMARY.containsMatchIn(it) }}")
                return count
            }
            if (System.nanoTime() >= nextReopen) {
                println("No CodeScan issue shown yet (${lastTexts.take(5)}); reopening GreeterService.cls")
                reopenApexFile()
                nextReopen = System.nanoTime() + REOPEN_AFTER.toNanos()
            }
            Thread.sleep(5000)
        }
        fail("no CodeScan issue shown for GreeterService.cls within ${ISSUES_TIMEOUT.toMinutes()} min; the Current File tab shows: $lastTexts")
    }

    private fun currentFileTabTexts(): List<String> {
        var texts = emptyList<String>()
        with(remoteRobot) {
            idea {
                toolWindow("CodeScan") {
                    ensureOpen()
                    tabTitleContains("Current File") { select() }
                    content("CurrentFilePanel") {
                        texts = findAllText().map { it.text }
                    }
                }
            }
        }
        return texts
    }

    private fun reopenApexFile() {
        remoteRobot.idea().runJs(
            """
            const project = component.project;
            const file = project.getBaseDir().findFileByRelativePath("$APEX_FILE");
            com.intellij.openapi.application.ApplicationManager.getApplication().invokeAndWait(new java.lang.Runnable({
                run: function () { com.intellij.openapi.fileEditor.FileEditorManager.getInstance(project).closeFile(file); }
            }), com.intellij.openapi.application.ModalityState.defaultModalityState());
            """, false
        )
        openFile(APEX_FILE, "GreeterService.cls", waitForBackgroundTasks = false)
    }

    // The title and texts of each open dialog except the settings one, for a failure message. A password field shows
    // only its mask characters there.
    private fun openDialogTexts(): String = remoteRobot.findAll<DialogFixture>(DialogFixture.all())
        .filter { it.title != "Settings" && it.title != "Preferences" }
        .joinToString(" | ") { dialog -> dialog.title + ": " + dialog.findAllText().joinToString(" ") { it.text } }

    // Marks the test in idea.log, so that a hit in the log check can be matched to it.
    private fun markInIdeLog(event: String) {
        remoteRobot.runJs(
            "com.intellij.openapi.diagnostic.Logger.getInstance(\"CodeScanUiTest\").info(\"CodeScan UI test $event: connectBindAndShowApexIssuesFromLiveServer\")"
        )
    }

}
