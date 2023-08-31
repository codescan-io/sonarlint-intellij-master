/*
 * Codescan for IntelliJ IDEA
 * Copyright (C) 2015-2023 SonarSource
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
package org.sonarlint.intellij.util;

import com.intellij.openapi.progress.ProgressIndicator;
import com.intellij.openapi.project.Project;
import java.time.Duration;
import java.util.List;
import java.util.concurrent.CancellationException;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import org.sonarlint.intellij.common.ui.SonarLintConsole;

public class FutureUtils {

  private static final long WAITING_FREQUENCY = 100;

  public static void waitForTask(Project project, ProgressIndicator indicator, Future<?> task, String taskName, Duration timeoutDuration) {
    try {
      waitForFutureWithTimeout(indicator, task, timeoutDuration);
    } catch (TimeoutException ex) {
      task.cancel(true);
      SonarLintConsole.get(project).error(taskName + " task expired", ex);
    } catch (InterruptedException ex) {
      Thread.currentThread().interrupt();
    } catch (Exception ex) {
      SonarLintConsole.get(project).error(taskName + " task failed", ex);
    }
  }

  public static void waitForTasks(Project project, ProgressIndicator indicator, List<Future<?>> updateTasks, String taskName) {
    for (var f : updateTasks) {
      waitForTask(project, indicator, f, taskName, Duration.ofSeconds(20));
    }
  }

  private static void waitForFutureWithTimeout(ProgressIndicator indicator, Future<?> future, Duration durationTimeout)
    throws InterruptedException, ExecutionException, TimeoutException {
    long counter = 0;
    while (counter < durationTimeout.toMillis()) {
      counter += WAITING_FREQUENCY;
      if (indicator.isCanceled()) {
        future.cancel(true);
        return;
      }
      try {
        future.get(WAITING_FREQUENCY, TimeUnit.MILLISECONDS);
        return;
      } catch (TimeoutException ignored) {
        continue;
      } catch (InterruptedException | CancellationException e) {
        throw new InterruptedException("Interrupted");
      }
    }
    throw new TimeoutException();
  }

  private FutureUtils() {
    // utility class
  }
}
