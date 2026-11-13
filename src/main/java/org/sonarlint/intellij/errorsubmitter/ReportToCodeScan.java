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

import com.intellij.notification.NotificationGroupManager;
import com.intellij.notification.NotificationType;
import com.intellij.openapi.actionSystem.CommonDataKeys;
import com.intellij.openapi.application.ApplicationInfo;
import com.intellij.openapi.application.ApplicationManager;
import com.intellij.openapi.application.ModalityState;
import com.intellij.openapi.diagnostic.ErrorReportSubmitter;
import com.intellij.openapi.diagnostic.IdeaLoggingEvent;
import com.intellij.openapi.diagnostic.Logger;
import com.intellij.openapi.diagnostic.SubmittedReportInfo;
import com.intellij.openapi.diagnostic.SubmittedReportInfo.SubmissionStatus;
import com.intellij.ide.DataManager;
import com.intellij.openapi.project.Project;
import com.intellij.util.Consumer;
import java.awt.Component;
import java.io.BufferedReader;
import java.io.IOException;
import java.io.StringReader;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.net.http.HttpTimeoutException;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.Predicate;
import java.util.function.Supplier;
import java.util.stream.Collectors;
import org.apache.commons.lang3.StringUtils;
import org.apache.commons.text.StringEscapeUtils;
import org.jetbrains.annotations.NotNull;
import org.jetbrains.annotations.Nullable;
import org.sonarlint.intellij.SonarLintPlugin;
import org.sonarlint.intellij.common.util.SonarLintUtils;
import org.sonarlint.intellij.config.global.ServerConnection;

import static org.sonarlint.intellij.config.Settings.getGlobalSettings;

/**
 * CodeScan: "Report to CodeScan Support" in the IDE error dialog. Sends the report as HTML to CodeScan's error service, which
 * emails it to support. The report goes to the first CodeScan connection's own server, logged in with its token when it has
 * one, or to CodeScan cloud when there is no CodeScan connection. The call runs off the UI thread; the dialog gets the result
 * later, and the user gets a notification when the report could not be sent.
 */
// Inspired from https://github.com/openclover/clover/blob/master/clover-idea/src/com/atlassian/clover/idea/util/BlameClover.java
public class ReportToCodeScan extends ErrorReportSubmitter {

  private static final Logger LOG = Logger.getInstance(ReportToCodeScan.class);
  static final String ERRORS_PATH = "/_codescan/errors/intellij";
  private static final Duration TIMEOUT = Duration.ofSeconds(10);
  private static final String NOTIFICATION_GROUP = "CodeScan";

  private final Supplier<Target> targets;
  private final Duration timeout;

  public ReportToCodeScan() {
    this(() -> chooseTarget(getGlobalSettings().getServerConnections(), ServerConnection::isSonarCloud, SonarLintUtils.SONARCLOUD_URL), TIMEOUT);
  }

  ReportToCodeScan(Supplier<Target> targets, Duration timeout) {
    this.targets = targets;
    this.timeout = timeout;
  }

  @Override
  public @NotNull String getReportActionText() {
    return "Report to CodeScan Support";
  }

  @Override
  public boolean submit(@NotNull IdeaLoggingEvent[] events,
    @Nullable String additionalInfo,
    @NotNull Component parentComponent,
    @NotNull Consumer<? super SubmittedReportInfo> consumer) {
    var body = buildBody(events, additionalInfo, ApplicationInfo.getInstance().getFullApplicationName(),
      SonarLintUtils.getService(SonarLintPlugin.class).getVersion());
    var project = CommonDataKeys.PROJECT.getData(DataManager.getInstance().getDataContext(parentComponent));
    var application = ApplicationManager.getApplication();
    application.executeOnPooledThread(() -> {
      var result = sendSafely(body);
      application.invokeLater(() -> {
        consumer.consume(result.reportInfo());
        if (result.problem() != null) {
          notifyNotSent(project, result.problem());
        }
      }, ModalityState.any());
    });
    return true;
  }

  private Result sendSafely(String body) {
    try {
      return send(targets.get(), body, timeout);
    } catch (RuntimeException e) {
      LOG.warn("Error report not sent to CodeScan: " + e.getClass().getSimpleName());
      return Result.failed("an unexpected problem stopped it");
    }
  }

  private static void notifyNotSent(@Nullable Project project, String problem) {
    NotificationGroupManager.getInstance().getNotificationGroup(NOTIFICATION_GROUP)
      .createNotification("CodeScan error report not sent",
        "The error report was not sent to CodeScan support, because " + problem + ". Your description was not sent either. "
          + "Please send the details to CodeScan support another way.",
        NotificationType.WARNING)
      .notify(project);
  }

  /** Where the report goes. The token is a secret, so it is never part of {@link #toString()}. */
  record Target(String url, @Nullable String token) {
    @Override
    public String toString() {
      return "Target[url=" + url + ", login=" + (token == null ? "none" : "token") + "]";
    }
  }

  /** The dialog's answer, and for a failure a short reason the user can read (no exception text, no secrets). */
  record Result(SubmittedReportInfo reportInfo, @Nullable String problem) {
    static Result sent() {
      return new Result(new SubmittedReportInfo(SubmissionStatus.NEW_ISSUE), null);
    }

    static Result failed(String problem) {
      return new Result(new SubmittedReportInfo(SubmissionStatus.FAILED), problem);
    }
  }

  static Target chooseTarget(List<ServerConnection> connections, Predicate<ServerConnection> isCodeScan, String defaultServerUrl) {
    return connections.stream()
      .filter(isCodeScan)
      .findFirst()
      .map(connection -> new Target(errorsUrl(connection.getHostUrl()), StringUtils.trimToNull(connection.getToken())))
      .orElseGet(() -> new Target(errorsUrl(defaultServerUrl), null));
  }

  private static String errorsUrl(String serverUrl) {
    return StringUtils.removeEnd(serverUrl.trim(), "/") + ERRORS_PATH;
  }

  /** Posts the report once; no retry, because every accepted post sends an email to support. */
  static Result send(Target target, String body, Duration timeout) {
    var client = HttpClient.newBuilder()
      // HTTP/1.1 only: the HTTP/2 upgrade on a plain-http POST is refused by some servers and proxies
      .version(HttpClient.Version.HTTP_1_1)
      .connectTimeout(timeout)
      .followRedirects(HttpClient.Redirect.NEVER)
      .build();
    var request = HttpRequest.newBuilder(URI.create(target.url()))
      .timeout(timeout)
      .header("Content-Type", "text/html; charset=UTF-8")
      .POST(HttpRequest.BodyPublishers.ofString(body, StandardCharsets.UTF_8));
    if (target.token() != null) {
      var login = Base64.getEncoder().encodeToString((target.token() + ":").getBytes(StandardCharsets.UTF_8));
      request.header("Authorization", "Basic " + login);
    }
    try {
      var response = client.send(request.build(), HttpResponse.BodyHandlers.discarding());
      var status = response.statusCode();
      if (status >= 200 && status < 300) {
        LOG.info("Error report sent to CodeScan");
        return Result.sent();
      }
      LOG.warn("Error report not sent to CodeScan: the server answered " + status);
      return Result.failed("the CodeScan server answered " + status);
    } catch (HttpTimeoutException e) {
      LOG.warn("Error report not sent to CodeScan: no answer in time");
      return Result.failed("the CodeScan server did not answer in time");
    } catch (IOException e) {
      LOG.warn("Error report not sent to CodeScan: server not reachable (" + e.getClass().getSimpleName() + ")");
      return Result.failed("the CodeScan server could not be reached");
    } catch (InterruptedException e) {
      Thread.currentThread().interrupt();
      return Result.failed("sending was interrupted");
    }
  }

  static @NotNull Map<String, String> getAbbreviations() {
    Map<String, String> aMap = new LinkedHashMap<>();
    aMap.put("com.intellij.openapi.diagnostic.", "c.ij.oa.dg.");
    aMap.put("com.intellij.openapi.application.", "c.ij.oa.ap.");
    aMap.put("com.intellij.openapi.", "c.ij.oa.");
    aMap.put("com.intellij.database.", "c.ij.db.");
    aMap.put("com.intellij.", "c.ij.");
    aMap.put("org.sonarlint.intellij.", "o.sl.ij.");
    aMap.put("org.sonarsource.sonarlint.", "o.ss.sl.");
    aMap.put("org.sonar.plugins.", "o.s.pl.");
    aMap.put("org.jetbrains.", "o.jb.");
    return aMap;
  }

  /** The report as HTML for an email. Everything that comes from the user or from an error is escaped. */
  static @NotNull String buildBody(@NotNull IdeaLoggingEvent[] events, @Nullable String additionalInfo, String ideName, String pluginVersion) {
    var abbreviations = getAbbreviations();
    var body = new StringBuilder();
    body.append("<h4>Environment:</h4>\n<ul>\n");
    item(body, "Java", System.getProperty("java.vendor") + " " + System.getProperty("java.version"));
    item(body, "OS", System.getProperty("os.name") + " " + System.getProperty("os.arch"));
    item(body, "IDE", ideName);
    item(body, "CodeScan", pluginVersion);
    body.append("</ul>\n");
    if (StringUtils.isNotBlank(additionalInfo)) {
      body.append("<h4>Additional information:</h4>\n<p>").append(escape(additionalInfo).replace("\n", "<br/>")).append("</p>\n");
    }
    for (var ideaLoggingEvent : events) {
      final var message = ideaLoggingEvent.getMessage();
      if (StringUtils.isNotBlank(message)) {
        body.append("<p>").append(escape(message)).append("</p>\n");
      }
      final var throwableText = ideaLoggingEvent.getThrowableText();
      if (StringUtils.isNotBlank(throwableText)) {
        body.append("<pre>").append(escape(abbreviate(abbreviations, throwableText))).append("</pre>\n");
      }
    }
    return body.toString();
  }

  private static void item(StringBuilder body, String name, String value) {
    body.append("<li>").append(name).append(": ").append(escape(value)).append("</li>\n");
  }

  private static String escape(String text) {
    return StringEscapeUtils.escapeHtml4(text);
  }

  static String abbreviate(Map<String, String> packageAbbreviation, String throwableText) {
    return new BufferedReader(new StringReader(throwableText)).lines()
      .map(line -> {
        var abbreviated = line;
        for (var entry : packageAbbreviation.entrySet()) {
          abbreviated = StringUtils.replace(abbreviated, entry.getKey(), entry.getValue());
        }
        return abbreviated;
      }).collect(Collectors.joining("\n"));
  }

}
