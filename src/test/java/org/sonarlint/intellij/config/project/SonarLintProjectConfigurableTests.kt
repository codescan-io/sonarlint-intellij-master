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
package org.sonarlint.intellij.config.project

import com.intellij.ide.DataManager
import com.intellij.openapi.actionSystem.impl.SimpleDataContext
import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.options.Configurable
import com.intellij.openapi.options.ConfigurableGroup
import com.intellij.testFramework.replaceService
import java.util.concurrent.TimeUnit
import org.assertj.core.api.Assertions.assertThat
import org.jetbrains.concurrency.Promise
import org.jetbrains.concurrency.resolvedPromise
import org.junit.jupiter.api.Test
import org.mockito.Mockito.doReturn
import org.mockito.Mockito.mock
import org.mockito.Mockito.spy
import org.mockito.Mockito.`when`
import org.sonarlint.intellij.AbstractSonarLintLightTests
import org.sonarlint.intellij.config.global.SonarLintGlobalConfigurable

class SonarLintProjectConfigurableTests : AbstractSonarLintLightTests() {

    @Test
    fun opening_the_page_does_not_wait_for_a_slow_search_of_all_settings_pages() {
        // a settings dialog whose page tree takes 2 s to walk, as when another plugin builds its pages on demand
        val slowGroup = mock(ConfigurableGroup::class.java)
        `when`(slowGroup.configurables).thenAnswer {
            Thread.sleep(2_000)
            arrayOf<Configurable>()
        }
        val slowSettings = object : com.intellij.openapi.options.ex.Settings(listOf(slowGroup)) {
            override fun selectImpl(configurable: Configurable?): Promise<in Any> = resolvedPromise<Any?>(null)
            override fun getConfigurableWithInitializedUiComponentImpl(configurable: Configurable, initializeUiComponentIfNotYet: Boolean) = configurable
            override fun checkModifiedImpl(configurable: Configurable) = Unit
            override fun setSearchText(option: String?) = Unit
        }
        val dataManager = spy(DataManager.getInstance())
        doReturn(resolvedPromise(SimpleDataContext.getSimpleContext(com.intellij.openapi.options.ex.Settings.KEY, slowSettings)))
            .`when`(dataManager).dataContextFromFocusAsync
        ApplicationManager.getApplication().replaceService(DataManager::class.java, dataManager, testRootDisposable)

        val configurable = SonarLintProjectConfigurable(project)
        configurable.createComponent()
        try {
            val start = System.nanoTime()
            configurable.reset()
            val waitedMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - start)

            assertThat(waitedMs).isLessThan(1_000)
        } finally {
            configurable.disposeUIResources()
        }
    }

    @Test
    fun connections_being_edited_on_the_global_page_are_known_while_that_page_is_open() {
        val globalPage = SonarLintGlobalConfigurable()
        globalPage.createComponent()
        try {
            assertThat(SonarLintGlobalConfigurable.getConnectionsBeingEdited()).isNotNull
        } finally {
            globalPage.disposeUIResources()
        }

        assertThat(SonarLintGlobalConfigurable.getConnectionsBeingEdited()).isNull()
    }
}
