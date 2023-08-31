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
package org.sonarlint.intellij.finding.issue;

import com.intellij.openapi.editor.RangeMarker;
import com.intellij.psi.PsiFile;
import java.util.List;
import javax.annotation.Nullable;
import org.sonarlint.intellij.finding.FindingContext;
import org.sonarlint.intellij.finding.LiveFinding;
import org.sonarlint.intellij.finding.QuickFix;
import org.sonarsource.sonarlint.core.client.api.common.analysis.Issue;
import org.sonarsource.sonarlint.core.commons.RuleType;

public class LiveIssue extends LiveFinding implements org.sonarlint.intellij.finding.Issue {

  private RuleType type;

  public LiveIssue(Issue issue, PsiFile psiFile, List<QuickFix> quickFixes) {
    this(issue, psiFile, null, null, quickFixes);
  }

  public LiveIssue(Issue issue, PsiFile psiFile, @Nullable RangeMarker range, @Nullable FindingContext context, List<QuickFix> quickFixes) {
    super(issue, psiFile, range, context, quickFixes);
    this.type = issue.getType();
  }

  @Override
  public RuleType getType() {
    return type;
  }

  public void setType(@Nullable RuleType type) {
    this.type = type;
  }

  @Override
  public void resolve() {
    setResolved(true);
  }
}
