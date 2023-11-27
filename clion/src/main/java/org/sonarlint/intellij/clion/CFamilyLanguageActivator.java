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
package org.sonarlint.intellij.clion;

import java.util.Set;
import org.sonarlint.intellij.common.LanguageActivator;
import org.sonarsource.sonarlint.core.commons.Language;

public class CFamilyLanguageActivator implements LanguageActivator {
  @Override
  public void amendLanguages(Set<Language> enabledLanguages, boolean isConnected) {
    boolean isPLSQLEnabled = enabledLanguages.contains(Language.PLSQL);
    enabledLanguages.clear();
    enabledLanguages.add(Language.C);
    enabledLanguages.add(Language.CPP);
    enabledLanguages.add(Language.SECRETS);
    if (isPLSQLEnabled) {
      enabledLanguages.add(Language.PLSQL);
    }
  }
}
