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
package org.sonarlint.intellij.config.global.rules;

import java.awt.event.ActionEvent;
import java.awt.event.KeyEvent;
import java.util.HashMap;
import java.util.List;
import javax.swing.KeyStroke;
import javax.swing.tree.TreePath;
import org.junit.jupiter.api.Test;
import org.sonarlint.intellij.AbstractSonarLintLightTests;
import org.sonarsource.sonarlint.core.rpc.protocol.backend.rules.ImpactDto;
import org.sonarsource.sonarlint.core.rpc.protocol.backend.rules.RuleDefinitionDto;
import org.sonarsource.sonarlint.core.rpc.protocol.common.CleanCodeAttribute;
import org.sonarsource.sonarlint.core.rpc.protocol.common.ImpactSeverity;
import org.sonarsource.sonarlint.core.rpc.protocol.common.SoftwareQuality;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class RulesTreeTableTests extends AbstractSonarLintLightTests {

  @Test
  void space_key_switches_the_selected_rule() {
    var root = new RulesTreeNode.Root();
    var lang = new RulesTreeNode.LanguageNode("lang");
    var ruleDetails = mock(RuleDefinitionDto.class);
    when(ruleDetails.getCleanCodeAttribute()).thenReturn(CleanCodeAttribute.CONVENTIONAL);
    when(ruleDetails.getSoftwareImpacts()).thenReturn(List.of(new ImpactDto(SoftwareQuality.MAINTAINABILITY, ImpactSeverity.MEDIUM)));
    when(ruleDetails.getKey()).thenReturn("key");
    root.add(lang);
    var rule = new RulesTreeNode.Rule(ruleDetails, true, new HashMap<>());
    lang.add(rule);
    var table = new RulesTreeTable(new RulesTreeTableModel(root));
    table.getTree().setSelectionPath(new TreePath(new Object[] {root, lang, rule}));

    var spaceKey = table.getActionForKeyStroke(KeyStroke.getKeyStroke(KeyEvent.VK_SPACE, 0));
    spaceKey.actionPerformed(new ActionEvent(table, ActionEvent.ACTION_PERFORMED, " "));

    assertThat(rule.isActivated()).isFalse();
  }
}
