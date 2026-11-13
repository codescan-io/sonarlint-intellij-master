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
package org.sonarlint.intellij

import com.intellij.openapi.util.Disposer
import com.intellij.psi.search.FilenameIndex
import com.intellij.psi.search.GlobalSearchScope
import com.intellij.util.SlowOperations
import org.assertj.core.api.Assertions.assertThat
import org.assertj.core.api.Assertions.assertThatThrownBy
import org.junit.jupiter.api.Test
import org.sonarlint.intellij.SlowOperationsChecks.withSlowOperationChecks

class SlowOperationsChecksTests : AbstractSonarLintLightTests() {

    @Test
    fun should_fail_on_a_slow_operation_on_the_ui_thread() {
        val disposable = Disposer.newDisposable()
        try {
            assertThatThrownBy {
                withSlowOperationChecks(disposable) {
                    FilenameIndex.getVirtualFilesByName("any.txt", GlobalSearchScope.projectScope(project))
                }
            }.hasMessageContaining("Slow operations are prohibited on EDT")
        } finally {
            Disposer.dispose(disposable)
        }
    }

    @Test
    fun should_leave_checks_off_after_the_block() {
        val disposable = Disposer.newDisposable()
        withSlowOperationChecks(disposable) { }
        Disposer.dispose(disposable)

        SlowOperations.assertSlowOperationsAreAllowed()
        assertThat(SlowOperations.isAlwaysAllowed()).isTrue()
    }

}
