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
package org.sonarlint.intellij.errorsubmitter;

import com.github.tomakehurst.wiremock.WireMockServer;
import com.intellij.openapi.diagnostic.IdeaLoggingEvent;
import com.intellij.openapi.diagnostic.SubmittedReportInfo.SubmissionStatus;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.Base64;
import java.util.List;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.sonarlint.intellij.config.global.ServerConnection;

import static com.github.tomakehurst.wiremock.client.WireMock.aResponse;
import static com.github.tomakehurst.wiremock.client.WireMock.absent;
import static com.github.tomakehurst.wiremock.client.WireMock.equalTo;
import static com.github.tomakehurst.wiremock.client.WireMock.ok;
import static com.github.tomakehurst.wiremock.client.WireMock.post;
import static com.github.tomakehurst.wiremock.client.WireMock.postRequestedFor;
import static com.github.tomakehurst.wiremock.client.WireMock.urlEqualTo;
import static com.github.tomakehurst.wiremock.core.WireMockConfiguration.wireMockConfig;
import static org.assertj.core.api.Assertions.assertThat;
import static org.sonarlint.intellij.errorsubmitter.ReportToCodeScan.getAbbreviations;

class ReportToCodeScanTests {

  private static final String ERRORS_PATH = "/_codescan/errors/intellij";
  private static final Duration SHORT_TIMEOUT = Duration.ofMillis(500);

  private WireMockServer server;

  @BeforeEach
  void startServer() {
    server = new WireMockServer(wireMockConfig().dynamicPort());
    server.start();
  }

  @AfterEach
  void stopServer() {
    server.stop();
  }

  @Test
  void action_text_names_codescan_support() {
    assertThat(new ReportToCodeScan().getReportActionText()).isEqualTo("Report to CodeScan Support");
  }

  @Test
  void body_lists_the_environment() {
    var body = ReportToCodeScan.buildBody(new IdeaLoggingEvent[0], null, "IntelliJ IDEA 2024.1", "7.3.0");

    assertThat(body)
      .contains("<li>Java: " + System.getProperty("java.vendor") + " " + System.getProperty("java.version") + "</li>")
      .contains("<li>OS: " + System.getProperty("os.name") + " " + System.getProperty("os.arch") + "</li>")
      .contains("<li>IDE: IntelliJ IDEA 2024.1</li>")
      .contains("<li>CodeScan: 7.3.0</li>")
      .doesNotContain("Additional information");
  }

  @Test
  void body_escapes_the_users_text() {
    var body = ReportToCodeScan.buildBody(new IdeaLoggingEvent[0], "<script>alert(1)</script> & more\nsecond line", "IDE", "1.0");

    assertThat(body)
      .contains("&lt;script&gt;alert(1)&lt;/script&gt; &amp; more<br/>second line")
      .doesNotContain("<script>");
  }

  @Test
  void body_escapes_and_abbreviates_each_error() {
    var event = new IdeaLoggingEvent("failed <b>here</b>", new IllegalStateException("bad <tag>"));

    var body = ReportToCodeScan.buildBody(new IdeaLoggingEvent[] {event}, null, "IDE", "1.0");

    assertThat(body)
      .contains("failed &lt;b&gt;here&lt;/b&gt;")
      .contains("java.lang.IllegalStateException: bad &lt;tag&gt;")
      .contains("o.sl.ij.errorsubmitter.ReportToCodeScanTests")
      .doesNotContain("<b>", "<tag>", "org.sonarlint.intellij.errorsubmitter");
  }

  @Test
  void no_connection_sends_to_codescan_cloud_without_login() {
    var target = ReportToCodeScan.chooseTarget(List.of(), connection -> true, "https://app.codescan.io");

    assertThat(target.url()).isEqualTo("https://app.codescan.io" + ERRORS_PATH);
    assertThat(target.token()).isNull();
  }

  @Test
  void codescan_connection_on_its_own_address_receives_the_report_with_its_token() {
    var other = connection("other", "https://sonar.example.com", "other-token");
    var selfHosted = connection("self-hosted", "https://codescan.mycorp.example/", "my-token");

    var target = ReportToCodeScan.chooseTarget(List.of(other, selfHosted), c -> c == selfHosted, "https://app.codescan.io");

    assertThat(target.url()).isEqualTo("https://codescan.mycorp.example" + ERRORS_PATH);
    assertThat(target.token()).isEqualTo("my-token");
    assertThat(target.toString()).doesNotContain("my-token");
  }

  @Test
  void codescan_connection_without_token_sends_without_login() {
    var noToken = connection("no-token", "https://codescan.mycorp.example", null);

    var target = ReportToCodeScan.chooseTarget(List.of(noToken), c -> true, "https://app.codescan.io");

    assertThat(target.url()).isEqualTo("https://codescan.mycorp.example" + ERRORS_PATH);
    assertThat(target.token()).isNull();
  }

  @Test
  void accepted_report_is_a_new_issue() {
    server.stubFor(post(ERRORS_PATH).willReturn(ok("OK")));

    var result = ReportToCodeScan.send(new ReportToCodeScan.Target(server.baseUrl() + ERRORS_PATH, null), "<p>body</p>", SHORT_TIMEOUT);

    assertThat(result.reportInfo().getStatus()).isEqualTo(SubmissionStatus.NEW_ISSUE);
    assertThat(result.problem()).isNull();
    server.verify(1, postRequestedFor(urlEqualTo(ERRORS_PATH))
      .withHeader("Content-Type", equalTo("text/html; charset=UTF-8"))
      .withHeader("Authorization", absent())
      .withRequestBody(equalTo("<p>body</p>")));
  }

  @Test
  void token_is_sent_as_the_login() {
    server.stubFor(post(ERRORS_PATH).willReturn(ok("OK")));

    ReportToCodeScan.send(new ReportToCodeScan.Target(server.baseUrl() + ERRORS_PATH, "my-token"), "<p>body</p>", SHORT_TIMEOUT);

    var basic = "Basic " + Base64.getEncoder().encodeToString("my-token:".getBytes(StandardCharsets.UTF_8));
    server.verify(1, postRequestedFor(urlEqualTo(ERRORS_PATH)).withHeader("Authorization", equalTo(basic)));
  }

  @Test
  void refused_report_fails_once_without_retry() {
    server.stubFor(post(ERRORS_PATH).willReturn(aResponse().withStatus(401)));

    var result = ReportToCodeScan.send(new ReportToCodeScan.Target(server.baseUrl() + ERRORS_PATH, null), "body", SHORT_TIMEOUT);

    assertThat(result.reportInfo().getStatus()).isEqualTo(SubmissionStatus.FAILED);
    assertThat(result.problem()).contains("401");
    server.verify(1, postRequestedFor(urlEqualTo(ERRORS_PATH)));
  }

  @Test
  void server_error_fails() {
    server.stubFor(post(ERRORS_PATH).willReturn(aResponse().withStatus(500)));

    var result = ReportToCodeScan.send(new ReportToCodeScan.Target(server.baseUrl() + ERRORS_PATH, null), "body", SHORT_TIMEOUT);

    assertThat(result.reportInfo().getStatus()).isEqualTo(SubmissionStatus.FAILED);
    assertThat(result.problem()).contains("500");
  }

  @Test
  void slow_server_times_out_and_fails() {
    server.stubFor(post(ERRORS_PATH).willReturn(ok("OK").withFixedDelay(5_000)));

    var start = System.nanoTime();
    var result = ReportToCodeScan.send(new ReportToCodeScan.Target(server.baseUrl() + ERRORS_PATH, null), "body", SHORT_TIMEOUT);

    assertThat(Duration.ofNanos(System.nanoTime() - start)).isLessThan(Duration.ofSeconds(3));
    assertThat(result.reportInfo().getStatus()).isEqualTo(SubmissionStatus.FAILED);
    assertThat(result.problem()).contains("did not answer in time");
  }

  @Test
  void unreachable_server_fails() {
    var url = server.baseUrl() + ERRORS_PATH;
    server.stop();

    var result = ReportToCodeScan.send(new ReportToCodeScan.Target(url, null), "body", SHORT_TIMEOUT);

    assertThat(result.reportInfo().getStatus()).isEqualTo(SubmissionStatus.FAILED);
    assertThat(result.problem()).contains("could not be reached");
  }

  private static ServerConnection connection(String name, String url, String token) {
    return ServerConnection.newBuilder().setName(name).setHostUrl(url).setToken(token).build();
  }

  @Test
    void testAbbreviateStackTrace() {
      var throwableText = """
        java.lang.Throwable: class com.intellij.openapi.roots.ProjectRootManager it is a service, use getService instead of getComponent
        \tat com.intellij.openapi.diagnostic.Logger.error(Logger.java:182)
        \tat com.intellij.serviceContainer.ComponentManagerImpl.getComponent(ComponentManagerImpl.kt:549)
        \tat org.sonarsource.sonarlint.core.container.module.SonarLintModuleFileSystem.files(SonarLintModuleFileSystem.java:39)
        \tat org.sonar.plugins.python.indexer.SonarLintPythonIndexer.getInputFiles(SonarLintPythonIndexer.java:82)
        \tat org.sonarlint.intellij.util.SonarLintUtils.get(SonarLintUtils.java:83)
        \tat org.sonarlint.intellij.actions.AbstractSonarAction.update(AbstractSonarAction.java:54)
        \tat org.jetbrains.plugins.textmate.TextMateServiceImpl.readBundle(TextMateServiceImpl.java:237)
        \tat com.intellij.openapi.actionSystem.ex.ActionUtil.lambda$performDumbAwareUpdate$0(ActionUtil.java:130)
        \tat com.intellij.openapi.actionSystem.impl.ActionUpdater.lambda$callAction$9(ActionUpdater.java:182)
        \tat com.intellij.openapi.progress.ProgressManager.lambda$runProcess$0(ProgressManager.java:57)
        \tat com.intellij.openapi.progress.impl.CoreProgressManager.lambda$runProcess$2(CoreProgressManager.java:183)
        \tat com.intellij.openapi.progress.ProgressManager.runProcess(ProgressManager.java:57)
        \tat com.intellij.openapi.actionSystem.impl.ActionUpdater.lambda$callAction$10(ActionUpdater.java:180)
        \tat com.intellij.openapi.actionSystem.impl.ActionUpdateEdtExecutor.lambda$computeOnEdt$0(ActionUpdateEdtExecutor.java:45)
        \tat com.intellij.openapi.application.TransactionGuardImpl$2.run(TransactionGuardImpl.java:199)
        \tat com.intellij.openapi.application.impl.ApplicationImpl.runIntendedWriteActionOnCurrentThread(ApplicationImpl.java:794)
        \tat com.intellij.openapi.application.impl.FlushQueue$FlushNow.run(FlushQueue.java:189)
        \tat java.desktop/java.awt.EventQueue.dispatchEventImpl(EventQueue.java:776)
        \tat java.desktop/java.awt.EventQueue$4.run(EventQueue.java:721)
        \tat java.base/java.security.ProtectionDomain$JavaSecurityAccessImpl.doIntersectionPrivilege(ProtectionDomain.java:85)
        \tat java.desktop/java.awt.EventQueue.dispatchEvent(EventQueue.java:746)""";

      var result = ReportToCodeScan.abbreviate(getAbbreviations(), throwableText);

        assertThat(throwableText).hasSize(2132);
        assertThat(result).hasSize(1865).isEqualTo("""
          java.lang.Throwable: class c.ij.oa.roots.ProjectRootManager it is a service, use getService instead of getComponent
          \tat c.ij.oa.dg.Logger.error(Logger.java:182)
          \tat c.ij.serviceContainer.ComponentManagerImpl.getComponent(ComponentManagerImpl.kt:549)
          \tat o.ss.sl.core.container.module.SonarLintModuleFileSystem.files(SonarLintModuleFileSystem.java:39)
          \tat o.s.pl.python.indexer.SonarLintPythonIndexer.getInputFiles(SonarLintPythonIndexer.java:82)
          \tat o.sl.ij.util.SonarLintUtils.get(SonarLintUtils.java:83)
          \tat o.sl.ij.actions.AbstractSonarAction.update(AbstractSonarAction.java:54)
          \tat o.jb.plugins.textmate.TextMateServiceImpl.readBundle(TextMateServiceImpl.java:237)
          \tat c.ij.oa.actionSystem.ex.ActionUtil.lambda$performDumbAwareUpdate$0(ActionUtil.java:130)
          \tat c.ij.oa.actionSystem.impl.ActionUpdater.lambda$callAction$9(ActionUpdater.java:182)
          \tat c.ij.oa.progress.ProgressManager.lambda$runProcess$0(ProgressManager.java:57)
          \tat c.ij.oa.progress.impl.CoreProgressManager.lambda$runProcess$2(CoreProgressManager.java:183)
          \tat c.ij.oa.progress.ProgressManager.runProcess(ProgressManager.java:57)
          \tat c.ij.oa.actionSystem.impl.ActionUpdater.lambda$callAction$10(ActionUpdater.java:180)
          \tat c.ij.oa.actionSystem.impl.ActionUpdateEdtExecutor.lambda$computeOnEdt$0(ActionUpdateEdtExecutor.java:45)
          \tat c.ij.oa.ap.TransactionGuardImpl$2.run(TransactionGuardImpl.java:199)
          \tat c.ij.oa.ap.impl.ApplicationImpl.runIntendedWriteActionOnCurrentThread(ApplicationImpl.java:794)
          \tat c.ij.oa.ap.impl.FlushQueue$FlushNow.run(FlushQueue.java:189)
          \tat java.desktop/java.awt.EventQueue.dispatchEventImpl(EventQueue.java:776)
          \tat java.desktop/java.awt.EventQueue$4.run(EventQueue.java:721)
          \tat java.base/java.security.ProtectionDomain$JavaSecurityAccessImpl.doIntersectionPrivilege(ProtectionDomain.java:85)
          \tat java.desktop/java.awt.EventQueue.dispatchEvent(EventQueue.java:746)""");
    }
}
