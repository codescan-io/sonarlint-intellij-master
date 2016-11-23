/*
 * SonarLint for IntelliJ IDEA
 * Copyright (C) 2015 SonarSource
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
package org.sonarlint.intellij.analysis;

import com.intellij.openapi.vfs.VirtualFile;
import java.util.Collection;
import java.util.Collections;
import java.util.Map;
import java.util.stream.IntStream;
import org.sonarlint.intellij.issue.LiveIssue;

public class AnalysisResult {
  private long filesAnalysed;
  private long issuesToShow;
  private Map<VirtualFile, Collection<LiveIssue>> issues;

  public AnalysisResult(long filesAnalysed, Map<VirtualFile, Collection<LiveIssue>> issues, long issuesToShow) {
    this.filesAnalysed = filesAnalysed;
    this.issues = issues;
    this.issuesToShow = issuesToShow;
  }

  public static AnalysisResult empty() {
    return new AnalysisResult(0, Collections.emptyMap(), 0);
  }

  public long numberIssues() {
    return issuesToShow;
  }

  public long filesAnalysed() {
    return filesAnalysed;
  }

  public Map<VirtualFile, Collection<LiveIssue>> issues() {
    return issues;
  }
}