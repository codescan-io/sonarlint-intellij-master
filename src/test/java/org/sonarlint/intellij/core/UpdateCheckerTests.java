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
package org.sonarlint.intellij.core;

import com.intellij.openapi.progress.DumbProgressIndicator;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.sonarlint.intellij.AbstractSonarLintLightTests;
import org.sonarlint.intellij.config.global.ServerConnection;
import org.sonarlint.intellij.exception.InvalidBindingException;
import org.sonarsource.sonarlint.core.client.api.connected.ConnectedSonarLintEngine;

import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class UpdateCheckerTests extends AbstractSonarLintLightTests {
  private ConnectedModeStorageSynchronizer connectedModeStorageSynchronizer;
  private ServerConnection server;
  private ProjectBindingManager bindingManager = mock(ProjectBindingManager.class);
  private ConnectedSonarLintEngine engine = mock(ConnectedSonarLintEngine.class);

  @BeforeEach
  void before() throws InvalidBindingException {
    replaceProjectService(ProjectBindingManager.class, bindingManager);

    getProjectSettings().setProjectKey("key");
    getProjectSettings().setConnectionName("serverId");
    server = createServer();
    when(bindingManager.getServerConnection()).thenReturn(server);
    when(bindingManager.getConnectedEngine()).thenReturn(engine);

    connectedModeStorageSynchronizer = new ConnectedModeStorageSynchronizer(getProject());
  }

  @Test
  void do_nothing_if_no_engine() throws InvalidBindingException {
    when(bindingManager.getConnectedEngine()).thenThrow(new IllegalStateException());
    connectedModeStorageSynchronizer.sync(DumbProgressIndicator.INSTANCE);

    verifyNoInteractions(engine);
  }

  private ServerConnection createServer() {
    return ServerConnection.newBuilder()
      .setHostUrl("http://localhost:9000")
      .setName("server1")
      .build();
  }
}
