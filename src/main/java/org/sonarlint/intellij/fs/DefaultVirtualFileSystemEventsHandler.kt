/*
 * SonarLint for IntelliJ IDEA
 * Copyright (C) 2015-2024 SonarSource
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
package org.sonarlint.intellij.fs

import com.intellij.openapi.Disposable
import com.intellij.openapi.module.Module
import com.intellij.openapi.module.ModuleUtil
import com.intellij.openapi.project.Project
import com.intellij.openapi.project.ProjectCoreUtil
import com.intellij.openapi.project.ProjectManager
import com.intellij.openapi.vfs.VfsUtilCore
import com.intellij.openapi.vfs.VirtualFile
import com.intellij.openapi.vfs.VirtualFileVisitor
import com.intellij.openapi.vfs.newvfs.events.VFileCopyEvent
import com.intellij.openapi.vfs.newvfs.events.VFileEvent
import com.intellij.serviceContainer.NonInjectable
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import org.sonarlint.intellij.common.util.SonarLintUtils.getService
import org.sonarlint.intellij.common.util.SonarLintUtils.isRider
import org.sonarlint.intellij.core.ProjectBindingManager
import org.sonarsource.sonarlint.core.analysis.api.ClientModuleFileEvent
import org.sonarsource.sonarlint.core.client.api.common.SonarLintEngine
import org.sonarsource.sonarlint.plugin.api.module.file.ModuleFileEvent

open class DefaultVirtualFileSystemEventsHandler @NonInjectable constructor(private val executorService: ExecutorService) : VirtualFileSystemEventsHandler, Disposable {

    // default constructor used for the application service instantiation
    // keep events in order with a single thread executor
    constructor() : this(Executors.newSingleThreadExecutor { r -> Thread(r, "sonarlint-vfs-events-notifier") })

    override fun forwardEventsAsync(events: List<VFileEvent>, eventTypeConverter: (VFileEvent) -> ModuleFileEvent.Type?, fileEventsNotifier: ModuleFileEventsNotifier) {
        executorService.submit { forwardEvents(events, eventTypeConverter, fileEventsNotifier) }
    }

    private fun forwardEvents(events: List<VFileEvent>, eventTypeConverter: (VFileEvent) -> ModuleFileEvent.Type?, fileEventsNotifier: ModuleFileEventsNotifier) {
        val openProjects = ProjectManager.getInstance().openProjects.filter { !it.isDisposed }.toList()
        val startedEnginesByProject = openProjects.associateWith { getEngineIfStarted(it) }
        val filesByModule = fileEventsByModules(events, openProjects, eventTypeConverter)
        filesByModule.forEach { (module, fileEvents) ->
            startedEnginesByProject[module.project]?.let {
                fileEventsNotifier.notifyAsync(it, module, fileEvents)
            }
        }
    }

    private fun getEngineIfStarted(project: Project): SonarLintEngine? =
        getService(project, ProjectBindingManager::class.java).engineIfStarted

    private fun fileEventsByModules(
        events: List<VFileEvent>,
        openProjects: List<Project>,
        eventTypeConverter: (VFileEvent) -> ModuleFileEvent.Type?,
    ): Map<Module, List<ClientModuleFileEvent>> {
        val map: MutableMap<Module, List<ClientModuleFileEvent>> = mutableMapOf()
        for (event in events) {
            // call event.file only once as it can be hurting performance
            val file = event.file ?: continue
            if (ProjectCoreUtil.isProjectOrWorkspaceFile(file, file.fileType)) continue
            val fileModule = findModule(file, openProjects) ?: continue
            val fileInvolved = if (event is VFileCopyEvent) event.findCreatedFile() else file
            fileInvolved ?: continue
            val type = eventTypeConverter(event) ?: continue
            val moduleEvents = map[fileModule] ?: emptyList()
            map[fileModule] = moduleEvents + allEventsFor(fileInvolved, fileModule, type)
        }
        return map
    }

    private fun allEventsFor(file: VirtualFile, fileModule: Module, type: ModuleFileEvent.Type): List<ClientModuleFileEvent> {
        val allFilesInvolved = mutableListOf<VirtualFile>()
        VfsUtilCore.visitChildrenRecursively(file, object : VirtualFileVisitor<Unit>() {
            override fun visitFile(file: VirtualFile): Boolean {
                // SLI-551 Only send events on .py files (avoid parse errors)
                // For Rider, send all events for OmniSharp
                if (!file.isDirectory && (isRider() || isPython(file))) {
                    allFilesInvolved.add(file)
                }
                return !fileModule.project.isDisposed
            }
        })
        return allFilesInvolved.mapNotNull { buildModuleFileEvent(fileModule, it, type) }
    }

    private fun findModule(file: VirtualFile?, openProjects: List<Project>): Module? {
        file ?: return null
        return openProjects.asSequence()
            .filter { !it.isDisposed }
            .map { ModuleUtil.findModuleForFile(file, it) }
            .find { it != null }
    }

    private fun isPython(file: VirtualFile): Boolean {
        return file.path.endsWith(".py")
    }

    override fun dispose() {
        executorService.shutdownNow()
    }
}
