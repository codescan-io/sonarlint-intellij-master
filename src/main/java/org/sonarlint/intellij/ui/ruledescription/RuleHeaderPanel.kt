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
package org.sonarlint.intellij.ui.ruledescription

import com.intellij.openapi.project.Project
import com.intellij.openapi.util.text.StringUtil
import com.intellij.ui.components.JBLabel
import com.intellij.ui.components.JBPanel
import com.intellij.ui.components.panels.HorizontalLayout
import com.intellij.util.ui.JBFont
import com.intellij.util.ui.JBUI
import com.intellij.util.ui.WrapLayout
import org.sonarlint.intellij.SonarLintIcons
import org.sonarlint.intellij.actions.MarkAsResolvedAction.Companion.canBeMarkedAsResolved
import org.sonarlint.intellij.actions.MarkAsResolvedAction.Companion.openMarkAsResolvedDialog
import org.sonarlint.intellij.actions.ReviewSecurityHotspotAction
import org.sonarlint.intellij.finding.Issue
import org.sonarlint.intellij.finding.hotspot.LiveSecurityHotspot
import org.sonarsource.sonarlint.core.commons.CleanCodeAttribute
import org.sonarsource.sonarlint.core.commons.ImpactSeverity
import org.sonarsource.sonarlint.core.commons.IssueSeverity
import org.sonarsource.sonarlint.core.commons.RuleType
import org.sonarsource.sonarlint.core.commons.SoftwareQuality
import java.awt.BorderLayout
import java.awt.FlowLayout
import java.awt.event.ActionEvent
import java.util.LinkedList
import javax.swing.AbstractAction
import javax.swing.BorderFactory
import javax.swing.JButton
import javax.swing.JPanel
import javax.swing.SwingConstants


class RuleHeaderPanel : JBPanel<RuleHeaderPanel>(BorderLayout()) {
    companion object {
        private const val MARK_AS_RESOLVED = "Mark Issue as..."
    }

    private val wrappedPanel = JBPanel<JBPanel<*>>(WrapLayout(FlowLayout.LEFT))
    private val attributeLabel = JBLabel()
    private val qualityLabels = LinkedList<JBLabel>()
    private val ruleTypeIcon = JBLabel()
    private val ruleTypeLabel = JBLabel()
    private val ruleSeverityIcon = JBLabel()
    private val ruleSeverityLabel = JBLabel()
    private val hotspotVulnerabilityLabel = JBLabel("Review priority: ")
    private val hotspotVulnerabilityValueLabel = JBLabel()
    private val ruleKeyLabel = JBLabel()
    private val changeStatusButton = JButton()

    fun clear() {
        attributeLabel.text = ""
        qualityLabels.clear()
        ruleTypeIcon.icon = null
        ruleTypeLabel.text = ""
        ruleKeyLabel.text = ""
        ruleSeverityIcon.icon = null
        ruleSeverityLabel.text = ""
        hotspotVulnerabilityLabel.isVisible = false
        hotspotVulnerabilityValueLabel.text = ""
        changeStatusButton.isVisible = false
        wrappedPanel.removeAll()
        removeAll()
        repaint()
    }

    fun updateForRuleConfiguration(ruleKey: String, type: RuleType, severity: IssueSeverity,
               attribute: CleanCodeAttribute?, qualities: Map<SoftwareQuality, ImpactSeverity>) {
        clear()
        updateCommonFields(type, attribute, qualities, ruleKey)
        updateRuleSeverity(severity)
    }

    fun updateForIssue(project: Project, type: RuleType, severity: IssueSeverity, issue: Issue) {
        clear()
        updateCommonFields(type, issue.getCleanCodeAttribute(), issue.getImpacts(), issue.getRuleKey())
        updateRuleSeverity(severity)

        if (canBeMarkedAsResolved(project, issue)) {
            changeStatusButton.isVisible = true
            changeStatusButton.action = object : AbstractAction(MARK_AS_RESOLVED) {
                override fun actionPerformed(e: ActionEvent?) {
                    openMarkAsResolvedDialog(project, issue)
                }
            }
        }
    }

    private fun updateRuleSeverity(severity: IssueSeverity) {
        ruleSeverityIcon.icon = SonarLintIcons.severity(severity)
        ruleSeverityLabel.text = clean(severity.toString())
        ruleSeverityLabel.setCopyable(true)
    }

    fun updateForSecurityHotspot(project: Project, ruleKey: String, type: RuleType, securityHotspot: LiveSecurityHotspot) {
        clear()
        updateCommonFields(type, securityHotspot.getCleanCodeAttribute(), securityHotspot.getImpacts(), ruleKey)
        ruleTypeIcon.icon = SonarLintIcons.hotspotTypeWithProbability(securityHotspot.vulnerabilityProbability)
        hotspotVulnerabilityLabel.isVisible = true
        hotspotVulnerabilityValueLabel.apply {
            text = securityHotspot.vulnerabilityProbability.name
            setCopyable(true)
            background = SonarLintIcons.colorsByProbability[securityHotspot.vulnerabilityProbability]
        }

        securityHotspot.serverFindingKey?.let {
            changeStatusButton.action = object : AbstractAction("Change Status") {
                override fun actionPerformed(e: ActionEvent?) {
                    ReviewSecurityHotspotAction(it, securityHotspot.status).openReviewingDialog(project, securityHotspot.file)
                }
            }
            changeStatusButton.isVisible = securityHotspot.isValid()
        }
    }

    private fun updateCommonFields(type: RuleType, attribute: CleanCodeAttribute?, qualities: Map<SoftwareQuality, ImpactSeverity>, ruleKey: String) {
        val newCctEnabled = attribute != null && qualities.isNotEmpty()
        if (newCctEnabled) {
            attributeLabel.text = "<html><b>" + clean(attribute!!.attributeCategory.issueLabel) + " issue</b> | Not " + clean(attribute.toString()) + "<br></html>"
            qualities.entries.forEach {
                qualityLabels.addAll(listOf(
                    JBLabel().apply { icon = SonarLintIcons.impact(it.value) },
                    JBLabel(clean(it.key.toString())).apply { setCopyable(true) })
                )
            }
        } else {
            ruleTypeIcon.icon = SonarLintIcons.type(type)
            ruleTypeLabel.text = clean(type.toString())
            ruleTypeLabel.setCopyable(true)
        }
        ruleKeyLabel.text = ruleKey
        ruleKeyLabel.setCopyable(true)

        organizeHeader(newCctEnabled)
    }

    private fun organizeHeader(newCct: Boolean) {
        if (newCct) {
            wrappedPanel.add(attributeLabel.apply { border = BorderFactory.createEmptyBorder(0, 0, 0, 15) })
            qualityLabels.forEach { wrappedPanel.add(it) }
        } else {
            wrappedPanel.add(ruleTypeIcon)
            wrappedPanel.add(ruleTypeLabel.apply {
                border = JBUI.Borders.emptyRight(0)
            })
            wrappedPanel.add(ruleSeverityIcon)
            wrappedPanel.add(ruleSeverityLabel)
            wrappedPanel.add(hotspotVulnerabilityLabel)
            wrappedPanel.add(hotspotVulnerabilityValueLabel.apply {
                font = JBFont.label().asBold()
                verticalTextPosition = SwingConstants.CENTER
                isOpaque = true
                border = BorderFactory.createEmptyBorder(0, 15, 0, 15)
            })
        }
        wrappedPanel.add(ruleKeyLabel.apply {
            border = JBUI.Borders.emptyLeft(10)
        }, HorizontalLayout.CENTER)
        val changeStatusPanel = JPanel(FlowLayout(FlowLayout.CENTER, 0, 0))
        changeStatusPanel.apply { border = BorderFactory.createEmptyBorder(0, 15, 0, 0) }

        changeStatusPanel.add(changeStatusButton)
        wrappedPanel.add(changeStatusPanel)
        add(wrappedPanel, BorderLayout.CENTER)
    }

    fun showMessage(msg: String) {
        clear()
        ruleTypeLabel.text = msg
    }

    private fun clean(txt: String): String {
        return StringUtil.capitalizeWords(txt.lowercase().replace("_", " "), true)
    }

}
