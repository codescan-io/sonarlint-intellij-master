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
package org.sonarlint.intellij.config.global.wizard;

import java.util.concurrent.CompletionException;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class ConnectionFailureMessagesTests {
  private static final String MSG = "Access to organization 'acme' is blocked by its IP allowlist. Your IP address is 203.0.113.9.";
  private static final String ADVICE = "Ask an administrator of the organization to add your network to the IP allowlist.";
  private static final String BODY = "{\"errors\":[{\"msg\":\"" + MSG + "\"}]}";

  @Test
  void connection_check_shows_the_ip_allowlist_message_instead_of_the_raw_body() {
    assertThat(AuthStep.connectionCheckFailure("HTTP Connection failed (403): " + BODY))
      .isEqualTo("Failed to connect to the server. " + MSG + " " + ADVICE);
  }

  @Test
  void connection_check_keeps_the_existing_text_for_other_failures() {
    assertThat(AuthStep.connectionCheckFailure("Authentication failed"))
      .isEqualTo("Failed to connect to the server. Please check the configuration. Cause: Authentication failed");
  }

  @Test
  void wizard_request_shows_the_ip_allowlist_message() {
    var e = new CompletionException(new IllegalStateException(MSG));
    assertThat(AuthStep.requestFailure("Failed to query organizations. Please check the configuration and try again.", "Failed to query organizations.", e))
      .isEqualTo("Failed to query organizations. " + MSG + " " + ADVICE);
  }

  @Test
  void wizard_request_keeps_the_existing_text_for_other_failures() {
    var generic = "Failed to contact the server. Please check the configuration and try again.";
    assertThat(AuthStep.requestFailure(generic, "Failed to contact the server.", new IllegalStateException("boom"))).isEqualTo(generic + " Error: boom");
    assertThat(AuthStep.requestFailure(generic, "Failed to contact the server.", new IllegalStateException((String) null))).isEqualTo(generic);
  }

  @Test
  void organization_fetch_shows_the_ip_allowlist_message() {
    assertThat(OrganizationStep.fetchOrganizationFailure(new IllegalStateException(MSG)))
      .isEqualTo("Failed to fetch organization from server. " + MSG + " " + ADVICE);
    assertThat(OrganizationStep.fetchOrganizationFailure(new IllegalStateException("boom")))
      .isEqualTo("Failed to fetch organization from server: boom");
  }
}
