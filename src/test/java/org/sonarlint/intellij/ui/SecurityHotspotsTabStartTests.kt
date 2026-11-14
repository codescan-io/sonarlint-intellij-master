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
package org.sonarlint.intellij.ui

import com.intellij.execution.impl.ConsoleViewImpl
import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.util.Disposer
import com.intellij.openapi.wm.ToolWindowManager
import com.intellij.testFramework.PlatformTestUtil
import com.intellij.testFramework.replaceService
import com.intellij.toolWindow.ToolWindowHeadlessManagerImpl
import com.intellij.ui.components.JBPanelWithEmptyText
import com.intellij.util.ui.UIUtil
import java.util.concurrent.CompletableFuture
import java.util.concurrent.atomic.AtomicBoolean
import org.assertj.core.api.Assertions.assertThat
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.mockito.Mockito.mock
import org.mockito.Mockito.mockingDetails
import org.mockito.Mockito.`when`
import org.mockito.kotlin.any
import org.sonarlint.intellij.AbstractSonarLintLightTests
import org.sonarlint.intellij.actions.RestartBackendAction
import org.sonarlint.intellij.actions.SonarLintToolWindow
import org.sonarlint.intellij.codescan.mockRpcServer
import org.sonarlint.intellij.common.util.SonarLintUtils.getService
import org.sonarlint.intellij.core.BackendService
import org.sonarsource.sonarlint.core.rpc.client.Sloop
import org.sonarsource.sonarlint.core.rpc.client.SloopLauncher
import org.sonarsource.sonarlint.core.rpc.protocol.backend.hotspot.CheckLocalDetectionSupportedResponse
import org.sonarsource.sonarlint.core.rpc.protocol.backend.hotspot.HotspotRpcService

class SecurityHotspotsTabStartTests : AbstractSonarLintLightTests() {

    @BeforeEach
    fun useFreshToolWindowService() {
        // SonarLintToolWindow keeps the first hotspot tab it finds, and the test project is shared by all tests
        project.replaceService(SonarLintToolWindow::class.java, SonarLintToolWindow(project), testRootDisposable)
    }

    @AfterEach
    fun removeToolWindow() {
        // dispose the tabs too, and the log console that nothing else disposes while the shared test project stays open
        val contentManager = ToolWindowManager.getInstance(project).getToolWindow(SonarLintToolWindowFactory.TOOL_WINDOW_ID)?.contentManager
        contentManager?.contents?.forEach { content -> UIUtil.findComponentsOfType(content.component, ConsoleViewImpl::class.java).forEach(Disposer::dispose) }
        contentManager?.removeAllContents(true)
        ToolWindowManager.getInstance(project).unregisterToolWindow(SonarLintToolWindowFactory.TOOL_WINDOW_ID)
    }

    // CodeScan: the tool window is built the first time the user opens it, after the project-open refresh has run.
    // The new Security Hotspots tab must then get its real state instead of keeping the service error.
    @Test
    fun security_hotspots_tab_built_after_project_open_shows_the_real_state_not_the_service_error() {
        useRunningBackendThatAnswers(CheckLocalDetectionSupportedResponse(false, "Bind the project to see Security Hotspots"))
        val toolWindow = (ToolWindowManager.getInstance(project) as ToolWindowHeadlessManagerImpl)
            .doRegisterToolWindow(SonarLintToolWindowFactory.TOOL_WINDOW_ID)

        SonarLintToolWindowFactory().createToolWindowContent(project, toolWindow)

        val hotspotsTab = { toolWindow.contentManager.findContent(SonarLintToolWindowFactory.SECURITY_HOTSPOTS_TAB_TITLE)?.component as SecurityHotspotsPanel? }
        PlatformTestUtil.waitWithEventsDispatching("the Security Hotspots tab was never built", { hotspotsTab() != null }, 10)
        val cards = UIUtil.findComponentsOfType(hotspotsTab()!!, JBPanelWithEmptyText::class.java)
        val errorCard = cards.single { it.emptyText.text == RestartBackendAction.SONARLINT_ERROR_MSG }
        PlatformTestUtil.waitWithEventsDispatching(
            "the Security Hotspots tab still shows \"${RestartBackendAction.SONARLINT_ERROR_MSG}\"", { !errorCard.isVisible }, 10)

        assertThat(cards.filter { it.parent == errorCard.parent && it.isVisible }.map { it.emptyText.text })
            .containsExactly("Bind the project to see Security Hotspots")
    }

    // CodeScan: after "Restart CodeScan Service" with no file analysed yet, the tab must leave the service error too.
    @Test
    fun security_hotspots_tab_shows_the_real_state_after_a_service_restart_with_no_file_analysed() {
        val notSupported = CheckLocalDetectionSupportedResponse(false, "Bind the project to see Security Hotspots")
        val firstServiceAlive = AtomicBoolean(true)
        val firstServiceExit = CompletableFuture<Int>()
        val firstService = serviceThatAnswers(notSupported, firstServiceAlive, firstServiceExit)
        val restartedService = serviceThatAnswers(notSupported, AtomicBoolean(true), CompletableFuture())
        val launcher = mock(SloopLauncher::class.java)
        `when`(launcher.start(any(), any(), any())).thenReturn(firstService, restartedService)
        ApplicationManager.getApplication().replaceService(BackendService::class.java, BackendService(launcher), testRootDisposable)
        val toolWindow = (ToolWindowManager.getInstance(project) as ToolWindowHeadlessManagerImpl)
            .doRegisterToolWindow(SonarLintToolWindowFactory.TOOL_WINDOW_ID)
        SonarLintToolWindowFactory().createToolWindowContent(project, toolWindow)
        val hotspotsTab = { toolWindow.contentManager.findContent(SonarLintToolWindowFactory.SECURITY_HOTSPOTS_TAB_TITLE)?.component as SecurityHotspotsPanel? }
        PlatformTestUtil.waitWithEventsDispatching("the Security Hotspots tab was never built", { hotspotsTab() != null }, 10)
        val cards = UIUtil.findComponentsOfType(hotspotsTab()!!, JBPanelWithEmptyText::class.java)
        val errorCard = cards.single { it.emptyText.text == RestartBackendAction.SONARLINT_ERROR_MSG }
        PlatformTestUtil.waitWithEventsDispatching("the Security Hotspots tab never left the service error at start", { !errorCard.isVisible }, 10)

        firstServiceAlive.set(false)
        firstServiceExit.complete(1)
        PlatformTestUtil.waitWithEventsDispatching("the Security Hotspots tab never showed the service error after the service stopped", { errorCard.isVisible }, 10)

        getService(BackendService::class.java).restartBackendService()
        PlatformTestUtil.waitWithEventsDispatching("the restarted service was never told about the project", {
            mockingDetails(restartedService.rpcServer.configurationService).invocations.any { it.method.name == "didAddConfigurationScopes" }
        }, 10)
        PlatformTestUtil.waitWithEventsDispatching(
            "after the restart the Security Hotspots tab still shows \"${RestartBackendAction.SONARLINT_ERROR_MSG}\"", { !errorCard.isVisible }, 10)

        assertThat(cards.filter { it.parent == errorCard.parent && it.isVisible }.map { it.emptyText.text })
            .containsExactly("Bind the project to see Security Hotspots")
    }

    private fun serviceThatAnswers(hotspotSupport: CheckLocalDetectionSupportedResponse, alive: AtomicBoolean, exit: CompletableFuture<Int>): Sloop {
        val rpcServer = mockRpcServer()
        val hotspotService = mock(HotspotRpcService::class.java)
        `when`(hotspotService.checkLocalDetectionSupported(any())).thenReturn(CompletableFuture.completedFuture(hotspotSupport))
        `when`(rpcServer.hotspotService).thenReturn(hotspotService)
        val sloop = mock(Sloop::class.java)
        `when`(sloop.rpcServer).thenReturn(rpcServer)
        `when`(sloop.isAlive).thenAnswer { alive.get() }
        `when`(sloop.onExit()).thenReturn(exit)
        return sloop
    }

    private fun useRunningBackendThatAnswers(hotspotSupport: CheckLocalDetectionSupportedResponse) {
        val rpcServer = mockRpcServer()
        val hotspotService = mock(HotspotRpcService::class.java)
        `when`(hotspotService.checkLocalDetectionSupported(any())).thenReturn(CompletableFuture.completedFuture(hotspotSupport))
        `when`(rpcServer.hotspotService).thenReturn(hotspotService)
        val sloop = mock(Sloop::class.java)
        `when`(sloop.rpcServer).thenReturn(rpcServer)
        `when`(sloop.isAlive).thenReturn(true)
        `when`(sloop.onExit()).thenReturn(CompletableFuture())
        val launcher = mock(SloopLauncher::class.java)
        `when`(launcher.start(any(), any(), any())).thenReturn(sloop)
        ApplicationManager.getApplication().replaceService(BackendService::class.java, BackendService(launcher), testRootDisposable)
    }

}
