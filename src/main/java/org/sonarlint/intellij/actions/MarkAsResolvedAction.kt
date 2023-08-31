/*
 * Codescan for IntelliJ IDEA
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
package org.sonarlint.intellij.actions

import com.intellij.codeInsight.intention.IntentionAction
import com.intellij.codeInsight.intention.PriorityAction
import com.intellij.icons.AllIcons
import com.intellij.ide.util.PropertiesComponent
import com.intellij.notification.NotificationGroup
import com.intellij.notification.NotificationGroupManager
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.editor.Editor
import com.intellij.openapi.module.Module
import com.intellij.openapi.module.ModuleUtil
import com.intellij.openapi.progress.ProgressManager
import com.intellij.openapi.project.Project
import com.intellij.openapi.ui.DoNotAskOption
import com.intellij.openapi.ui.MessageDialogBuilder
import com.intellij.openapi.util.Iconable
import com.intellij.psi.PsiFile
import org.sonarlint.intellij.analysis.AnalysisStatus
import org.sonarlint.intellij.common.ui.SonarLintConsole
import org.sonarlint.intellij.common.util.SonarLintUtils.getService
import org.sonarlint.intellij.config.global.ServerConnection
import org.sonarlint.intellij.core.BackendService
import org.sonarlint.intellij.core.ProjectBindingManager
import org.sonarlint.intellij.editor.CodeAnalyzerRestarter
import org.sonarlint.intellij.finding.Issue
import org.sonarlint.intellij.finding.issue.vulnerabilities.LocalTaintVulnerability
import org.sonarlint.intellij.tasks.FutureAwaitingTask
import org.sonarlint.intellij.ui.UiUtils.Companion.runOnUiThread
import org.sonarlint.intellij.ui.resolve.MarkAsResolvedDialog
import org.sonarlint.intellij.util.DataKeys.Companion.TAINT_VULNERABILITY_DATA_KEY
import org.sonarlint.intellij.util.displayErrorNotification
import org.sonarlint.intellij.util.displaySuccessfulNotification
import org.sonarlint.intellij.util.displayWarningNotification
import org.sonarsource.sonarlint.core.clientapi.backend.issue.CheckStatusChangePermittedResponse
import org.sonarsource.sonarlint.core.clientapi.backend.issue.IssueStatus

private const val SKIP_CONFIRM_DIALOG_PROPERTY = "SonarLint.markIssueAsResolved.hideConfirmation"

class MarkAsResolvedAction(
    private var issue: Issue? = null
)  :
    AbstractSonarAction(
        "Mark Issue as...", "Change the issue resolution status", null
    ), IntentionAction, PriorityAction, Iconable {
    companion object {
        private const val errorTitle = "<b>SonarLint - Unable to mark the issue as resolved</b>"
        private const val content = "The issue was successfully marked as resolved"

        val GROUP: NotificationGroup = NotificationGroupManager.getInstance().getNotificationGroup("SonarLint: Mark Issue as Resolved")

        fun openMarkAsResolvedDialog(project: Project, issue: Issue) {
            val connection = serverConnection(project) ?: return displayErrorNotification(
                project,
                errorTitle, "No connection could be found", GROUP
            )

            val file = issue.file() ?: return displayErrorNotification(project, errorTitle, "The file could not be found", GROUP)

            val module = ModuleUtil.findModuleForFile(file, project) ?: return displayErrorNotification(
                project, errorTitle, "No module could be found for this file", GROUP
            )
            val serverKey =
                issue.getServerKey() ?: return displayErrorNotification(project, errorTitle, "The issue key could not be found", GROUP)
            val response = checkPermission(project, connection, serverKey) ?: return

            val resolution = MarkAsResolvedDialog(
                project,
                connection,
                response,
            ).chooseResolution() ?: return
            if (confirm(project, connection.productName, resolution.newStatus)) {
                markAsResolved(project, module, issue, resolution, serverKey)
            }
        }

        private fun markAsResolved(
            project: Project,
            module: Module,
            issue: Issue,
            resolution: MarkAsResolvedDialog.Resolution,
            issueKey: String,
        ) {
            getService(BackendService::class.java)
                .markAsResolved(module, issueKey, resolution.newStatus, issue is LocalTaintVulnerability)
                .thenAccept {
                    updateUI(project, issue)
                    val comment = resolution.comment ?: return@thenAccept displaySuccessfulNotification(project, content, GROUP)
                    addComment(project, module, issueKey, comment)
                }
                .exceptionally { error ->
                    SonarLintConsole.get(project).error("Error while marking the issue as resolved", error)
                    displayErrorNotification(project, "Could not mark the issue as resolved", GROUP)
                    null
                }
        }

        private fun updateUI(project: Project, issue: Issue) {
            runOnUiThread(project) {
                issue.resolve()
                getService(project, SonarLintToolWindow::class.java).markAsResolved(issue)
                getService(project, CodeAnalyzerRestarter::class.java).refreshOpenFiles()
            }
        }

        private fun addComment(project: Project, module: Module, issueKey: String, comment: String) {
            getService(BackendService::class.java)
                .addCommentOnIssue(module, issueKey, comment)
                .thenAccept { displaySuccessfulNotification(project, content, GROUP) }
                .exceptionally { error ->
                    SonarLintConsole.get(project).error("Error while adding a comment on the issue", error)
                    displayWarningNotification(project, "The issue was marked as resolved but there was an error adding the comment", GROUP)
                    null
                }
        }

        private fun checkPermission(project: Project, connection: ServerConnection, issueKey: String): CheckStatusChangePermittedResponse? {
            val checkTask = CheckIssueStatusChangePermission(project, connection, issueKey)
            return try {
                ProgressManager.getInstance().run(checkTask)
            } catch (e: Exception) {
                SonarLintConsole.get(project).error("Error while retrieving the list of allowed statuses for issues", e)
                displayErrorNotification(project, "Could not check status change permission", GROUP)
                null
            }
        }

        private fun confirm(project: Project, productName: String, issueStatus: IssueStatus): Boolean {
            return shouldSkipConfirmationDialog() || MessageDialogBuilder.okCancel(
                "Confirm marking issue as resolved",
                "Are you sure you want to mark this issue as \"${issueStatus.title}\"? The status will be updated on $productName and synchronized with any contributor using SonarLint in connected mode"
            )
                .yesText("Confirm")
                .noText("Cancel")
                .doNotAsk(DoNotShowAgain())
                .ask(project)
        }

        private fun shouldSkipConfirmationDialog() = PropertiesComponent.getInstance().getBoolean(SKIP_CONFIRM_DIALOG_PROPERTY, false)

        private fun serverConnection(project: Project): ServerConnection? = getService(
            project,
            ProjectBindingManager::class.java
        ).tryGetServerConnection().orElse(null)
    }

    override fun isEnabled(e: AnActionEvent, project: Project, status: AnalysisStatus): Boolean {
        return (e.getData(DisableRuleAction.ISSUE_DATA_KEY) != null && e.getData(DisableRuleAction.ISSUE_DATA_KEY)?.serverFindingKey != null
            && e.getData(DisableRuleAction.ISSUE_DATA_KEY)?.isValid() == true) || (e.getData(TAINT_VULNERABILITY_DATA_KEY) != null)
    }

    override fun updatePresentation(e: AnActionEvent, project: Project) {
        val serverConnection = serverConnection(project) ?: return
        e.presentation.description = "Mark Issue as Resolved on ${serverConnection.productName}"
    }


    override fun actionPerformed(e: AnActionEvent) {
        val project = e.project ?: return
        var issue: Issue? = e.getData(DisableRuleAction.ISSUE_DATA_KEY)
        if (issue == null) {
            issue = e.getData(TAINT_VULNERABILITY_DATA_KEY)
        }
        if (issue == null) {
            return displayErrorNotification(project, errorTitle, "The issue could not be found", GROUP)
        }

        openMarkAsResolvedDialog(project, issue)
    }


    private class DoNotShowAgain : DoNotAskOption {
        override fun isToBeShown() = true

        override fun setToBeShown(toBeShown: Boolean, exitCode: Int) {
            PropertiesComponent.getInstance().setValue(SKIP_CONFIRM_DIALOG_PROPERTY, java.lang.Boolean.toString(!toBeShown))
        }

        override fun canBeHidden() = true

        override fun shouldSaveOptionsOnCancel() = false

        override fun getDoNotShowMessage() = "Don't show again"
    }


    override fun getPriority() = PriorityAction.Priority.NORMAL

    override fun getIcon(flags: Int) = AllIcons.Actions.BuildLoadChanges

    override fun startInWriteAction() = false

    override fun getText() = "SonarLint: Mark issue as..."

    override fun getFamilyName(): String {
        return "SonarLint mark issue as..."
    }

    override fun isAvailable(project: Project, editor: Editor?, file: PsiFile?) = issue?.getServerKey() != null

    override fun invoke(project: Project, editor: Editor?, file: PsiFile?) {
        file?.let {
            issue?.let { openMarkAsResolvedDialog(project, it) }
        }
    }

    private class CheckIssueStatusChangePermission(
        project: Project,
        connection: ServerConnection,
        issueKey: String,
    ) :
        FutureAwaitingTask<CheckStatusChangePermittedResponse>(
            project,
            "Checking permission to mark issue as resolved",
            getService(BackendService::class.java).checkIssueStatusChangePermitted(connection.name, issueKey)
        )
}
