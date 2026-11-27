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
package org.sonarlint.intellij;

import com.intellij.ide.plugins.PluginManager;
import com.intellij.ide.plugins.cl.PluginAwareClassLoader;
import com.intellij.openapi.components.Service;
import com.intellij.openapi.extensions.PluginDescriptor;
import com.intellij.openapi.extensions.PluginId;
import java.nio.file.Path;

@Service(Service.Level.APP)
public final class SonarLintPlugin {
  private static final String PLUGIN_ID = "com.code-scan.intellij";
  private PluginDescriptor plugin;

  public String getVersion() {
    return getPlugin().getVersion();
  }

  public Path getPath() {
    return getPlugin().getPluginPath();
  }

  private PluginDescriptor getPlugin() {
    if (plugin == null) {
      // CodeScan (7.3.1): find our own plugin through its class loader, not the internal PluginManagerCore.getPlugin.
      // In tests our classes are not loaded by the plugin's class loader, so look the plugin up by its id there.
      var classLoader = getClass().getClassLoader();
      plugin = classLoader instanceof PluginAwareClassLoader pluginClassLoader
        ? pluginClassLoader.getPluginDescriptor()
        : PluginManager.getInstance().findEnabledPlugin(PluginId.getId(PLUGIN_ID));
    }
    return plugin;
  }
}
