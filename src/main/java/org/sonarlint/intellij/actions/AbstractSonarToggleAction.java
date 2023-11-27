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
package org.sonarlint.intellij.actions;

import com.intellij.openapi.actionSystem.ToggleAction;
import com.intellij.openapi.actionSystem.UpdateInBackground;
import com.intellij.openapi.project.DumbAware;
import com.intellij.openapi.util.NlsActions;
import javax.swing.Icon;
import org.jetbrains.annotations.Nullable;

// UpdateInBackground is scheduled for removal and comes with a replacement in 2022.2. We have to use it for older versions
public abstract class AbstractSonarToggleAction extends ToggleAction implements DumbAware, UpdateInBackground {

  protected AbstractSonarToggleAction() {
    super();
  }

  protected AbstractSonarToggleAction(@Nullable @NlsActions.ActionText final String text) {
    super(text);
  }

  protected AbstractSonarToggleAction(@Nullable @NlsActions.ActionText final String text,
    @Nullable @NlsActions.ActionDescription final String description,
    @Nullable final Icon icon) {
    super(text, description, icon);
  }
}
