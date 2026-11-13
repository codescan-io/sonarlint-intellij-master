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
package org.sonarlint.intellij.ui.ruledescription

import com.intellij.openapi.application.impl.LaterInvocator
import com.intellij.openapi.editor.EditorFactory
import com.intellij.openapi.fileTypes.PlainTextFileType
import com.intellij.openapi.util.Disposer
import com.intellij.testFramework.PlatformTestUtil
import org.assertj.core.api.Assertions.assertThat
import org.junit.jupiter.api.Test
import org.sonarlint.intellij.AbstractSonarLintLightTests
import org.sonarlint.intellij.ui.ruledescription.section.CodeExampleFragment
import org.sonarlint.intellij.ui.ruledescription.section.CodeExampleType

class RuleCodeSnippetTests : AbstractSonarLintLightTests() {

    @Test
    fun diff_highlighting_is_computed_off_the_ui_thread_and_applied_later() {
        val compliant = CodeExampleFragment("val a = 1\nval b = 2\n", CodeExampleType.Compliant, "1")
        val nonCompliant = CodeExampleFragment("val a = 1\nvar b = 3\n", CodeExampleType.NonCompliant, "1")
        compliant.diffTarget = nonCompliant

        val snippet = RuleCodeSnippet(project, PlainTextFileType.INSTANCE, compliant)
        try {
            val editor = EditorFactory.getInstance().allEditors.single { it.getUserData(RuleCodeSnippet.CODE_EXAMPLE_FRAGMENT_KEY) === compliant }

            assertThat(editor.document.text).isEqualTo("val a = 1\nval b = 2\n")
            assertThat(editor.markupModel.allHighlighters).isEmpty()

            PlatformTestUtil.waitWithEventsDispatching("diff highlights never applied", { editor.markupModel.allHighlighters.isNotEmpty() }, 10)
        } finally {
            Disposer.dispose(snippet)
        }
    }

    @Test
    fun diff_highlighting_is_applied_while_a_modal_dialog_such_as_settings_is_open() {
        val compliant = CodeExampleFragment("val a = 1\nval b = 2\n", CodeExampleType.Compliant, "1")
        val nonCompliant = CodeExampleFragment("val a = 1\nvar b = 3\n", CodeExampleType.NonCompliant, "1")
        compliant.diffTarget = nonCompliant
        // the rules page builds this snippet inside the modal Settings dialog
        val settingsDialog = Any()
        LaterInvocator.enterModal(settingsDialog)
        try {
            val snippet = RuleCodeSnippet(project, PlainTextFileType.INSTANCE, compliant)
            try {
                val editor = EditorFactory.getInstance().allEditors.single { it.getUserData(RuleCodeSnippet.CODE_EXAMPLE_FRAGMENT_KEY) === compliant }

                PlatformTestUtil.waitWithEventsDispatching("diff highlights not applied while the dialog is open", { editor.markupModel.allHighlighters.isNotEmpty() }, 5)
            } finally {
                Disposer.dispose(snippet)
            }
        } finally {
            LaterInvocator.leaveModal(settingsDialog)
        }
    }

}
