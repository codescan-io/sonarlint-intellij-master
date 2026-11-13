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

import com.intellij.openapi.Disposable
import com.intellij.openapi.util.registry.Registry
import com.intellij.util.SlowOperations

/**
 * Turns on the platform's "Slow operations are prohibited on EDT" check, which is always off in unit-test mode.
 * A slow operation on the UI thread then makes the test logger fail the test, as it fails an internal-mode IDE.
 * Relies on the private field SlowOperations.ourAlwaysAllow of IntelliJ 2023.1 (the platform the tests run on).
 */
object SlowOperationsChecks {

    @JvmStatic
    fun <T> withSlowOperationChecks(parent: Disposable, action: () -> T): T {
        val alwaysAllow = SlowOperations::class.java.getDeclaredField("ourAlwaysAllow").apply { isAccessible = true }
        val previous = alwaysAllow.getInt(null)
        Registry.get("ide.slow.operations.assertion").setValue(true, parent)
        Registry.get("ide.slow.operations.assertion.other").setValue(true, parent)
        alwaysAllow.setInt(null, 0)
        try {
            return action()
        } finally {
            alwaysAllow.setInt(null, previous)
        }
    }

}
