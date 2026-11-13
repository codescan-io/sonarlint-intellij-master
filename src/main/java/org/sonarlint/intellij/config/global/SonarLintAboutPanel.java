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
package org.sonarlint.intellij.config.global;

import com.intellij.ide.BrowserUtil;
import com.intellij.ui.HyperlinkLabel;
import com.intellij.ui.components.JBLabel;
import java.awt.BorderLayout;
import java.awt.GridBagConstraints;
import java.awt.GridBagLayout;
import java.time.LocalDate;
import javax.swing.JComponent;
import javax.swing.JPanel;
import org.sonarlint.intellij.SonarLintIcons;
import org.sonarlint.intellij.SonarLintPlugin;
import org.sonarlint.intellij.common.util.SonarLintUtils;
import org.sonarlint.intellij.config.ConfigurationPanel;
import org.sonarlint.intellij.telemetry.SonarLintTelemetry;

// CodeScan: no Statistics section. Telemetry is off (BackendService), and the backend would send even an opt-out to
// SonarSource's telemetry address, so the page offers no choice
public class SonarLintAboutPanel implements ConfigurationPanel<SonarLintTelemetry> {
  private final JPanel panel;

  public SonarLintAboutPanel() {
    panel = new JPanel(new BorderLayout(0, 20));
    panel.add(createSonarLintPanel(), BorderLayout.NORTH);
  }

  private JComponent createSonarLintPanel() {
    var sonarlintIcon = new JBLabel(SonarLintIcons.SONARQUBE_FOR_INTELLIJ_32PX);
    var plugin = SonarLintUtils.getService(SonarLintPlugin.class);
    var title = new JBLabel("<html><b>CodeScan IntelliJ " + plugin.getVersion() + "</b></html>");
    var linkLabel = new HyperlinkLabel("codescan.io");
    linkLabel.addHyperlinkListener(e -> BrowserUtil.browse("https://www.codescan.io"));
    var copyrightLabel = new JBLabel("<html>&copy; " + LocalDate.now().getYear() + " CodeScan</html>");

    var infoPanel = new JPanel(new GridBagLayout());
    var constraints = new GridBagConstraints();
    constraints.gridx = 0;
    constraints.gridy = 0;
    constraints.ipadx = 10;
    constraints.ipady = 5;
    constraints.gridwidth = 2;
    infoPanel.add(title, constraints);
    constraints.gridx = 0;
    constraints.gridy = 1;
    constraints.ipady = 2;
    constraints.gridwidth = 1;
    constraints.gridheight = 2;
    constraints.fill = GridBagConstraints.VERTICAL;
    infoPanel.add(sonarlintIcon, constraints);
    constraints.gridx = 1;
    constraints.gridheight = 1;
    constraints.fill = GridBagConstraints.NONE;
    infoPanel.add(linkLabel, constraints);
    constraints.gridy = 2;
    constraints.fill = GridBagConstraints.NONE;
    infoPanel.add(copyrightLabel, constraints);

    return infoPanel;
  }

  public JComponent getComponent() {
    return panel;
  }

  @Override
  public void load(SonarLintTelemetry telemetry) {
    // nothing to load: the page has no settings
  }

  @Override
  public void save(SonarLintTelemetry telemetry) {
    // nothing to save: the page has no settings
  }

  @Override
  public boolean isModified(SonarLintTelemetry telemetry) {
    return false;
  }
}
