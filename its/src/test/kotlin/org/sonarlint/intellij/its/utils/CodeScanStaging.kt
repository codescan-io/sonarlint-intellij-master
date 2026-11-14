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

import org.sonarlint.intellij.its.BaseUiTest

/**
 * Settings of a live CodeScan server for CodeScanStagingTests, all from environment variables:
 * CODESCAN_TOKEN (required; without it the test is skipped), CODESCAN_URL (default https://staging.codescan.io),
 * CODESCAN_ORG and CODESCAN_PROJECT. The token is never read here: the UI-test IDE reads it from its own environment and
 * puts it into the password field itself, so it is never part of a script, a step name or a log line of the tests.
 */
object CodeScanStaging {
    const val TOKEN_VARIABLE = "CODESCAN_TOKEN"
    private const val DEFAULT_URL = "https://staging.codescan.io"

    val url: String
        get() = variable("CODESCAN_URL") ?: DEFAULT_URL

    val organization: String
        get() = requireNotNull(variable("CODESCAN_ORG")) { "CODESCAN_ORG is not set: the organization key on $url" }

    val projectKey: String
        get() = requireNotNull(variable("CODESCAN_PROJECT")) { "CODESCAN_PROJECT is not set: the project key in $organization" }

    // Used by @EnabledIf: the token check comes first, so that without one the IDE is never contacted.
    @JvmStatic
    fun shouldRun(): Boolean = variable(TOKEN_VARIABLE) != null && BaseUiTest.isIdea()

    private fun variable(name: String): String? = System.getenv(name)?.trim()?.takeIf { it.isNotEmpty() }
}
