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
package org.sonarlint.intellij.common.util;

import com.intellij.openapi.application.ApplicationManager;
import com.intellij.openapi.components.Service;
import com.intellij.openapi.diagnostic.Logger;
import com.intellij.util.io.HttpRequests;
import java.io.IOException;
import java.net.HttpURLConnection;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.TimeUnit;

/**
 * CodeScan: tells whether an address is a self-hosted CodeScan server on its own domain, by asking the server for
 * CodeScan's health page. Only an HTTP 200 answer of exactly {"status":"UP"} or {"status":"DOWN"} counts.
 * <p>
 * Each server is asked once and the answer is kept in memory. A "no" is kept for a few minutes only, in case the server
 * was down. The server is never asked on the UI thread: there, a server not asked yet counts as "no" for now and is
 * asked in the background. The IDE's HTTP client is used, so the IDE's proxy and certificate settings apply.
 */
@Service(Service.Level.APP)
public final class CodeScanServerCheck {

  static final String HEALTH_PATH = "/_codescan/actuator/health";
  private static final Logger LOG = Logger.getInstance(CodeScanServerCheck.class);
  private static final Set<String> CODESCAN_HEALTH_ANSWERS = Set.of("{\"status\":\"UP\"}", "{\"status\":\"DOWN\"}");
  private static final int TIMEOUT_MS = (int) TimeUnit.SECONDS.toMillis(5);
  private static final long NO_IS_KEPT_FOR_MS = TimeUnit.MINUTES.toMillis(5);

  private final Map<String, Answer> answers = new ConcurrentHashMap<>();
  private final Set<String> askingInBackground = ConcurrentHashMap.newKeySet();

  /**
   * @param serverUrl the server address without a trailing slash, query or fragment
   */
  public boolean isCodeScanServer(String serverUrl) {
    var answer = answers.get(serverUrl);
    if (answer != null && !answer.isOutdated()) {
      return answer.isCodeScan;
    }
    var application = ApplicationManager.getApplication();
    if (application != null && application.isDispatchThread()) {
      if (askingInBackground.add(serverUrl)) {
        application.executeOnPooledThread(() -> {
          try {
            askNow(serverUrl);
          } finally {
            askingInBackground.remove(serverUrl);
          }
        });
      }
      return false;
    }
    return askNow(serverUrl);
  }

  /**
   * Asks the server now, even if an answer is kept, and keeps the new answer. Blocks for up to a few seconds, so never
   * call it on the UI thread.
   */
  public boolean askNow(String serverUrl) {
    var isCodeScan = askServer(serverUrl);
    answers.put(serverUrl, new Answer(isCodeScan, isCodeScan ? Long.MAX_VALUE : System.currentTimeMillis() + NO_IS_KEPT_FOR_MS));
    return isCodeScan;
  }

  private static boolean askServer(String serverUrl) {
    try {
      return HttpRequests.request(serverUrl + HEALTH_PATH)
        .connectTimeout(TIMEOUT_MS)
        .readTimeout(TIMEOUT_MS)
        .throwStatusCodeException(false)
        .connect(request -> {
          var status = ((HttpURLConnection) request.getConnection()).getResponseCode();
          if (status != HttpURLConnection.HTTP_OK) {
            LOG.debug("CodeScan health check of " + serverUrl + " answered with status " + status);
            return false;
          }
          var body = request.readString().trim();
          if (!CODESCAN_HEALTH_ANSWERS.contains(body)) {
            LOG.debug("CodeScan health check of " + serverUrl + " answered with a body that is not CodeScan's");
            return false;
          }
          return true;
        });
    } catch (IOException | RuntimeException e) {
      LOG.warn("CodeScan health check of " + serverUrl + " failed: " + e);
      return false;
    }
  }

  private static final class Answer {
    private final boolean isCodeScan;
    private final long keptUntil;

    private Answer(boolean isCodeScan, long keptUntil) {
      this.isCodeScan = isCodeScan;
      this.keptUntil = keptUntil;
    }

    private boolean isOutdated() {
      return System.currentTimeMillis() > keptUntil;
    }
  }
}
