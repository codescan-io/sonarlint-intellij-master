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

import java.util.Collections;
import java.util.List;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.Mockito;
import org.sonarlint.intellij.AbstractSonarLintLightTests;
import org.sonarlint.intellij.config.global.ServerConnection;
import org.sonarlint.intellij.exception.InvalidBindingException;
import org.sonarlint.intellij.notifications.SonarLintProjectNotifications;
import org.sonarsource.sonarlint.core.client.api.connected.ConnectedSonarLintEngine;
import org.sonarsource.sonarlint.core.client.api.standalone.StandaloneSonarLintEngine;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.catchThrowable;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class DefaultEngineManagerTests extends AbstractSonarLintLightTests {

  private DefaultEngineManager manager;
  private SonarLintEngineFactory engineFactory;
  private SonarLintProjectNotifications notifications;
  private ConnectedSonarLintEngine connectedEngine;
  private StandaloneSonarLintEngine standaloneEngine;

  @BeforeEach
  void before() {
    engineFactory = mock(SonarLintEngineFactory.class);
    notifications = mock(SonarLintProjectNotifications.class);
    connectedEngine = mock(ConnectedSonarLintEngine.class);
    standaloneEngine = mock(StandaloneSonarLintEngine.class);

    when(engineFactory.createEngine(anyString(), eq(false))).thenReturn(connectedEngine);
    when(engineFactory.createEngine()).thenReturn(standaloneEngine);

    manager = new DefaultEngineManager(engineFactory);
    getGlobalSettings().setServerConnections(Collections.emptyList());
  }

  @Test
  void should_get_standalone() {
    assertThat(manager.getStandaloneEngine()).isEqualTo(standaloneEngine);
    assertThat(manager.getStandaloneEngine()).isEqualTo(standaloneEngine);
    verify(engineFactory, Mockito.times(1)).createEngine();
  }

  @Test
  void should_get_connected() {
    getGlobalSettings().setServerConnections(List.of(createConnection("server1")));

    assertThat(manager.getConnectedEngine("server1")).isEqualTo(connectedEngine);
    assertThat(manager.getConnectedEngine("server1")).isEqualTo(connectedEngine);
    verify(engineFactory, Mockito.times(1)).createEngine("server1", false);
  }

  @Test
  void should_fail_invalid_server() {
    var throwable = catchThrowable(() -> manager.getConnectedEngine(notifications, "server1", "project1"));

    assertThat(throwable)
      .isInstanceOf(InvalidBindingException.class)
      .hasMessage("Invalid server name: server1");
  }

  private static ServerConnection createConnection(String name) {
    return ServerConnection.newBuilder().setName(name).build();
  }

}
