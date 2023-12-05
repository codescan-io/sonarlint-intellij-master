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
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02
 */
package org.sonarlint.intellij.fs

import com.intellij.openapi.vfs.VirtualFile
import com.intellij.openapi.vfs.newvfs.events.*
import org.assertj.core.api.Assertions.assertThat
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.mockito.Mockito.reset
import org.mockito.Mockito.verify
import org.mockito.Mockito.verifyNoInteractions
import org.mockito.kotlin.argumentCaptor
import org.mockito.kotlin.mock
import org.mockito.kotlin.whenever
import org.sonarlint.intellij.AbstractSonarLintLightTests
import org.sonarlint.intellij.core.ProjectBindingManager
import org.sonarlint.intellij.eq
import org.sonarsource.sonarlint.core.analysis.api.ClientModuleFileEvent
import org.sonarsource.sonarlint.core.client.api.common.SonarLintEngine
import org.sonarsource.sonarlint.plugin.api.module.file.ModuleFileEvent

private const val FILE_NAME = "main.py"

class VirtualFileSystemListenerTests : AbstractSonarLintLightTests() {
    @BeforeEach
    fun prepare() {
        replaceProjectService(ProjectBindingManager::class.java, projectBindingManager)
        whenever(projectBindingManager.engineIfStarted).thenReturn(fakeEngine)
        file = myFixture.copyFileToProject(FILE_NAME, FILE_NAME)
        reset(fileEventsNotifier)
        virtualFileSystemListener = VirtualFileSystemListener(fileEventsNotifier)
    }

    @Test
    fun should_notify_engine_of_a_file_deleted_event() {
        val vFileEvent = VFileDeleteEvent(null, file, false)

        virtualFileSystemListener.before(listOf(vFileEvent))

        assertEventNotified(ModuleFileEvent.Type.DELETED, FILE_NAME)
    }

    @Test
    fun should_not_notify_engine_of_a_non_py_file() {
        val nonPyFile = myFixture.copyFileToProject("file.txt", "file.txt")
        val vFileEvent = VFileDeleteEvent(null, nonPyFile, false)

        virtualFileSystemListener.before(listOf(vFileEvent))

        verify(fileEventsNotifier).notifyAsync(eq(fakeEngine), eq(module), eq(emptyList()))
    }

    @Test
    fun should_notify_engine_of_a_file_modified_event() {
        val vFileEvent = VFileContentChangeEvent(null, file, 0L, 0L, false)

        virtualFileSystemListener.after(listOf(vFileEvent))

        assertEventNotified(ModuleFileEvent.Type.MODIFIED, FILE_NAME)
    }

    @Test
    fun should_notify_engine_of_a_file_created_event() {
        val vFileEvent = VFileCreateEvent(null, file.parent, FILE_NAME, false, null, null, false, null)

        virtualFileSystemListener.after(listOf(vFileEvent))

        assertEventNotified(ModuleFileEvent.Type.CREATED, FILE_NAME)
    }

    @Test
    fun should_notify_engine_of_a_file_copied_event() {
        val copiedFile = myFixture.copyFileToProject(FILE_NAME, "$FILE_NAME.cp.py")
        val vFileEvent = VFileCopyEvent(null, file, file.parent, "$FILE_NAME.cp.py")

        virtualFileSystemListener.after(listOf(vFileEvent))

        assertEventNotified(ModuleFileEvent.Type.CREATED, "$FILE_NAME.cp.py", copiedFile)
    }

    @Test
    fun should_notify_engine_of_a_file_deleted_event_before_a_file_is_moved() {
        val vFileEvent = VFileMoveEvent(null, file, file.parent)

        virtualFileSystemListener.before(listOf(vFileEvent))

        assertEventNotified(ModuleFileEvent.Type.DELETED, FILE_NAME)
    }

    @Test
    fun should_notify_engine_of_a_file_created_event_after_a_file_is_moved() {
        val vFileEvent = VFileMoveEvent(null, file, file.parent)

        virtualFileSystemListener.after(listOf(vFileEvent))

        assertEventNotified(ModuleFileEvent.Type.CREATED, FILE_NAME)
    }

    @Test
    fun should_not_notify_engine_of_a_file_property_changed_event() {
        val vFileEvent = VFilePropertyChangeEvent(null, file, VirtualFile.PROP_NAME, "oldName", "newName", false)

        virtualFileSystemListener.after(listOf(vFileEvent))

        verifyNoInteractions(fileEventsNotifier)
    }

    @Test
    fun should_not_notify_engine_if_not_started() {
        whenever(projectBindingManager.engineIfStarted).thenReturn(null)
        val vFileEvent = VFileDeleteEvent(null, file, false)

        virtualFileSystemListener.after(listOf(vFileEvent))

        verifyNoInteractions(fileEventsNotifier)
    }

    @Test
    fun should_not_notify_engine_when_event_happens_on_an_empty_directory() {
        val directory = myFixture.tempDirFixture.findOrCreateDir("emptyDir")
        val vFileEvent = VFileDeleteEvent(null, directory, false)

        virtualFileSystemListener.after(listOf(vFileEvent))

        verifyNoInteractions(fileEventsNotifier)
    }

    @Test
    fun should_notify_engine_about_subfiles_when_event_happens_on_a_directory() {
        val directory = myFixture.copyDirectoryToProject("sub/folder", "sub/folder")
        val subfileName = "subfile.py"
        val childFile = directory.findChild(subfileName)!!
        val vFileEvent = VFileDeleteEvent(null, directory, false)

        virtualFileSystemListener.before(listOf(vFileEvent))

        assertEventNotified(ModuleFileEvent.Type.DELETED, subfileName, childFile, "sub/folder/$subfileName")
    }

    private fun assertEventNotified(type: ModuleFileEvent.Type, fileName: String, file: VirtualFile = this.file, relativePath: String = fileName) {
        argumentCaptor<List<ClientModuleFileEvent>>().apply {
            verify(fileEventsNotifier).notifyAsync(eq(fakeEngine), eq(module), capture())

            val events = firstValue
            assertThat(events).hasSize(1)
            val event = events[0]
            assertThat(event.type()).isEqualTo(type)
            val inputFile = event.target()
            assertThat(inputFile.contents()).contains("content")
            assertThat(inputFile.relativePath()).isEqualTo(relativePath)
            assertThat(inputFile.getClientObject<Any>() as VirtualFile).isEqualTo(file)
            assertThat(inputFile.path).isEqualTo("/src/$relativePath")
        }
    }

    private var projectBindingManager: ProjectBindingManager = mock()
    private var fakeEngine: SonarLintEngine = mock()
    private var fileEventsNotifier: ModuleFileEventsNotifier = mock()
    private lateinit var file: VirtualFile
    private lateinit var virtualFileSystemListener: VirtualFileSystemListener
}
