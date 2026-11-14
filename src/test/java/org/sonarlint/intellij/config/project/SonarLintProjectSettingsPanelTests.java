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
package org.sonarlint.intellij.config.project;

import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class SonarLintProjectSettingsPanelTests {
  private static final String MSG = "Access to organization 'acme' is blocked by its IP allowlist. Your IP address is 203.0.113.9.";
  private static final String ADVICE = "Ask an administrator of the organization to add your network to the IP allowlist.";

  @Test
  void connection_check_shows_the_ip_allowlist_message_instead_of_the_raw_body() {
    assertThat(SonarLintProjectSettingsPanel.connectionCheckFailure("HTTP Connection failed (403): {\"errors\":[{\"msg\":\"" + MSG + "\"}]}"))
      .isEqualTo("Failed to connect to the server. " + MSG + " " + ADVICE);
    assertThat(SonarLintProjectSettingsPanel.connectionCheckFailure(new IllegalStateException(MSG)))
      .isEqualTo("Failed to connect to the server. " + MSG + " " + ADVICE);
  }

  @Test
  void connection_check_keeps_the_existing_text_for_other_failures() {
    assertThat(SonarLintProjectSettingsPanel.connectionCheckFailure("Authentication failed")).isEqualTo("Authentication failed");
    assertThat(SonarLintProjectSettingsPanel.connectionCheckFailure(new IllegalStateException("boom")))
      .isEqualTo("Failed to connect to the server. Please check the configuration. Error: boom");
  }
}
