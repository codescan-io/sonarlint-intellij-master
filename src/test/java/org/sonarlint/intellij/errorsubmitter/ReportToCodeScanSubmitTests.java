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
import com.intellij.notification.Notification;
import com.intellij.notification.Notifications;
import com.intellij.openapi.application.ApplicationManager;
import com.intellij.openapi.util.Disposer;
import com.intellij.openapi.diagnostic.IdeaLoggingEvent;
import com.intellij.openapi.diagnostic.SubmittedReportInfo;
import com.intellij.openapi.diagnostic.SubmittedReportInfo.SubmissionStatus;
import com.intellij.testFramework.PlatformTestUtil;
import java.time.Duration;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.atomic.AtomicReference;
import javax.swing.JPanel;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.sonarlint.intellij.AbstractSonarLintLightTests;

import static com.github.tomakehurst.wiremock.client.WireMock.aResponse;
import static com.github.tomakehurst.wiremock.client.WireMock.ok;
import static com.github.tomakehurst.wiremock.client.WireMock.post;
import static com.github.tomakehurst.wiremock.core.WireMockConfiguration.wireMockConfig;
import static org.assertj.core.api.Assertions.assertThat;

class ReportToCodeScanSubmitTests extends AbstractSonarLintLightTests {

  private static final String ERRORS_PATH = "/_codescan/errors/intellij";

  private WireMockServer server;
  private final List<Notification> notifications = new CopyOnWriteArrayList<>();
  private final com.intellij.openapi.Disposable listening = Disposer.newDisposable();

  @BeforeEach
  void startServer() {
    server = new WireMockServer(wireMockConfig().dynamicPort());
    server.start();
    Notifications listener = new Notifications() {
      @Override
      public void notify(@org.jetbrains.annotations.NotNull Notification notification) {
        notifications.add(notification);
      }
    };
    // without an open project the notification goes to the whole IDE, otherwise to the project
    ApplicationManager.getApplication().getMessageBus().connect(listening).subscribe(Notifications.TOPIC, listener);
    getProject().getMessageBus().connect(listening).subscribe(Notifications.TOPIC, listener);
  }

  @AfterEach
  void stopServer() {
    server.stop();
    Disposer.dispose(listening);
  }

  @Test
  void submit_returns_at_once_and_reports_success_later() throws Exception {
    server.stubFor(post(ERRORS_PATH).willReturn(ok("OK").withFixedDelay(1_000)));
    var underTest = new ReportToCodeScan(() -> new ReportToCodeScan.Target(server.baseUrl() + ERRORS_PATH, null), Duration.ofSeconds(5));
    var received = new AtomicReference<SubmittedReportInfo>();

    var start = System.nanoTime();
    var accepted = underTest.submit(events(), "what I was doing", new JPanel(), received::set);

    assertThat(accepted).isTrue();
    assertThat(Duration.ofNanos(System.nanoTime() - start)).isLessThan(Duration.ofMillis(500));
    assertThat(received.get()).isNull();
    PlatformTestUtil.waitWithEventsDispatching("the report result never arrived", () -> received.get() != null, 10);
    assertThat(received.get().getStatus()).isEqualTo(SubmissionStatus.NEW_ISSUE);
    assertThat(errorReportNotifications()).isEmpty();
  }

  @Test
  void failed_report_is_reported_and_the_user_is_told() throws Exception {
    server.stubFor(post(ERRORS_PATH).willReturn(aResponse().withStatus(403)));
    var underTest = new ReportToCodeScan(() -> new ReportToCodeScan.Target(server.baseUrl() + ERRORS_PATH, "secret-token"), Duration.ofSeconds(5));
    var received = new AtomicReference<SubmittedReportInfo>();

    underTest.submit(events(), "what I was doing", new JPanel(), received::set);

    PlatformTestUtil.waitWithEventsDispatching("the report result never arrived", () -> received.get() != null, 10);
    assertThat(received.get().getStatus()).isEqualTo(SubmissionStatus.FAILED);
    var shown = errorReportNotifications();
    assertThat(shown).hasSize(1);
    assertThat(shown.get(0).getContent()).contains("not sent", "403").doesNotContain("secret-token");
  }

  @Test
  void unexpected_problem_still_ends_as_failed() throws Exception {
    var underTest = new ReportToCodeScan(() -> {
      throw new IllegalStateException("settings are broken");
    }, Duration.ofSeconds(5));
    var received = new AtomicReference<SubmittedReportInfo>();

    underTest.submit(events(), null, new JPanel(), received::set);

    PlatformTestUtil.waitWithEventsDispatching("the report result never arrived", () -> received.get() != null, 10);
    assertThat(received.get().getStatus()).isEqualTo(SubmissionStatus.FAILED);
    assertThat(errorReportNotifications()).hasSize(1);
  }

  private static IdeaLoggingEvent[] events() {
    return new IdeaLoggingEvent[] {new IdeaLoggingEvent("boom", new IllegalStateException("boom"))};
  }

  private List<Notification> errorReportNotifications() {
    return notifications.stream().filter(n -> n.getTitle().contains("error report")).toList();
  }
}
