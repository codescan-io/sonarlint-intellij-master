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
package org.sonarlint.intellij.common.ui

import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.application.ModalityState
import com.intellij.openapi.progress.ProgressManager
import com.intellij.openapi.project.Project
import com.intellij.openapi.vfs.VirtualFile
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import org.assertj.core.api.Assertions.assertThat
import org.junit.jupiter.api.Test
import org.mockito.Mockito.mock
import org.mockito.Mockito.`when`
import org.sonarlint.intellij.AbstractSonarLintLightTests
import org.sonarlint.intellij.ui.UiUtils.Companion.runOnUiThreadAndWait

class ReadActionUtilsTests : AbstractSonarLintLightTests() {

    @Test
    fun a_long_background_read_gives_way_to_a_write_on_the_ui_thread() {
        val started = CountDownLatch(1)
        val reader = CompletableFuture.supplyAsync {
            ReadActionUtils.computeReadActionSafely(project) {
                started.countDown()
                val end = System.nanoTime() + TimeUnit.SECONDS.toNanos(2)
                while (System.nanoTime() < end) {
                    ProgressManager.checkCanceled()
                    Thread.sleep(10)
                }
                "done"
            }
        }
        assertThat(started.await(10, TimeUnit.SECONDS)).isTrue()

        val before = System.nanoTime()
        ApplicationManager.getApplication().runWriteAction {}
        val writeWaitedMillis = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - before)

        assertThat(writeWaitedMillis).isLessThan(1000)
        assertThat(reader.get(15, TimeUnit.SECONDS)).isEqualTo("done")
    }

    @Test
    fun computeReadActionSafely_returns_value_from_background_thread() {
        val result = CompletableFuture.supplyAsync {
            ReadActionUtils.computeReadActionSafely(project) { "computed" }
        }.get(10, TimeUnit.SECONDS)

        assertThat(result).isEqualTo("computed")
    }

    @Test
    fun computeReadActionSafely_returns_null_when_project_expires_during_background_read() {
        val expiringProject = mock(Project::class.java)
        val disposeChecks = AtomicInteger(0)
        `when`(expiringProject.isDisposed).thenAnswer { disposeChecks.incrementAndGet() > 1 }

        val result = CompletableFuture.supplyAsync {
            ReadActionUtils.computeReadActionSafely(expiringProject) { "ignored" }
        }.get(10, TimeUnit.SECONDS)

        assertThat(result).isNull()
    }

    @Test
    fun runReadActionSafely_does_not_throw_when_project_expires_during_background_read() {
        val expiringProject = mock(Project::class.java)
        val disposeChecks = AtomicInteger(0)
        `when`(expiringProject.isDisposed).thenAnswer { disposeChecks.incrementAndGet() > 1 }
        val executed = AtomicBoolean(false)

        CompletableFuture.runAsync {
            ReadActionUtils.runReadActionSafely(expiringProject) { executed.set(true) }
        }.get(10, TimeUnit.SECONDS)

        assertThat(executed).isFalse()
    }

    @Test
    fun computeReadActionSafely_returns_null_when_virtual_file_expires_during_background_read() {
        val expiringFile = mock(VirtualFile::class.java)
        val validityChecks = AtomicInteger(0)
        `when`(expiringFile.isValid).thenAnswer { validityChecks.incrementAndGet() > 1 }

        val result = CompletableFuture.supplyAsync {
            ReadActionUtils.computeReadActionSafely(expiringFile, project) { "ignored" }
        }.get(10, TimeUnit.SECONDS)

        assertThat(result).isNull()
    }

    @Test
    fun computeReadActionSafely_returns_null_when_project_is_disposed() {
        val disposedProject = mock(Project::class.java)
        `when`(disposedProject.isDisposed).thenReturn(true)

        assertThat(ReadActionUtils.computeReadActionSafely(disposedProject) { "ignored" }).isNull()
    }

    @Test
    fun runReadActionSafely_executes_from_background_thread() {
        val executed = AtomicBoolean(false)

        CompletableFuture.runAsync {
            ReadActionUtils.runReadActionSafely(project) { executed.set(true) }
        }.get(10, TimeUnit.SECONDS)

        assertThat(executed).isTrue()
    }

    @Test
    fun computeReadActionSafely_skips_invalid_virtual_file() {
        val file = mock(VirtualFile::class.java)
        `when`(file.isValid).thenReturn(false)

        assertThat(ReadActionUtils.computeReadActionSafely(file, project) { "ignored" }).isNull()
    }

    @Test
    fun computeReadActionSafely_returns_value_on_edt() {
        runOnUiThreadAndWait(project, ModalityState.defaultModalityState()) {
            assertThat(ReadActionUtils.computeReadActionSafely(project) { "computed-on-edt" })
                .isEqualTo("computed-on-edt")
        }
    }

    @Test
    fun runReadActionSafely_executes_on_edt() {
        val executed = AtomicBoolean(false)

        runOnUiThreadAndWait(project, ModalityState.defaultModalityState()) {
            ReadActionUtils.runReadActionSafely(project) { executed.set(true) }
        }

        assertThat(executed).isTrue()
    }
}
