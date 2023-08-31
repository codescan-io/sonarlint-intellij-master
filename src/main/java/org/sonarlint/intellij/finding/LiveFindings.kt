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
package org.sonarlint.intellij.finding

import com.intellij.openapi.vfs.VirtualFile
import org.sonarlint.intellij.finding.hotspot.LiveSecurityHotspot
import org.sonarlint.intellij.finding.issue.LiveIssue

class LiveFindings(
    val issuesPerFile: Map<VirtualFile, Collection<LiveIssue>>,
    val securityHotspotsPerFile: Map<VirtualFile, Collection<LiveSecurityHotspot>>,
) {
    val filesInvolved = issuesPerFile.keys + securityHotspotsPerFile.keys

    fun onlyFor(files: Set<VirtualFile>): LiveFindings {
        return LiveFindings(
            issuesPerFile.filterKeys { files.contains(it) },
            securityHotspotsPerFile.filterKeys { files.contains(it) })
    }

    companion object {
        @JvmStatic
        fun none() : LiveFindings {
            return LiveFindings(emptyMap(), emptyMap())
        }
    }
}