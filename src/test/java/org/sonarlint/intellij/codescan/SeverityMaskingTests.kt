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
package org.sonarlint.intellij.codescan

import com.intellij.openapi.project.Project
import org.assertj.core.api.Assertions.assertThat
import org.junit.jupiter.api.Test
import org.mockito.Mockito.mock
import org.sonarlint.intellij.finding.issue.SeverityMaskingService

/** CodeScan names for severities, from the project settings codescan.severity.masking.<SEVERITY> (7.3.2, CD-7909). */
class SeverityMaskingTests {

    private val service = SeverityMaskingService(mock(Project::class.java))

    @Test
    fun keepsOnlyMaskingSettingsWithText() {
        val masks = SeverityMaskingService.extractMasks(
            mapOf(
                "codescan.severity.masking.MAJOR" to " Important ",
                "codescan.severity.masking.minor" to "Low",
                "codescan.severity.masking.INFO" to "  ",
                "sonar.exclusions" to "**/test/**",
            )
        )

        assertThat(masks).containsExactlyInAnyOrderEntriesOf(mapOf("MAJOR" to "Important", "MINOR" to "Low"))
    }

    @Test
    fun givesTheMaskOrNull() {
        service.update(mapOf("codescan.severity.masking.BLOCKER" to "Stop ship"))

        assertThat(service.mask("BLOCKER")).isEqualTo("Stop ship")
        assertThat(service.mask("blocker")).isEqualTo("Stop ship")
        assertThat(service.mask("MAJOR")).isNull()
        assertThat(service.mask(null)).isNull()
    }

    @Test
    fun forgetsMasksTheProjectNoLongerSets() {
        service.update(mapOf("codescan.severity.masking.BLOCKER" to "Stop ship", "codescan.severity.masking.MAJOR" to "Important"))

        // unbound project, or the setting was removed on the server
        service.update(mapOf("codescan.severity.masking.MAJOR" to "Serious"))

        assertThat(service.mask("BLOCKER")).isNull()
        assertThat(service.mask("MAJOR")).isEqualTo("Serious")
    }

    @Test
    fun eachProjectHasItsOwnMasks() {
        val other = SeverityMaskingService(mock(Project::class.java))
        service.update(mapOf("codescan.severity.masking.MAJOR" to "Important"))

        assertThat(other.mask("MAJOR")).isNull()
    }
}
