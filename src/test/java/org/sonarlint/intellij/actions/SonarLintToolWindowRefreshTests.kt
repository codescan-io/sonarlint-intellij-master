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
package org.sonarlint.intellij.actions

import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.wm.ToolWindowManager
import com.intellij.testFramework.PlatformTestUtil
import com.intellij.toolWindow.ToolWindowHeadlessManagerImpl
import com.intellij.ui.content.ContentFactory
import java.util.concurrent.atomic.AtomicReference
import org.assertj.core.api.Assertions.assertThat
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Test
import org.mockito.Mockito.doAnswer
import org.mockito.Mockito.mock
import org.sonarlint.intellij.AbstractSonarLintLightTests
import org.sonarlint.intellij.ui.SonarLintToolWindowFactory
import org.sonarlint.intellij.ui.vulnerabilities.TaintVulnerabilitiesPanel

class SonarLintToolWindowRefreshTests : AbstractSonarLintLightTests() {

    @AfterEach
    fun removeToolWindow() {
        ToolWindowManager.getInstance(project).unregisterToolWindow(SonarLintToolWindowFactory.TOOL_WINDOW_ID)
    }

    @Test
    fun refreshing_views_from_a_background_thread_updates_the_taint_tab_on_the_ui_thread() {
        val toolWindow = (ToolWindowManager.getInstance(project) as ToolWindowHeadlessManagerImpl)
            .doRegisterToolWindow(SonarLintToolWindowFactory.TOOL_WINDOW_ID)
        val taintPanel = mock(TaintVulnerabilitiesPanel::class.java)
        val ranOnUiThread = AtomicReference<Boolean>()
        doAnswer {
            ranOnUiThread.set(ApplicationManager.getApplication().isDispatchThread)
            null
        }.`when`(taintPanel).applyFocusOnNewCodeSettings()
        val tabName = SonarLintToolWindow.buildTabName(0, SonarLintToolWindowFactory.TAINT_VULNERABILITIES_TAB_TITLE)
        toolWindow.contentManager.addContent(ContentFactory.getInstance().createContent(taintPanel, tabName, false))

        ApplicationManager.getApplication().executeOnPooledThread { SonarLintToolWindow(project).refreshViews() }

        PlatformTestUtil.waitWithEventsDispatching("taint tab never refreshed", { ranOnUiThread.get() != null }, 10)
        assertThat(ranOnUiThread.get()).isTrue()
    }

}
