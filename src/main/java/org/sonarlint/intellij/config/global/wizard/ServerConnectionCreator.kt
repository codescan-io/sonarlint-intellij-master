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
package org.sonarlint.intellij.config.global.wizard

import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.progress.ProgressManager
import org.sonarlint.intellij.config.Settings
import org.sonarlint.intellij.config.global.ServerConnection
import org.sonarlint.intellij.messages.GlobalConfigurationListener
import org.sonarlint.intellij.tasks.BindingStorageUpdateTask

open class ServerConnectionCreator {

    open fun createThroughWizard(serverUrl: String): ServerConnection? {
        val globalSettings = Settings.getGlobalSettings()
        val connectionToCreate = ServerConnection.newBuilder().setHostUrl(serverUrl).setDisableNotifications(false).build()
        val wizard = ServerConnectionWizard.forNewConnection(connectionToCreate, globalSettings.serverNames)
        if (wizard.showAndGet()) {
            val created = wizard.connection
            globalSettings.addServerConnection(created)
            val serverChangeListener = ApplicationManager.getApplication().messageBus.syncPublisher(GlobalConfigurationListener.TOPIC)
            serverChangeListener.changed(globalSettings.serverConnections)
            val task = BindingStorageUpdateTask(created, null)
            ProgressManager.getInstance().run(task.asModal())
            return created
        }
        return null
    }
}
