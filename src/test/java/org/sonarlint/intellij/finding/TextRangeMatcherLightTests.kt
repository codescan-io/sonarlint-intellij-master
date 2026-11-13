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
package org.sonarlint.intellij.finding

import org.assertj.core.api.Assertions.assertThat
import org.junit.jupiter.api.Test
import org.sonarlint.intellij.AbstractSonarLintLightTests
import org.sonarlint.intellij.common.ui.ReadActionUtils.Companion.computeReadActionSafely
import org.sonarsource.sonarlint.core.rpc.protocol.common.TextRangeDto

class TextRangeMatcherLightTests : AbstractSonarLintLightTests() {

    @Test
    fun matchWithCode_returns_null_instead_of_throwing_when_the_range_is_outside_the_file() {
        val file = myFixture.configureByText("file.ext", "one line").virtualFile

        val rangeMarker = computeReadActionSafely(project) {
            TextRangeMatcher(project).matchWithCode(file, TextRangeDto(5, 0, 5, 3), "abc")
        }

        assertThat(rangeMarker).isNull()
    }

    @Test
    fun matchWithCode_returns_a_range_when_the_code_matches() {
        val file = myFixture.configureByText("file.ext", "one line").virtualFile

        val rangeMarker = computeReadActionSafely(project) {
            TextRangeMatcher(project).matchWithCode(file, TextRangeDto(1, 0, 1, 3), "one")
        }

        assertThat(rangeMarker?.startOffset).isEqualTo(0)
        assertThat(rangeMarker?.endOffset).isEqualTo(3)
    }
}
