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
package org.sonarlint.intellij.editor

import com.intellij.openapi.editor.impl.DocumentMarkupModel
import com.intellij.testFramework.PlatformTestUtil
import org.assertj.core.api.Assertions.assertThat
import org.junit.jupiter.api.Test
import org.sonarlint.intellij.AbstractSonarLintLightTests

class EditorDecoratorTests : AbstractSonarLintLightTests() {

    @Test
    fun highlights_a_range_and_then_removes_it() {
        val file = myFixture.configureByText("Foo.java", "class Foo {}\n")
        val document = myFixture.editor.document
        val range = document.createRangeMarker(0, 5)
        val decorator = EditorDecorator(project)
        val markup = DocumentMarkupModel.forDocument(document, project, true)

        decorator.highlightRange(range)
        PlatformTestUtil.waitWithEventsDispatching("highlight never applied", { markup.allHighlighters.isNotEmpty() }, 10)

        decorator.removeHighlights()

        assertThat(markup.allHighlighters).isEmpty()
        assertThat(file.isValid).isTrue()
    }

}
