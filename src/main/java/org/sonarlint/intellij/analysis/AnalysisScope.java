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
package org.sonarlint.intellij.analysis;

import com.intellij.openapi.module.Module;
import com.intellij.openapi.project.Project;
import com.intellij.openapi.vfs.VirtualFile;
import java.util.Collection;
import java.util.Map;
import java.util.Set;
import org.sonarlint.intellij.common.ui.SonarLintConsole;
import org.sonarlint.intellij.exception.InvalidBindingException;
import org.sonarlint.intellij.trigger.TriggerType;

import static java.util.stream.Collectors.toSet;
import static org.sonarlint.intellij.common.util.SonarLintUtils.getService;

class AnalysisScope {

  public static AnalysisScope defineFrom(Project project, Collection<VirtualFile> files, TriggerType trigger) throws InvalidBindingException {
    var isForcedAnalysis = trigger == TriggerType.ACTION;
    var localFileExclusions = getService(project, LocalFileExclusions.class);
    var console = getService(project, SonarLintConsole.class);
    var filesByModule = localFileExclusions.retainNonExcludedFilesByModules(files, isForcedAnalysis,
      (f, r) -> console.debug("File '" + f.getName() + "' excluded: " + r.excludeReason()));
    return new AnalysisScope(filesByModule);
  }

  private final Map<Module, Collection<VirtualFile>> filesByModule;
  private final Set<VirtualFile> allFilesToAnalyze;

  public AnalysisScope(Map<Module, Collection<VirtualFile>> filesByModule) {
    this.filesByModule = filesByModule;
    this.allFilesToAnalyze = filesByModule.entrySet().stream().flatMap(e -> e.getValue().stream()).collect(toSet());
  }

  public Map<Module, Collection<VirtualFile>> getFilesByModule() {
    return filesByModule;
  }

  public Set<VirtualFile> getAllFilesToAnalyze() {
    return allFilesToAnalyze;
  }

  public boolean isEmpty() {
    return allFilesToAnalyze.isEmpty();
  }

  private int modulesCount() {
    return filesByModule.keySet().size();
  }

  public String getDescription() {
    int numModules = modulesCount();
    var suffix = "";
    if (numModules > 1) {
      suffix = String.format(" in %d modules", numModules);
    }
    long filesCount = allFilesToAnalyze.size();
    if (filesCount > 1) {
      return filesCount + " files" + suffix;
    } else {
      return "'" + allFilesToAnalyze.iterator().next().getName() + "'";
    }
  }
}
