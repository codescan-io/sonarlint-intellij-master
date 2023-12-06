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

import com.intellij.openapi.actionSystem.ActionPlaces;
import com.intellij.openapi.actionSystem.AnActionEvent;
import com.intellij.openapi.components.Service;
import com.intellij.openapi.fileEditor.FileEditorManager;
import com.intellij.openapi.project.Project;
import com.intellij.openapi.vcs.changes.ChangeListManager;
import com.intellij.openapi.vfs.VirtualFile;
import java.util.Collection;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.atomic.AtomicBoolean;
import javax.annotation.CheckForNull;
import org.sonarlint.intellij.actions.ShowReportCallable;
import org.sonarlint.intellij.actions.ShowSecurityHotspotCallable;
import org.sonarlint.intellij.actions.ShowUpdatedCurrentFileCallable;
import org.sonarlint.intellij.actions.UpdateOnTheFlyFindingsCallable;
import org.sonarlint.intellij.common.ui.SonarLintConsole;
import org.sonarlint.intellij.common.util.SonarLintUtils;
import org.sonarlint.intellij.tasks.TaskRunnerKt;
import org.sonarlint.intellij.trigger.TriggerType;
import org.sonarlint.intellij.ui.SonarLintToolWindowFactory;

import static org.sonarlint.intellij.config.Settings.getGlobalSettings;
import static org.sonarlint.intellij.util.ProjectUtils.getAllFiles;

@Service(Service.Level.PROJECT)
public final class AnalysisSubmitter {
  public static final String ANALYSIS_TASK_TITLE = "CodeScan Analysis";
  private final Project project;
  private final OnTheFlyFindingsHolder onTheFlyFindingsHolder;
  private Cancelable currentManualAnalysis;

  public AnalysisSubmitter(Project project) {
    this.project = project;
    this.onTheFlyFindingsHolder = new OnTheFlyFindingsHolder(project);
  }

  public void cancelCurrentManualAnalysis() {
    if (currentManualAnalysis != null) {
      currentManualAnalysis.cancel();
      currentManualAnalysis = null;
    }
  }

  public void analyzeAllFiles() {
    var allFiles = getAllFiles(project);
    var callback = new ShowReportCallable(project);
    var analysis = new Analysis(project, allFiles, TriggerType.ALL, callback);
    TaskRunnerKt.startBackgroundableModalTask(project, ANALYSIS_TASK_TITLE, analysis::run);
  }

  public void analyzeVcsChangedFiles() {
    var changedFiles = ChangeListManager.getInstance(project).getAffectedFiles();
    var callback = new ShowReportCallable(project);
    var analysis = new Analysis(project, changedFiles, TriggerType.CHANGED_FILES, callback);
    TaskRunnerKt.startBackgroundableModalTask(project, ANALYSIS_TASK_TITLE, analysis::run);
  }

  public void autoAnalyzeOpenFiles(TriggerType triggerType) {
    var openFiles = FileEditorManager.getInstance(project).getOpenFiles();
    autoAnalyzeFiles(List.of(openFiles), triggerType);
  }

  public void autoAnalyzeFile(VirtualFile file, TriggerType triggerType) {
    autoAnalyzeFiles(Collections.singleton(file), triggerType);
  }

  @CheckForNull
  public Cancelable autoAnalyzeFiles(Collection<VirtualFile> files, TriggerType triggerType) {
    if (!getGlobalSettings().isAutoTrigger()) {
      return null;
    }
    var callback = new UpdateOnTheFlyFindingsCallable(onTheFlyFindingsHolder);
    return analyzeInBackground(files, triggerType, callback);
  }

  @CheckForNull
  public AnalysisResult analyzeFilesPreCommit(Collection<VirtualFile> files) {
    var console = SonarLintUtils.getService(project, SonarLintConsole.class);
    var trigger = TriggerType.CHECK_IN;
    console.debug("Trigger: " + trigger);
    if (shouldSkipAnalysis()) {
      return null;
    }

    var callback = new ErrorAwareAnalysisCallback();
    var analysis = new Analysis(project, files, trigger, callback);
    var result = TaskRunnerKt.runModalTaskWithResult(project, ANALYSIS_TASK_TITLE, analysis::run);
    return callback.analysisSucceeded() ? result : null;
  }

  public void analyzeFilesOnUserAction(Collection<VirtualFile> files, AnActionEvent actionEvent) {
    AnalysisCallback callback;

    if (SonarLintToolWindowFactory.TOOL_WINDOW_ID.equals(actionEvent.getPlace())
      || ActionPlaces.isMainMenuOrActionSearch(actionEvent.getPlace())) {
      callback = new ShowUpdatedCurrentFileCallable(project, onTheFlyFindingsHolder);
    } else {
      callback = new ShowReportCallable(project);
    }

    // do we really need to distinguish both cases ? Couldn't we always run in background ?
    if (shouldExecuteInBackground(actionEvent)) {
      analyzeInBackground(files, TriggerType.ACTION, callback);
    } else {
      currentManualAnalysis = analyzeInBackgroundableModal(files, TriggerType.ACTION, callback);
    }
  }

  public void analyzeFileAndTrySelectHotspot(VirtualFile file, String securityHotspotKey) {
    AnalysisCallback callback = new ShowSecurityHotspotCallable(project, onTheFlyFindingsHolder, securityHotspotKey);
    var task = new Analysis(project, List.of(file), TriggerType.OPEN_SECURITY_HOTSPOT, callback);
    TaskRunnerKt.startBackgroundableModalTask(project, ANALYSIS_TASK_TITLE, task::run);
  }

  /**
   * Whether the analysis should be launched in the background.
   * Analysis should be run in background in the following cases:
   * - Keybinding used (place = MainMenu)
   * - Macro used (place = unknown)
   * - Action used, ctrl+shift+A (place = GoToAction)
   */
  private static boolean shouldExecuteInBackground(AnActionEvent e) {
    return ActionPlaces.isMainMenuOrActionSearch(e.getPlace())
      || ActionPlaces.UNKNOWN.equals(e.getPlace());
  }

  private Cancelable analyzeInBackground(Collection<VirtualFile> files, TriggerType trigger, AnalysisCallback callback) {
    var analysis = new Analysis(project, files, trigger, callback);
    TaskRunnerKt.startBackgroundTask(project, ANALYSIS_TASK_TITLE, analysis::run);
    return analysis;
  }

  private Cancelable analyzeInBackgroundableModal(Collection<VirtualFile> files, TriggerType action, AnalysisCallback callback) {
    if (shouldSkipAnalysis()) {
      return null;
    }
    var analysis = new Analysis(project, files, action, callback);
    TaskRunnerKt.startBackgroundableModalTask(project, ANALYSIS_TASK_TITLE, analysis::run);
    return analysis;
  }

  private boolean shouldSkipAnalysis() {
    var status = SonarLintUtils.getService(project, AnalysisStatus.class);
    var console = SonarLintUtils.getService(project, SonarLintConsole.class);
    if (project.isDisposed() || !status.tryRun()) {
      console.info("Canceling analysis triggered by the user because another one is already running or because the project is disposed");
      return true;
    }
    return false;
  }

  public void clearCurrentFileIssues() {
    onTheFlyFindingsHolder.clearCurrentFile();
  }

  private static class ErrorAwareAnalysisCallback implements AnalysisCallback {
    private final AtomicBoolean errored = new AtomicBoolean(false);

    @Override
    public void onSuccess(AnalysisResult analysisResult) {
      // do nothing
    }

    @Override
    public void onError(Throwable e) {
      errored.set(true);
    }

    public boolean analysisSucceeded() {
      return !errored.get();
    }

  }
}
