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
package org.sonarlint.intellij.ui.tree;

import com.intellij.openapi.editor.RangeMarker;
import com.intellij.openapi.vfs.VirtualFile;
import com.intellij.psi.PsiFile;
import java.util.ArrayList;
import java.util.Collection;
import java.util.Collections;
import java.util.HashMap;
import java.util.LinkedList;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import javax.annotation.Nullable;
import javax.swing.tree.DefaultTreeModel;
import org.junit.jupiter.api.Test;
import org.sonarlint.intellij.finding.issue.LiveIssue;
import org.sonarlint.intellij.ui.nodes.AbstractNode;
import org.sonarsource.sonarlint.core.client.api.common.analysis.Issue;
import org.sonarsource.sonarlint.core.commons.CleanCodeAttribute;
import org.sonarsource.sonarlint.core.commons.ImpactSeverity;
import org.sonarsource.sonarlint.core.commons.IssueSeverity;
import org.sonarsource.sonarlint.core.commons.RuleType;
import org.sonarsource.sonarlint.core.commons.SoftwareQuality;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;
import static org.sonarsource.sonarlint.core.commons.ImpactSeverity.HIGH;
import static org.sonarsource.sonarlint.core.commons.ImpactSeverity.LOW;
import static org.sonarsource.sonarlint.core.commons.IssueSeverity.MAJOR;
import static org.sonarsource.sonarlint.core.commons.IssueSeverity.MINOR;
import static org.sonarsource.sonarlint.core.commons.SoftwareQuality.MAINTAINABILITY;

class IssueTreeModelBuilderTests {
  private final IssueTreeModelBuilder treeBuilder = new IssueTreeModelBuilder();
  private final DefaultTreeModel model = treeBuilder.createModel();

  @Test
  void createModel() {
    var model = treeBuilder.createModel();
    assertThat(model.getRoot()).isNotNull();
  }

  @Test
  void testNavigation() {
    var data = new HashMap<VirtualFile, Collection<LiveIssue>>();

    // ordering of files: name
    // ordering of issues: creation date (inverse), getSeverity, setRuleName, startLine
    addFile(data, "file1", 2);
    addFile(data, "file2", 2);
    addFile(data, "file3", 2);

    treeBuilder.updateModel(data, "empty");
    var first = treeBuilder.getNextIssue((AbstractNode) model.getRoot());
    assertThat(first).isNotNull();

    var second = treeBuilder.getNextIssue(first);
    assertThat(second).isNotNull();

    var third = treeBuilder.getNextIssue(second);
    assertThat(third).isNotNull();

    assertThat(treeBuilder.getPreviousIssue(third)).isEqualTo(second);
    assertThat(treeBuilder.getPreviousIssue(second)).isEqualTo(first);
    assertThat(treeBuilder.getPreviousIssue(first)).isNull();
  }

  @Test
  void testIssueComparator() {
    var list = new ArrayList<LiveIssue>();

    list.add(mockIssuePointer(100, "rule1", MAJOR, null));
    list.add(mockIssuePointer(100, "rule2", MAJOR, 1000L));
    list.add(mockIssuePointer(100, "rule3", MINOR, 2000L));
    list.add(mockIssuePointer(50, "rule4", MINOR, null));
    list.add(mockIssuePointer(100, "rule5", MAJOR, null));

    List<LiveIssue> sorted = new ArrayList<>(list);
    sorted.sort(new IssueTreeModelBuilder.IssueComparator());

    // criteria: creation date (most recent, nulls last), getSeverity (highest first), rule alphabetically
    assertThat(sorted).containsExactly(list.get(2), list.get(1), list.get(0), list.get(4), list.get(3));
  }

  @Test
  void testIssueComparatorNewCct() {
    var list = new ArrayList<LiveIssue>();

    list.add(mockIssuePointer(100, "rule1", Map.of(MAINTAINABILITY, HIGH), null));
    list.add(mockIssuePointer(100, "rule2", Map.of(MAINTAINABILITY, HIGH), 1000L));
    list.add(mockIssuePointer(100, "rule3", Map.of(MAINTAINABILITY, LOW), 2000L));
    list.add(mockIssuePointer(50, "rule4", Map.of(MAINTAINABILITY, LOW), null));
    list.add(mockIssuePointer(100, "rule5", Map.of(MAINTAINABILITY, HIGH), null));

    var sorted = new ArrayList<>(list);
    sorted.sort(new IssueTreeModelBuilder.IssueComparator());

    // criteria: creation date (most recent, nulls last), getImpact (highest first), rule alphabetically
    assertThat(sorted).containsExactly(list.get(2), list.get(1), list.get(0), list.get(4), list.get(3));
  }

  private void addFile(Map<VirtualFile, Collection<LiveIssue>> data, String fileName, int numIssues) {
    var file = mock(VirtualFile.class);
    when(file.getName()).thenReturn(fileName);
    when(file.isValid()).thenReturn(true);

    var issueList = new LinkedList<LiveIssue>();

    for (var i = 0; i < numIssues; i++) {
      issueList.add(mockIssuePointer(i, "rule" + i, MAJOR, (long) i));
    }

    data.put(file, issueList);
  }

  private static LiveIssue mockIssuePointer(int startOffset, String rule, IssueSeverity severity, @Nullable Long introductionDate) {
    var psiFile = mock(PsiFile.class);
    when(psiFile.isValid()).thenReturn(true);

    var issue = mock(Issue.class);
    when(issue.getRuleKey()).thenReturn(rule);
    when(issue.getSeverity()).thenReturn(severity);
    when(issue.getType()).thenReturn(RuleType.BUG);

    var marker = mock(RangeMarker.class);
    when(marker.getStartOffset()).thenReturn(startOffset);

    var liveIssue = new LiveIssue(issue, psiFile, Collections.emptyList());
    liveIssue.setIntroductionDate(introductionDate);
    return liveIssue;
  }

  private static LiveIssue mockIssuePointer(int startOffset, String rule, Map<SoftwareQuality, ImpactSeverity> impacts, @Nullable Long introductionDate) {
    var psiFile = mock(PsiFile.class);
    when(psiFile.isValid()).thenReturn(true);

    var issue = mock(Issue.class);
    when(issue.getRuleKey()).thenReturn(rule);
    when(issue.getType()).thenReturn(RuleType.BUG);
    when(issue.getCleanCodeAttribute()).thenReturn(Optional.of(CleanCodeAttribute.defaultCleanCodeAttribute()));
    when(issue.getImpacts()).thenReturn(impacts);

    var marker = mock(RangeMarker.class);
    when(marker.getStartOffset()).thenReturn(startOffset);

    var liveIssue = new LiveIssue(issue, psiFile, Collections.emptyList());
    liveIssue.setIntroductionDate(introductionDate);
    return liveIssue;
  }

}
