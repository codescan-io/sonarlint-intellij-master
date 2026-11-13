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
package org.sonarlint.intellij.codescan

import java.util.concurrent.CompletableFuture
import org.mockito.Mockito.mock
import org.mockito.Mockito.`when`
import org.mockito.kotlin.any
import org.sonarlint.intellij.core.BackendService
import org.sonarsource.sonarlint.core.rpc.client.Sloop
import org.sonarsource.sonarlint.core.rpc.client.SloopLauncher
import org.sonarsource.sonarlint.core.rpc.protocol.SonarLintRpcServer
import org.sonarsource.sonarlint.core.rpc.protocol.backend.binding.BindingRpcService
import org.sonarsource.sonarlint.core.rpc.protocol.backend.branch.SonarProjectBranchRpcService
import org.sonarsource.sonarlint.core.rpc.protocol.backend.config.ConfigurationRpcService
import org.sonarsource.sonarlint.core.rpc.protocol.backend.connection.ConnectionRpcService
import org.sonarsource.sonarlint.core.rpc.protocol.backend.hotspot.HotspotRpcService
import org.sonarsource.sonarlint.core.rpc.protocol.backend.issue.IssueRpcService
import org.sonarsource.sonarlint.core.rpc.protocol.backend.rules.RulesRpcService
import org.sonarsource.sonarlint.core.rpc.protocol.backend.tracking.ListAllResponse
import org.sonarsource.sonarlint.core.rpc.protocol.backend.tracking.TaintVulnerabilityTrackingRpcService

/*
 * A backend that never starts a process, for CodeScan tests that read what the plugin sends to the backend or that do not need it at all.
 * The real backend is a separate process: a heavy test that starts it sees its output reader threads as leaked.
 */

/** A BackendService whose backend is [rpcServer]. */
internal fun fakeBackendService(rpcServer: SonarLintRpcServer = mockRpcServer()) = BackendService(launcherFor(rpcServer))

internal fun mockRpcServer(): SonarLintRpcServer {
    val rpcServer = mock(SonarLintRpcServer::class.java)
    `when`(rpcServer.initialize(any())).thenReturn(CompletableFuture.completedFuture(null))
    `when`(rpcServer.connectionService).thenReturn(mock(ConnectionRpcService::class.java))
    `when`(rpcServer.configurationService).thenReturn(mock(ConfigurationRpcService::class.java))
    `when`(rpcServer.rulesService).thenReturn(mock(RulesRpcService::class.java))
    `when`(rpcServer.issueService).thenReturn(mock(IssueRpcService::class.java))
    `when`(rpcServer.bindingService).thenReturn(mock(BindingRpcService::class.java))
    `when`(rpcServer.hotspotService).thenReturn(mock(HotspotRpcService::class.java))
    `when`(rpcServer.sonarProjectBranchService).thenReturn(mock(SonarProjectBranchRpcService::class.java))
    val taintService = mock(TaintVulnerabilityTrackingRpcService::class.java)
    `when`(taintService.listAll(any())).thenReturn(CompletableFuture.completedFuture(ListAllResponse(emptyList())))
    `when`(rpcServer.taintVulnerabilityTrackingService).thenReturn(taintService)
    return rpcServer
}

internal fun launcherFor(rpcServer: SonarLintRpcServer): SloopLauncher {
    val sloop = mock(Sloop::class.java)
    `when`(sloop.rpcServer).thenReturn(rpcServer)
    // the mocked backend never exits
    `when`(sloop.onExit()).thenReturn(CompletableFuture())
    val launcher = mock(SloopLauncher::class.java)
    `when`(launcher.start(any(), any(), any())).thenReturn(sloop)
    return launcher
}
