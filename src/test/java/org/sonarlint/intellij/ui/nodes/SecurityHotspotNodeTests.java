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
package org.sonarlint.intellij.ui.nodes;

import com.intellij.psi.PsiFile;
import java.util.Collections;
import java.util.Optional;
import org.junit.jupiter.api.Test;
import org.sonarlint.intellij.finding.hotspot.LiveSecurityHotspot;
import org.sonarsource.sonarlint.core.client.api.common.analysis.Issue;
import org.sonarsource.sonarlint.core.commons.RuleType;
import org.sonarsource.sonarlint.core.commons.VulnerabilityProbability;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class SecurityHotspotNodeTests {

  @Test
  void testCount() {
    var i = createSecurityHotspot();
    var node = new LiveSecurityHotspotNode(i, false);
    assertThat(node.getFindingCount()).isEqualTo(1);
    assertThat(node.getHotspot()).isEqualTo(i);
  }

  private static LiveSecurityHotspot createSecurityHotspot() {
    var file = mock(PsiFile.class);
    when(file.isValid()).thenReturn(true);
    var issue = mock(Issue.class);
    when(issue.getMessage()).thenReturn("rule");
    when(issue.getVulnerabilityProbability()).thenReturn(Optional.of(VulnerabilityProbability.HIGH));
    when(issue.getType()).thenReturn(RuleType.BUG);
    return new LiveSecurityHotspot(issue, file, Collections.emptyList());
  }
}
