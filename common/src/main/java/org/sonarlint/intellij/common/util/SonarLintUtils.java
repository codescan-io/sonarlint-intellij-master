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
package org.sonarlint.intellij.common.util;

import com.intellij.lang.Language;
import com.intellij.openapi.application.ApplicationInfo;
import com.intellij.openapi.application.ApplicationManager;
import com.intellij.openapi.diagnostic.Logger;
import com.intellij.openapi.fileEditor.FileDocumentManager;
import com.intellij.openapi.fileEditor.FileEditorManager;
import com.intellij.openapi.module.Module;
import com.intellij.openapi.module.ModuleServiceManager;
import com.intellij.openapi.project.Project;
import com.intellij.openapi.roots.ModuleRootManager;
import com.intellij.openapi.roots.SourceFolder;
import com.intellij.openapi.vfs.VirtualFile;
import com.intellij.psi.PsiFile;
import java.net.URI;
import java.net.URISyntaxException;
import java.util.List;
import java.util.Locale;
import javax.annotation.CheckForNull;
import javax.annotation.Nullable;
import org.jetbrains.annotations.NotNull;
import org.jetbrains.jps.model.java.JavaModuleSourceRootTypes;

public class SonarLintUtils {

  private static final Logger LOG = Logger.getInstance(SonarLintUtils.class);
  public static final String DEFAULT_SONARCLOUD_URL = "https://sonarcloud.io";
  // CodeScan: the "cloud" is CodeScan's, so new cloud connections and their links use this address
  public static final String DEFAULT_CODESCANCLOUD_URL = "https://app.codescan.io";
  public static final String SONARCLOUD_URL = System.getProperty("sonarlint.internal.sonarcloud.url", DEFAULT_CODESCANCLOUD_URL);
  // CodeScan: every host on these domains is CodeScan
  private static final List<String> CODESCAN_DOMAINS = List.of("codescan.io", "autorabit.com");
  @Nullable
  private static final String SONARCLOUD_HOST = hostOf(SONARCLOUD_URL);

  private SonarLintUtils() {
    // Utility class
  }

  public static <T> T getService(Class<T> clazz) {
    var t = ApplicationManager.getApplication().getService(clazz);
    logAndThrowIfServiceNotFound(t, clazz.getName());

    return t;
  }

  public static <T> T getService(@NotNull Project project, Class<T> clazz) {
    var t = project.getService(clazz);
    logAndThrowIfServiceNotFound(t, clazz.getName());

    return t;
  }

  public static <T> T getService(@NotNull Module module, Class<T> clazz) {
    var t = ModuleServiceManager.getService(module, clazz);
    logAndThrowIfServiceNotFound(t, clazz.getName());

    return t;
  }

  private static <T> void logAndThrowIfServiceNotFound(T t, String name) {
    if (t == null) {
      LOG.error("Could not find service: " + name);
      throw new IllegalArgumentException("Class not found: " + name);
    }
  }

  /**
   * CodeScan: tells whether a server is CodeScan, which the plugin treats as a "cloud" server (it has organizations).
   * That is the case for the cloud address, for any host on codescan.io or autorabit.com (the host itself; the rest of the
   * address does not count), and for a self-hosted CodeScan server on its own domain that answers CodeScan's health check.
   * On the UI thread the health check is never waited for, see {@link CodeScanServerCheck}.
   */
  public static boolean isSonarCloudAlias(@Nullable String url) {
    if (isBlank(url)) {
      return false;
    }
    URI uri;
    try {
      uri = new URI(url.trim());
    } catch (URISyntaxException e) {
      return false;
    }
    var scheme = uri.getScheme();
    var host = uri.getHost();
    if (scheme == null || host == null || !("http".equalsIgnoreCase(scheme) || "https".equalsIgnoreCase(scheme))) {
      return false;
    }
    host = host.toLowerCase(Locale.ROOT);
    if (isCodeScanHost(host)) {
      return true;
    }
    var application = ApplicationManager.getApplication();
    if (application == null) {
      // no IDE around (plain unit tests), so no health check
      return false;
    }
    return application.getService(CodeScanServerCheck.class).isCodeScanServer(serverAddress(scheme, host, uri));
  }

  private static boolean isCodeScanHost(String host) {
    if (host.equals(SONARCLOUD_HOST)) {
      return true;
    }
    return CODESCAN_DOMAINS.stream().anyMatch(domain -> host.equals(domain) || host.endsWith("." + domain));
  }

  @CheckForNull
  private static String hostOf(String url) {
    try {
      var host = new URI(url).getHost();
      return host == null ? null : host.toLowerCase(Locale.ROOT);
    } catch (URISyntaxException e) {
      return null;
    }
  }

  /**
   * The address without user name, query, fragment or trailing slashes, so each server is asked once.
   */
  private static String serverAddress(String scheme, String host, URI uri) {
    var port = uri.getPort() == -1 ? "" : (":" + uri.getPort());
    var path = uri.getRawPath() == null ? "" : uri.getRawPath();
    while (path.endsWith("/")) {
      path = path.substring(0, path.length() - 1);
    }
    return scheme.toLowerCase(Locale.ROOT) + "://" + host + port + path;
  }

  public static boolean isEmpty(@Nullable String str) {
    return str == null || str.isEmpty();
  }

  public static boolean isBlank(@Nullable String str) {
    return str == null || str.trim().isEmpty();
  }

  public static boolean equalsIgnoringTrailingSlash(String aString, String anotherString) {
    return withTrailingSlash(aString).equals(withTrailingSlash(anotherString));
  }

  public static String withTrailingSlash(String str) {
    if (!str.endsWith("/")) {
      return str + '/';
    }
    return str;
  }

  public static String withoutTrailingSlash(String str) {
    if (str.endsWith("/")) {
      return str.substring(0, str.length() - 1);
    }
    return str;
  }

  /**
   * FileEditorManager#getSelectedFiles does not work as expected. In split editors, the order of the files does not change depending
   * on which one of the split editors is selected.
   * This seems to work well with split editors.
   */
  @CheckForNull
  public static VirtualFile getSelectedFile(Project project) {
    if (project.isDisposed()) {
      return null;
    }
    ApplicationManager.getApplication().assertIsDispatchThread();
    var editorManager = FileEditorManager.getInstance(project);

    var editor = editorManager.getSelectedTextEditor();
    if (editor != null) {
      var doc = editor.getDocument();
      var docManager = FileDocumentManager.getInstance();
      return docManager.getFile(doc);
    }

    return null;
  }

  public static boolean isGeneratedSource(SourceFolder sourceFolder) {
    // copied from JavaProjectRootsUtil. Don't use that class because it's not available in other flavors of Intellij
    var properties = sourceFolder.getJpsElement().getProperties(JavaModuleSourceRootTypes.SOURCES);
    var resourceProperties = sourceFolder.getJpsElement().getProperties(JavaModuleSourceRootTypes.RESOURCES);
    return (properties != null && properties.isForGeneratedSources()) || (resourceProperties != null && resourceProperties.isForGeneratedSources());
  }

  @Nullable
  public static SourceFolder getSourceFolder(@CheckForNull VirtualFile source, Module module) {
    if (source == null) {
      return null;
    }
    for (var entry : ModuleRootManager.getInstance(module).getContentEntries()) {
      for (var folder : entry.getSourceFolders()) {
        if (source.equals(folder.getFile())) {
          return folder;
        }
      }
    }
    return null;
  }

  public static boolean isJavaResource(SourceFolder source) {
    return JavaModuleSourceRootTypes.RESOURCES.contains(source.getRootType());
  }

  public static String pluralize(String str, long i) {
    if (i == 1) {
      return str;
    }
    return str + "s";
  }

  public static boolean isPhpLanguageRegistered() {
    return Language.findLanguageByID("PHP") != null;
  }

  public static boolean isPhpFile(@NotNull PsiFile file) {
    return "php".equalsIgnoreCase(file.getFileType().getName());
  }

  private static ApplicationInfo getAppInfo() {
    return ApplicationInfo.getInstance();
  }

  /** Alternative to {@link com.intellij.util.PlatformUtils#isCLion} */
  public static boolean isCLion() {
    return getAppInfo().getFullApplicationName().toLowerCase().contains("clion");
  }

  /** Alternative to {@link com.intellij.util.PlatformUtils#isGoIde} */
  public static boolean isGoIde() {
    return getAppInfo().getFullApplicationName().toLowerCase().contains("goland");
  }

  /** Alternative to {@link com.intellij.util.PlatformUtils#isRider} */
  public static boolean isRider() {
    return getAppInfo().getFullApplicationName().toLowerCase().contains("rider");
  }

  /** Alternative to {@link com.intellij.util.PlatformUtils#isAppCode} */
  public static boolean isAppCode() {
    return getAppInfo().getFullApplicationName().toLowerCase().contains("appcode");
  }

  /** CodeScan: taint vulnerabilities are not shown (no tab, no editor marks). */
  public static boolean isTaintVulnerabilitiesEnabled() {
    return false;
  }

  public static boolean isModuleLevelBindingEnabled() {
    return !isRider() && !isCLion() && !isAppCode();
  }
}
