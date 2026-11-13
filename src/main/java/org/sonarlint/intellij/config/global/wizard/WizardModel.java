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
package org.sonarlint.intellij.config.global.wizard;

import com.intellij.openapi.progress.ProgressManager;
import java.util.ArrayList;
import java.util.List;
import javax.annotation.CheckForNull;
import javax.annotation.Nullable;
import org.sonarlint.intellij.common.util.SonarLintUtils;
import org.sonarlint.intellij.config.global.ServerConnection;
import org.sonarlint.intellij.tasks.CheckNotificationsSupportedTask;
import org.sonarlint.intellij.tasks.GetOrganizationTask;
import org.sonarlint.intellij.tasks.GetOrganizationsTask;
import org.sonarsource.sonarlint.core.rpc.protocol.backend.connection.org.OrganizationDto;

import static org.sonarlint.intellij.common.util.SonarLintUtils.SONARCLOUD_URL;

public class WizardModel {
  private ServerType serverType;
  private String serverUrl;
  private String token;
  private String login;
  private char[] password;
  private String name;
  private String organizationKey;
  private boolean proxyEnabled;
  private boolean notificationsDisabled = false;
  private boolean notificationsSupported = false;

  private List<OrganizationDto> organizationList = new ArrayList<>();

  public enum ServerType {
    SONARCLOUD,
    SONARQUBE
  }

  public WizardModel() {

  }

  public WizardModel(ServerConnection connectionToEdit) {
    if (SonarLintUtils.isSonarCloudAlias(connectionToEdit.getHostUrl())) {
      serverType = ServerType.SONARCLOUD;
    } else {
      serverType = ServerType.SONARQUBE;
    }
    // CodeScan: a cloud connection keeps its address too, because a self-hosted CodeScan server is a cloud connection
    serverUrl = connectionToEdit.getHostUrl();
    this.proxyEnabled = connectionToEdit.enableProxy();
    this.token = connectionToEdit.getToken();
    this.login = connectionToEdit.getLogin();
    var pass = connectionToEdit.getPassword();
    if (pass != null) {
      this.password = pass.toCharArray();
    }
    this.organizationKey = connectionToEdit.getOrganizationKey();
    this.notificationsDisabled = connectionToEdit.isDisableNotifications();
    this.name = connectionToEdit.getName();
  }

  @CheckForNull
  public ServerType getServerType() {
    return serverType;
  }

  public WizardModel setServerType(ServerType serverType) {
    this.serverType = serverType;
    return this;
  }

  public boolean isSonarCloud() {
    return ServerType.SONARCLOUD.equals(serverType);
  }

  /**
   * Whether the server step selects the cloud choice rather than showing a server address.
   * CodeScan: a cloud connection on another address than the default cloud (a self-hosted CodeScan server) shows its address.
   */
  public boolean usesDefaultCloudServer() {
    return serverType == null
      || (serverType == ServerType.SONARCLOUD && (serverUrl == null || SonarLintUtils.equalsIgnoringTrailingSlash(serverUrl, SONARCLOUD_URL)));
  }

  /**
   * CodeScan: uses the server address typed in the wizard. A CodeScan server, including a self-hosted one on its own domain,
   * becomes a cloud connection, because it has organizations. This can ask the server, so never call it on the UI thread.
   */
  public WizardModel useServer(String serverUrl) {
    var address = serverUrl.trim();
    while (address.endsWith("/")) {
      address = address.substring(0, address.length() - 1);
    }
    this.serverUrl = address;
    serverType = SonarLintUtils.isSonarCloudAlias(address) ? ServerType.SONARCLOUD : ServerType.SONARQUBE;
    return this;
  }

  public boolean isNotificationsSupported() {
    return notificationsSupported;
  }

  public WizardModel setNotificationsSupported(boolean notificationsSupported) {
    this.notificationsSupported = notificationsSupported;
    return this;
  }

  public void queryIfNotificationsSupported() throws Exception {
    final var partialConnection = createConnectionWithoutOrganization();
    var task = new CheckNotificationsSupportedTask(partialConnection);
    ProgressManager.getInstance().run(task);
    if (task.getException() != null) {
      throw task.getException();
    }
    setNotificationsSupported(task.notificationsSupported());
  }

  public void queryOrganizations() throws Exception {
    if (isSonarCloud()) {
      final ServerConnection partialConnection = createConnectionWithoutOrganization();
      final var task = buildAndRunGetOrganizationsTask(partialConnection);
      setOrganizationList(task.organizations());
      final var presetOrganizationKey = getOrganizationKey();
      if (presetOrganizationKey != null) {
        addPresetOrganization(partialConnection, task, presetOrganizationKey);
      }
      if (getOrganizationKey() == null && task.organizations().size() == 1) {
        // if there is only one organization, we can preselect it
        setOrganizationKey(task.organizations().iterator().next().getKey());
      }
    }
  }

  private static GetOrganizationsTask buildAndRunGetOrganizationsTask(ServerConnection partialConnection) throws Exception {
    var task = new GetOrganizationsTask(partialConnection);
    ProgressManager.getInstance().run(task);
    if (task.getException() != null) {
      throw task.getException();
    }
    return task;
  }

  private void addPresetOrganization(ServerConnection partialConnection, GetOrganizationsTask task, String presetOrganizationKey) {
    // the previously configured organization might not be in the list. If that's the case, fetch it and add it to the list.
    var orgExists = task.organizations().stream().anyMatch(o -> o.getKey().equals(presetOrganizationKey));
    if (!orgExists) {
      var getOrganizationTask = new GetOrganizationTask(partialConnection, presetOrganizationKey);
      ProgressManager.getInstance().run(getOrganizationTask);
      final var fetchedOrganization = getOrganizationTask.organization();
      if (getOrganizationTask.getException() != null || fetchedOrganization == null) {
        // ignore and reset organization
        setOrganizationKey(null);
      } else {
        getOrganizationList().add(fetchedOrganization);
      }
    }
  }

  public boolean isNotificationsDisabled() {
    return notificationsDisabled;
  }

  public WizardModel setNotificationsDisabled(boolean notificationsDisabled) {
    this.notificationsDisabled = notificationsDisabled;
    return this;
  }

  public boolean isProxyEnabled() {
    return proxyEnabled;
  }

  public WizardModel setProxyEnabled(boolean proxyEnabled) {
    this.proxyEnabled = proxyEnabled;
    return this;
  }

  public List<OrganizationDto> getOrganizationList() {
    return organizationList;
  }

  public WizardModel setOrganizationList(List<OrganizationDto> organizationList) {
    this.organizationList = organizationList;
    return this;
  }

  public boolean isOrganizationStepComplete(@Nullable OrganizationDto selectedOrganization) {
    // even if skipped in the SQ context, this step is still checked for completion.
    // CodeScan: with zero or one organization there is nothing to choose, so Next is allowed. With zero, the connection is
    // saved without an organization, which the backend skips (BackendService) until one is added with "Select another organization".
    return !isSonarCloud() || organizationList.size() <= 1 || selectedOrganization != null;
  }

  @CheckForNull
  public String getServerUrl() {
    return serverUrl;
  }

  public WizardModel setServerUrl(@Nullable String serverUrl) {
    this.serverUrl = serverUrl;
    return this;
  }

  @CheckForNull
  public String getToken() {
    return token;
  }

  public WizardModel setToken(@Nullable String token) {
    this.token = token;
    return this;
  }

  @CheckForNull
  public String getLogin() {
    return login;
  }

  public WizardModel setLogin(@Nullable String login) {
    this.login = login;
    return this;
  }

  @CheckForNull
  public char[] getPassword() {
    return password;
  }

  public WizardModel setPassword(@Nullable char[] password) {
    this.password = password;
    return this;
  }

  @CheckForNull
  public String getName() {
    return name;
  }

  public WizardModel setName(String name) {
    this.name = name;
    return this;
  }

  @CheckForNull
  public String getOrganizationKey() {
    return organizationKey;
  }

  public WizardModel setOrganizationKey(@Nullable String organization) {
    this.organizationKey = organization;
    return this;
  }

  public ServerConnection createConnectionWithoutOrganization() {
    return createConnection(null);
  }

  public ServerConnection createConnection() {
    return createConnection(organizationKey);
  }

  private ServerConnection.Builder createUnauthenticatedConnection(@Nullable String organizationKey) {
    var builder = ServerConnection.newBuilder()
      .setOrganizationKey(organizationKey)
      .setEnableProxy(proxyEnabled)
      .setName(name);

    if (serverType == ServerType.SONARCLOUD) {
      // CodeScan: a cloud connection keeps its own address; the default cloud address is only the fallback
      builder.setHostUrl(SonarLintUtils.isBlank(serverUrl) ? SONARCLOUD_URL : serverUrl);
    } else {
      builder.setHostUrl(serverUrl);
    }
    builder.setDisableNotifications(notificationsDisabled);
    return builder;
  }

  private ServerConnection createConnection(@Nullable String organizationKey) {
    var builder = createUnauthenticatedConnection(organizationKey);

    if (token != null) {
      builder.setToken(token)
        .setLogin(null)
        .setPassword(null);
    } else {
      builder.setToken(null)
        .setLogin(login)
        .setPassword(new String(password));
    }
    return builder.build();
  }
}
