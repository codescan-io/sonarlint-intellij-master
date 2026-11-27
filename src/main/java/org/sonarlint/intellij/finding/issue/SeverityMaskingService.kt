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
package org.sonarlint.intellij.finding.issue

import com.intellij.openapi.components.Service
import com.intellij.openapi.project.Project
import java.util.concurrent.ConcurrentHashMap
import org.sonarlint.intellij.common.util.SonarLintUtils.getService
import org.sonarlint.intellij.core.BackendService
import org.sonarlint.intellij.util.GlobalLogOutput
import org.sonarsource.sonarlint.core.client.utils.ClientLogOutput

/**
 * CodeScan: the names a CodeScan project gives to the old severities (BLOCKER ... INFO), read from the project settings
 * `codescan.severity.masking.<SEVERITY>`. The backend saves those settings during sync; [refresh] reads them on a
 * background thread, so [mask] never waits and never talks to the backend. One instance per project.
 */
@Service(Service.Level.PROJECT)
class SeverityMaskingService(private val project: Project) {

    private val masks = ConcurrentHashMap<String, String>()

    /** The CodeScan name for [severity] (for example "MAJOR"), or null when the project does not set one. */
    fun mask(severity: String?): String? = severity?.let { masks[it.uppercase()] }

    /** Ask the backend for the saved project settings and keep the masking ones. Returns at once. */
    fun refresh() {
        if (project.isDisposed) return
        getService(BackendService::class.java).getProjectServerSettings(project)
            .thenAccept { update(it) }
            .exceptionally {
                GlobalLogOutput.get().log("Could not read CodeScan severity names: ${it.message}", ClientLogOutput.Level.DEBUG)
                null
            }
    }

    fun update(settings: Map<String, String>) {
        val newMasks = extractMasks(settings)
        masks.keys.retainAll(newMasks.keys)
        masks.putAll(newMasks)
    }

    companion object {
        const val MASK_PREFIX = "codescan.severity.masking."

        fun extractMasks(settings: Map<String, String>): Map<String, String> =
            settings.filter { (key, value) -> key.startsWith(MASK_PREFIX) && value.isNotBlank() }
                .mapKeys { it.key.removePrefix(MASK_PREFIX).uppercase() }
                .mapValues { it.value.trim() }
    }
}
