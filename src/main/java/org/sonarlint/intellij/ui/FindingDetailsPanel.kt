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
package org.sonarlint.intellij.ui

import com.intellij.openapi.Disposable
import com.intellij.openapi.project.Project
import com.intellij.openapi.roots.ProjectRootManager
import com.intellij.openapi.util.text.StringUtil.capitalize
import com.intellij.ui.ScrollPaneFactory
import com.intellij.ui.components.JBTabbedPane
import org.sonarlint.intellij.common.util.SonarLintUtils
import org.sonarlint.intellij.editor.EditorDecorator
import org.sonarlint.intellij.finding.LiveFinding
import org.sonarlint.intellij.ui.tree.FlowsTree
import org.sonarlint.intellij.ui.tree.FlowsTreeModelBuilder


enum class FindingKind {
    ISSUE, SECURITY_HOTSPOT, MIX
}

class FindingDetailsPanel(private val project: Project, parentDisposable: Disposable, findingKind: FindingKind) : JBTabbedPane() {
    private lateinit var rulePanel: SonarLintRulePanel
    private lateinit var flowsTree: FlowsTree
    private lateinit var flowsTreeBuilder: FlowsTreeModelBuilder
    private val findingKindText: String

    init {
        findingKindText = when(findingKind) {
            FindingKind.ISSUE -> "issue"
            FindingKind.SECURITY_HOTSPOT -> "Security Hotspot"
            else -> "finding"
        }
        createFlowsTree()
        createTabs(parentDisposable)
    }

    private fun createFlowsTree() {
        flowsTreeBuilder = FlowsTreeModelBuilder()
        val model = flowsTreeBuilder.createModel()
        flowsTree = FlowsTree(project, model)
        flowsTreeBuilder.clearFlows()
        flowsTree.emptyText.setText("No $findingKindText selected")
    }

    private fun createTabs(parentDisposable: Disposable) {
        // Flows panel with tree
        val flowsPanel = ScrollPaneFactory.createScrollPane(flowsTree, true)
        flowsPanel.verticalScrollBar.unitIncrement = 10

        // Rule panel
        rulePanel = SonarLintRulePanel(project, parentDisposable)
        insertTab("Rule", null, rulePanel, "Details about the rule", RULE_TAB_INDEX)
        insertTab("Locations", null, flowsPanel, "All locations involved in the $findingKindText", LOCATIONS_TAB_INDEX)
    }

    fun show(liveFinding: LiveFinding) {
        val moduleForFile = ProjectRootManager.getInstance(project).fileIndex.getModuleForFile(liveFinding.psiFile().virtualFile)
        if (moduleForFile == null) {
            showInvalidFindingMessage()
            return
        }
        rulePanel.setSelectedFinding(moduleForFile, liveFinding)
        SonarLintUtils.getService(project, EditorDecorator::class.java).highlightFinding(liveFinding)
        flowsTree.emptyText.setText("Selected $findingKindText doesn't have flows")
        flowsTreeBuilder.populateForFinding(liveFinding)
        flowsTree.expandAll()
    }

    fun clear() {
        flowsTreeBuilder.clearFlows()
        flowsTree.emptyText.setText("No $findingKindText selected")
        rulePanel.clear()
    }

    fun selectRulesTab() {
        selectedIndex = RULE_TAB_INDEX
    }

    fun selectLocationsTab() {
        selectedIndex = LOCATIONS_TAB_INDEX
    }

    private fun showInvalidFindingMessage() {
        flowsTreeBuilder.clearFlows()
        flowsTree.emptyText.setText("${capitalize(findingKindText)} location has been deleted")
        rulePanel.clearDeletedFile()
    }

    companion object {
        private const val RULE_TAB_INDEX = 0
        private const val LOCATIONS_TAB_INDEX = 1
    }
}
