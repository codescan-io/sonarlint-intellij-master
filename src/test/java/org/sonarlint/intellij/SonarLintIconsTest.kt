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
package org.sonarlint.intellij

import org.assertj.core.api.Assertions.assertThat
import org.junit.jupiter.api.Test
import org.sonarlint.intellij.SonarLintIcons.hotspotTypeWithProbability
import org.sonarlint.intellij.SonarLintIcons.severity
import org.sonarlint.intellij.SonarLintIcons.toDisabled
import org.sonarlint.intellij.SonarLintIcons.type
import org.sonarsource.sonarlint.core.commons.IssueSeverity
import org.sonarsource.sonarlint.core.commons.RuleType
import org.sonarsource.sonarlint.core.commons.VulnerabilityProbability

class SonarLintIconsTest {
    @Test
    fun testSeverities() {
        for (value in IssueSeverity.values()) {
            assertThat(severity(value)).isNotNull
        }
    }

    @Test
    fun testTypes() {
        for (value in RuleType.values()) {
            assertThat(type(value)).isNotNull
        }
        for (value in VulnerabilityProbability.values()) {
            assertThat(hotspotTypeWithProbability(value)).isNotNull
        }
    }

    @Test
    fun testIcons() {
        assertThat(SonarLintIcons.CLEAN).isNotNull
        assertThat(SonarLintIcons.ICON_SONARQUBE_16).isNotNull
        assertThat(SonarLintIcons.INFO).isNotNull
        assertThat(SonarLintIcons.PLAY).isNotNull
        assertThat(SonarLintIcons.SONARLINT).isNotNull
        assertThat(SonarLintIcons.SUSPEND).isNotNull
        assertThat(SonarLintIcons.TOOLS).isNotNull
        assertThat(SonarLintIcons.WARN).isNotNull
    }

    @Test
    fun testDisabled() {
        assertThat(toDisabled(SonarLintIcons.WARN)).isNotNull
    }
}