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
<<<<<<<< HEAD:src/test/java/org/sonarlint/intellij/RunInEdtInterceptor.kt
<<<<<<<< HEAD:src/test/java/org/sonarlint/intellij/RunInEdtInterceptor.kt
package org.sonarlint.intellij
========
package org.sonarlint.intellij.git
>>>>>>>> 1016ecda6 (SLI-1531 Update to IntelliJ Platform Gradle Plugin (2.x)):test-common/src/testFixtures/kotlin/org/sonarlint/intellij/git/RunInEdtInterceptor.kt
========
package org.sonarlint.intellij.fixtures
>>>>>>>> 068d933ed (Support minimum version to 2023.1):test-common/src/testFixtures/kotlin/org/sonarlint/intellij/fixtures/RunInEdtInterceptor.kt

import com.intellij.testFramework.UITestUtil
import com.intellij.testFramework.runInEdtAndWait
import org.junit.jupiter.api.extension.ExtensionContext
import org.junit.jupiter.api.extension.InvocationInterceptor
import org.junit.jupiter.api.extension.ReflectiveInvocationContext
import java.lang.reflect.Method

// Warning: InvocationInterceptor is in Experimental status
class RunInEdtInterceptor : InvocationInterceptor {
    companion object {
        init {
            UITestUtil.replaceIdeEventQueueSafely()
        }
    }

    override fun interceptBeforeAllMethod(
        invocation: InvocationInterceptor.Invocation<Void>,
        invocationContext: ReflectiveInvocationContext<Method>,
        extensionContext: ExtensionContext
    ) {
        runInEdtAndWait { invocation.proceed() }
    }

    override fun interceptBeforeEachMethod(
        invocation: InvocationInterceptor.Invocation<Void>,
        invocationContext: ReflectiveInvocationContext<Method>,
        extensionContext: ExtensionContext
    ) {
        runInEdtAndWait { invocation.proceed() }
    }
    override fun interceptTestMethod(
        invocation: InvocationInterceptor.Invocation<Void>,
        invocationContext: ReflectiveInvocationContext<Method>,
        extensionContext: ExtensionContext
    ) {
        runInEdtAndWait { invocation.proceed() }
    }

    override fun interceptAfterEachMethod(
        invocation: InvocationInterceptor.Invocation<Void>,
        invocationContext: ReflectiveInvocationContext<Method>,
        extensionContext: ExtensionContext
    ) {
        runInEdtAndWait { invocation.proceed() }
    }

    override fun interceptAfterAllMethod(
        invocation: InvocationInterceptor.Invocation<Void>,
        invocationContext: ReflectiveInvocationContext<Method>,
        extensionContext: ExtensionContext
    ) {
        runInEdtAndWait { invocation.proceed() }
    }
}
