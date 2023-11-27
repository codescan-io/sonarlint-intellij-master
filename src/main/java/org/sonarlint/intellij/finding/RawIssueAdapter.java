/*
 * SonarLint for IntelliJ IDEA
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
package org.sonarlint.intellij.finding;

import com.intellij.openapi.project.Project;
import com.intellij.psi.PsiFile;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.LinkedList;
import java.util.List;
import java.util.Objects;
import java.util.Optional;
import java.util.stream.Collectors;
import org.sonarlint.intellij.common.ui.SonarLintConsole;
import org.sonarlint.intellij.finding.hotspot.LiveSecurityHotspot;
import org.sonarlint.intellij.finding.issue.LiveIssue;
import org.sonarsource.sonarlint.core.analysis.api.ClientInputFile;
import org.sonarsource.sonarlint.core.client.api.common.analysis.Issue;

import static org.sonarlint.intellij.common.ui.ReadActionUtils.computeReadActionSafely;
import static org.sonarlint.intellij.finding.LocationKt.resolvedLocation;
import static org.sonarlint.intellij.finding.QuickFixKt.convert;
import static org.sonarlint.intellij.util.ProjectUtils.toPsiFile;

public class RawIssueAdapter {

  public static LiveSecurityHotspot toLiveSecurityHotspot(Project project, Issue rawHotspot, ClientInputFile inputFile) throws TextRangeMatcher.NoMatchException {
    return computeReadActionSafely(project, () -> {
      var matcher = new TextRangeMatcher(project);
      var psiFile = toPsiFile(project, inputFile.getClientObject());
      var textRange = rawHotspot.getTextRange();
      var quickFixes = transformQuickFixes(project, rawHotspot.quickFixes());
      if (textRange != null) {
        var rangeMarker = matcher.match(psiFile, textRange);
        var context = transformFlows(project, matcher, psiFile, rawHotspot.flows(), rawHotspot.getRuleKey());
        return new LiveSecurityHotspot(rawHotspot, psiFile, rangeMarker, context.orElse(null), quickFixes);
      } else {
        return new LiveSecurityHotspot(rawHotspot, psiFile, quickFixes);
      }
    });
  }

  public static LiveIssue toLiveIssue(Project project, Issue rawIssue, ClientInputFile inputFile) throws TextRangeMatcher.NoMatchException {
    return computeReadActionSafely(project, () -> {
      var matcher = new TextRangeMatcher(project);
      var psiFile = toPsiFile(project, inputFile.getClientObject());
      var textRange = rawIssue.getTextRange();
      var quickFixes = transformQuickFixes(project, rawIssue.quickFixes());
      if (textRange != null) {
        var rangeMarker = matcher.match(psiFile, textRange);
        var context = transformFlows(project, matcher, psiFile, rawIssue.flows(), rawIssue.getRuleKey());
        return new LiveIssue(rawIssue, psiFile, rangeMarker, context.orElse(null), quickFixes);
      } else {
        return new LiveIssue(rawIssue, psiFile, quickFixes);
      }
    });
  }

  private static Optional<FindingContext> transformFlows(Project project, TextRangeMatcher matcher, PsiFile psiFile,
    List<org.sonarsource.sonarlint.core.analysis.api.Flow> flows, String rule) {
    List<Flow> matchedFlows = new LinkedList<>();

    for (var flow : flows) {
      List<Location> matchedLocations = new LinkedList<>();
      for (var loc : flow.locations()) {
        try {
          var textRange = loc.getTextRange();
          var locInputFile = loc.getInputFile();
          if (textRange != null && locInputFile != null) {
            var locPsiFile = toPsiFile(project, locInputFile.getClientObject());
            var range = matcher.match(locPsiFile, textRange);
            matchedLocations.add(resolvedLocation(locPsiFile.getVirtualFile(), range, loc.getMessage(), null));
          }
        } catch (TextRangeMatcher.NoMatchException e) {
          // File content is likely to have changed during the analysis, should be fixed in next analysis
          SonarLintConsole.get(project)
            .debug("Failed to find secondary location of finding for file: '" + psiFile.getName() + "'. The location won't be displayed - " + e.getMessage());
        } catch (Exception e) {
          var detailString = String.join(",",
            rule,
            String.valueOf(loc.getStartLine()),
            String.valueOf(loc.getStartLineOffset()),
            String.valueOf(loc.getEndLine()),
            String.valueOf(loc.getEndLineOffset())
          );
          SonarLintConsole.get(project).error("Error finding secondary location for finding: " + detailString, e);
          return Optional.empty();
        }
      }
      var matchedFlow = new Flow(matchedLocations);
      matchedFlows.add(matchedFlow);

    }

    return adapt(matchedFlows);
  }

  public static Optional<FindingContext> adapt(List<Flow> flows) {
    return flows.isEmpty()
      ? Optional.empty()
      : Optional.of(new FindingContext(adaptFlows(flows)));
  }

  private static List<Flow> adaptFlows(List<Flow> flows) {
    return flows.stream().anyMatch(Flow::hasMoreThanOneLocation)
      ? reverse(flows)
      : List.of(groupToSingleFlow(flows));
  }

  private static Flow groupToSingleFlow(List<Flow> flows) {
    return new Flow(flows.stream()
      .flatMap(f -> f.getLocations().stream())
      .sorted(Comparator.comparing(i -> i.getRange().getStartOffset()))
      .collect(Collectors.toList()));
  }

  private static List<Flow> reverse(List<Flow> flows) {
    return flows.stream().map(f -> {
      var reorderedLocations = new ArrayList<>(f.getLocations());
      Collections.reverse(reorderedLocations);
      return new Flow(reorderedLocations);
    }).collect(Collectors.toList());
  }

  private static List<QuickFix> transformQuickFixes(Project project,
    List<org.sonarsource.sonarlint.core.analysis.api.QuickFix> quickFixes) {
    return quickFixes
      .stream().map(fix -> convert(project, fix))
      .filter(Objects::nonNull)
      .collect(Collectors.toList());
  }

  private RawIssueAdapter() {
    // utility class
  }
}
