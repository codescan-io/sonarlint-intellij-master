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
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02
 */
package org.sonarlint.intellij.actions

import com.intellij.openapi.actionSystem.AnActionEvent
import org.assertj.core.api.Assertions.assertThat
import org.junit.jupiter.api.Test
import org.mockito.Mockito
import org.mockito.Mockito.`when`
import org.sonarlint.intellij.AbstractSonarLintLightTests
import org.sonarlint.intellij.actions.filters.IncludeResolvedHotspotsAction

class FilterSecurityHotspotActionTests : AbstractSonarLintLightTests() {

    val event: AnActionEvent = Mockito.mock(AnActionEvent::class.java)

    @Test
    fun shouldNotBeSelectedByDefault() {
        val includeResolvedHotspotsAction =
            IncludeResolvedHotspotsAction("", "", null)
        assertThat(includeResolvedHotspotsAction.isSelected(event)).isFalse();
    }

    @Test
    fun shouldChangeAfterUpdate() {
        `when`(event.project).thenReturn(project)
        val includeResolvedHotspotsAction =
            IncludeResolvedHotspotsAction("", "", null)
        includeResolvedHotspotsAction.setSelected(event, true)
        assertThat(includeResolvedHotspotsAction.isSelected(event)).isTrue()
    }

}
