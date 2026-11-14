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
package org.sonarlint.intellij.util;

import com.google.gson.JsonPrimitive;
import java.util.concurrent.CompletionException;
import org.eclipse.lsp4j.jsonrpc.ResponseErrorException;
import org.eclipse.lsp4j.jsonrpc.messages.ResponseError;
import org.eclipse.lsp4j.jsonrpc.messages.ResponseErrorCode;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class IpAllowlistBlockTests {
  private static final String MSG = "Access to organization 'acme' is blocked by its IP allowlist. Your IP address is 203.0.113.9.";
  private static final String ADVICE = "Ask an administrator of the organization to add your network to the IP allowlist.";

  @Test
  void finds_the_message_deep_in_the_cause_chain() {
    var e = new RuntimeException("Failed to update", new RuntimeException("wrapper", new IllegalStateException(MSG)));
    assertThat(IpAllowlistBlock.find(e)).contains(MSG);
  }

  @Test
  void extracts_the_message_from_a_raw_json_body() {
    var e = new IllegalStateException("HTTP Connection failed (403): {\"errors\":[{\"msg\":\"" + MSG + "\"}]}");
    assertThat(IpAllowlistBlock.find(e)).contains(MSG);
  }

  @Test
  void finds_the_message_in_a_connection_check_reason() {
    assertThat(IpAllowlistBlock.find("HTTP Connection failed (403): {\"errors\":[{\"msg\":\"" + MSG + "\"}]}")).contains(MSG);
    assertThat(IpAllowlistBlock.find("HTTP Connection failed (500): Foo")).isEmpty();
    assertThat(IpAllowlistBlock.find((String) null)).isEmpty();
  }

  @Test
  void decodes_the_escaped_quotes_the_server_sends() {
    var reason = "HTTP Connection failed (403): {\"errors\":[{\"msg\":\"Access to organization \\u0027acme\\u0027 is blocked by its IP allowlist."
      + " Your IP address is 203.0.113.9.\"}]}";
    assertThat(IpAllowlistBlock.find(reason)).contains(MSG);
  }

  @Test
  void picks_the_matching_entry_when_the_json_body_has_several_errors() {
    assertThat(IpAllowlistBlock.find("{\"errors\":[{\"msg\":\"Something else\"},{\"msg\":\"" + MSG + "\"}]}")).contains(MSG);
  }

  @Test
  void finds_the_message_in_the_stack_trace_a_backend_request_error_carries() {
    // lsp4j turns an unhandled backend exception into "Internal error." and puts the stack trace in the error data
    var stackTrace = "java.util.concurrent.CompletionException: java.lang.IllegalStateException: " + MSG + "\n"
      + "\tat java.base/java.util.concurrent.CompletableFuture.encodeThrowable(CompletableFuture.java:315)\n"
      + "Caused by: java.lang.IllegalStateException: " + MSG + "\n"
      + "\tat org.sonarsource.sonarlint.core.serverapi.ServerApiHelper.handleError(ServerApiHelper.java:145)\n";
    var asJson = new ResponseErrorException(new ResponseError(ResponseErrorCode.InternalError, "Internal error.", new JsonPrimitive(stackTrace)));
    var asString = new ResponseErrorException(new ResponseError(ResponseErrorCode.InternalError, "Internal error.", stackTrace));

    assertThat(IpAllowlistBlock.find(new CompletionException(asJson))).contains(MSG);
    assertThat(IpAllowlistBlock.find(asString)).contains(MSG);
  }

  @Test
  void finds_the_message_in_a_logged_stack_trace() {
    var stackTrace = "java.lang.IllegalStateException: Failed to synchronize\n"
      + "\tat org.sonarsource.sonarlint.core.sync.SynchronizationService.sync(SynchronizationService.java:300)\n"
      + "Caused by: java.lang.IllegalStateException: " + MSG + "\n"
      + "\t... 12 more\n";
    assertThat(IpAllowlistBlock.find(stackTrace)).contains(MSG);
  }

  @Test
  void ignores_other_errors() {
    assertThat(IpAllowlistBlock.find(new IllegalStateException("Not authorized. Please check server credentials."))).isEmpty();
    assertThat(IpAllowlistBlock.find(new RuntimeException("Failed", new IllegalStateException("Error 500")))).isEmpty();
    assertThat(IpAllowlistBlock.find(new ResponseErrorException(new ResponseError(ResponseErrorCode.InternalError, "Internal error.", null)))).isEmpty();
    assertThat(IpAllowlistBlock.find(new RuntimeException((String) null))).isEmpty();
    assertThat(IpAllowlistBlock.find((Throwable) null)).isEmpty();
  }

  @Test
  void stops_on_a_cause_chain_that_loops() {
    var first = new IllegalStateException("first");
    var second = new IllegalStateException("second");
    first.initCause(second);
    second.initCause(first);
    assertThat(IpAllowlistBlock.find(first)).isEmpty();
  }

  @Test
  void explains_a_block_with_the_server_message_and_the_advice() {
    var e = new RuntimeException("Failed", new IllegalStateException(MSG));
    assertThat(IpAllowlistBlock.explain(e, "Failed to query organizations.", "unused fallback"))
      .isEqualTo("Failed to query organizations. " + MSG + " " + ADVICE);
    assertThat(IpAllowlistBlock.explain("HTTP Connection failed (403): {\"errors\":[{\"msg\":\"" + MSG + "\"}]}", "Failed to connect to the server.", "unused"))
      .isEqualTo("Failed to connect to the server. " + MSG + " " + ADVICE);
  }

  @Test
  void keeps_the_existing_text_when_there_is_no_block() {
    assertThat(IpAllowlistBlock.explain(new IllegalStateException("boom"), "Failed to query organizations.", "the old text")).isEqualTo("the old text");
    assertThat(IpAllowlistBlock.explain("Authentication failed", "Failed to connect to the server.", "the old text")).isEqualTo("the old text");
    assertThat(IpAllowlistBlock.explain((String) null, "Failed to connect to the server.", "the old text")).isEqualTo("the old text");
  }
}
