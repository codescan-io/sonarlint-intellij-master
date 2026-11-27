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
package org.sonarlint.intellij.its.utils

import org.assertj.core.api.Assertions.assertThat
import org.junit.jupiter.api.Test

// Runs without an IDE: it checks which errors the IDE reported make a UI test fail.
class IdeErrorsTest {

    private val pluginFrame = "\tat org.sonarlint.intellij.analysis.AnalysisSubmitter.analyzeOpenFiles(AnalysisSubmitter.kt:95)"

    @Test
    fun `an exception from the plugin fails the test`() {
        val error = "message=Cannot read storage, stacktrace=java.lang.IllegalStateException: boom\n$pluginFrame"

        assertThat(IdeErrors.failsTest(error)).isTrue()
    }

    @Test
    fun `an exception from the analysis library fails the test`() {
        val error = "message=null, stacktrace=java.lang.NullPointerException\n\tat org.sonarsource.sonarlint.core.Foo.bar(Foo.java:1)"

        assertThat(IdeErrors.failsTest(error)).isTrue()
    }

    @Test
    fun `an error from another plugin does not fail the test`() {
        val error = "message=oops, stacktrace=java.lang.IllegalStateException\n\tat com.intellij.openapi.Foo.bar(Foo.java:1)"

        assertThat(IdeErrors.failsTest(error)).isFalse()
    }

    @Test
    fun `a slow operation on the UI thread does not fail the test, the IDE log check reports it`() {
        val error = "message=Slow operations are prohibited on EDT. See SlowOperations.assertSlowOperationsAreAllowed javadoc., " +
            "stacktrace=java.lang.Throwable: Slow operations are prohibited on EDT.\n$pluginFrame"

        assertThat(IdeErrors.failsTest(error)).isFalse()
    }

    @Test
    fun `reading outside a read action does not fail the test, the IDE log check reports it`() {
        val error = "message=Read access is allowed from inside read-action only (see Application.runReadAction()), " +
            "stacktrace=com.intellij.openapi.diagnostic.RuntimeExceptionWithAttachments: Read access is allowed from inside read-action\n$pluginFrame"

        assertThat(IdeErrors.failsTest(error)).isFalse()
    }

    @Test
    fun `UI work off the UI thread does not fail the test, the IDE log check reports it`() {
        val error = "message=Access is allowed from Event Dispatch Thread (EDT) only, " +
            "stacktrace=com.intellij.openapi.diagnostic.RuntimeExceptionWithAttachments: Access is allowed from Event Dispatch Thread (EDT) only\n$pluginFrame"

        assertThat(IdeErrors.failsTest(error)).isFalse()
    }

}
