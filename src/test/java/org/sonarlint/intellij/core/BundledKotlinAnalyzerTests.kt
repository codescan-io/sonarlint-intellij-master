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
package org.sonarlint.intellij.core

import java.lang.reflect.InvocationTargetException
import java.net.URLClassLoader
import org.assertj.core.api.Assertions.assertThat
import org.junit.jupiter.api.Test
import org.sonarlint.intellij.AbstractSonarLintLightTests

class BundledKotlinAnalyzerTests : AbstractSonarLintLightTests() {

    // CodeScan: IntelliJ 2026.1 runs the analysis service on Java 25. The Kotlin compiler inside older Kotlin analyzers
    // cannot read a Java version of 25 or more ("IllegalArgumentException: 25.0.4"), so Kotlin files got no findings.
    @Test
    fun bundled_kotlin_analyzer_can_read_the_java_25_version() {
        val kotlinAnalyzer = EnabledLanguages.findEmbeddedPlugins().single { it.fileName.toString().startsWith("sonar-kotlin-plugin-") }

        val feature = URLClassLoader(arrayOf(kotlinAnalyzer.toUri().toURL()), ClassLoader.getPlatformClassLoader()).use { loader ->
            val javaVersion = Class.forName("com.intellij.util.lang.JavaVersion", true, loader)
            val parsed = try {
                javaVersion.getMethod("parse", String::class.java).invoke(null, "25.0.4")
            } catch (e: InvocationTargetException) {
                throw AssertionError("${kotlinAnalyzer.fileName} cannot read the Java version 25.0.4", e.cause)
            }
            javaVersion.getField("feature").getInt(parsed)
        }

        assertThat(feature).isEqualTo(25)
    }
}
