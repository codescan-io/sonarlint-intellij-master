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
package org.sonarlint.intellij.codescan

import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths
import kotlin.io.path.extension
import kotlin.io.path.name
import kotlin.io.path.readText
import org.assertj.core.api.Assertions.assertThat
import org.junit.jupiter.api.Test
import org.sonarlint.intellij.config.global.ServerConnection
import org.sonarlint.intellij.documentation.SonarLintDocumentation
import org.sonarlint.intellij.telemetry.LinkTelemetry
import org.sonarlint.intellij.ui.AbstractIssuesPanel
import org.sonarlint.intellij.ui.ReportPanel
import org.sonarlint.intellij.ui.SonarLintLogPanel
import org.sonarlint.intellij.ui.SonarLintToolWindowFactory

/**
 * Text the user can see says CodeScan, not the names of SonarSource products.
 * The check reads the source files, because most of this text only shows up in dialogs, notifications and the log console.
 */
class CodeScanBrandingTests {

    @Test
    fun textInCodeNamesCodeScan() {
        val found = codeLiterals()
            .filter { (where, value) -> namesSonarProduct(value) && value !in ALLOWED[where.substringBefore(':')].orEmpty() }
            .map { (where, value) -> "$where: ${value.take(120)}" }

        assertThat(found).`as`("strings in the code that name a SonarSource product").isEmpty()
    }

    /** Strings as "File.kt:line" to text; placeholder contents are listed separately and cut from the outer string so if/else choices do not read as one sentence. */
    private fun codeLiterals(): List<Pair<String, String>> = sourceFiles().flatMap { file ->
        val text = file.readText()
        TOKEN.findAll(text)
            .filter { it.value.startsWith("\"") }
            .flatMap { match ->
                val line = lineOf(text, match.range.first)
                val value = literalValue(match.value)
                val nested = PLACEHOLDER.findAll(value).flatMap { STRING.findAll(it.value) }.map { literalValue(it.value) }
                (sequenceOf(value.replace(PLACEHOLDER) { "\${}" }) + nested).map { "${file.name}:$line" to it }
            }
            .toList()
    }

    @Test
    fun renamedTextStillReadsAsASentence() {
        // swapping every product name for CodeScan turned "SonarQube for IDE complements SonarQube Cloud" into "CodeScan complements CodeScan"
        val found = codeLiterals().filter { (_, value) -> REPEATED_NAME.containsMatchIn(value) || SONAR_MARKETING.containsMatchIn(value) }
            .map { (where, value) -> "$where: ${value.take(120)}" }
        val sameBothWays = sourceFiles().flatMap { file ->
            val text = file.readText()
            SAME_BOTH_WAYS.findAll(text).map { "${file.name}:${lineOf(text, it.range.first)}: ${it.value}" }.toList()
        }

        assertThat(found + sameBothWays).`as`("text that names CodeScan twice in a row, repeats SonarSource sales claims, or picks between two identical texts").isEmpty()
    }

    @Test
    fun productLinksGoToCodeScan() {
        // CodeScan has no documentation pages matching SonarSource's yet, so only the product and sign-up links change
        val productLinks = LinkTelemetry.values().filterNot { it.url.startsWith(SonarLintDocumentation.Intellij.BASE_DOCS_URL) }

        assertThat(productLinks).isNotEmpty()
        productLinks.forEach { link -> assertThat(link.url).`as`(link.name).startsWith("https://www.codescan.io") }
    }

    @Test
    fun textInFormsAndPluginDescriptorsNamesCodeScan() {
        val forms = sourceFiles("form").flatMap { file -> textIn(file, FORM_TEXT) }
        val descriptors = Files.list(Paths.get("src/main/resources/META-INF")).use { paths -> paths.filter { it.extension == "xml" }.toList() }
            .flatMap { file -> textIn(file, DESCRIPTOR_TEXT) }

        assertThat(forms + descriptors).`as`("form and plugin descriptor text that names a SonarSource product").isEmpty()
    }

    @Test
    fun serverProductNameIsCodeScan() {
        // P7 makes every CodeScan server a cloud connection, so both kinds must read the same
        listOf("https://app.codescan.io", "https://codescan.example.invalid").forEach { url ->
            val connection = ServerConnection.newBuilder().setName("c").setHostUrl(url).setToken("t").build()

            assertThat(connection.productName).`as`(url).isEqualTo("CodeScan")
        }
    }

    @Test
    fun toolWindowToolbarsReportTheToolWindowAsTheirPlace() {
        // AnalysisSubmitter shows a run started from the tool window in the Current File tab only when the toolbar place equals
        // the tool window id, so renaming one without the others sends the results to the Report tab instead
        listOf(AbstractIssuesPanel::class.java, ReportPanel::class.java, SonarLintLogPanel::class.java).forEach { panel ->
            val place = panel.getDeclaredField("ID").apply { isAccessible = true }.get(null)

            assertThat(place).`as`(panel.simpleName).isEqualTo(SonarLintToolWindowFactory.TOOL_WINDOW_ID)
        }
    }

    private fun textIn(file: Path, pattern: Regex): List<String> {
        val text = file.readText()
        return pattern.findAll(text)
            .map { it.groupValues.drop(1).firstOrNull { group -> group.isNotEmpty() }.orEmpty() to it }
            .filter { (value, _) -> namesSonarProduct(value) }
            .map { (value, match) -> "${file.name}:${lineOf(text, match.range.first)}: $value" }
            .toList()
    }

    private fun sourceFiles(vararg extensions: String = arrayOf("java", "kt")): List<Path> =
        listOf("src/main/java", "common/src/main/java", "git/src/main/java")
            .map { Paths.get(it) }
            .filter { Files.isDirectory(it) }
            .flatMap { root -> Files.walk(root).use { paths -> paths.filter { it.extension in extensions }.toList() } }

    private fun literalValue(token: String) = if (token.startsWith(TRIPLE_QUOTE)) token.removeSurrounding(TRIPLE_QUOTE) else token.removeSurrounding("\"")

    private fun namesSonarProduct(value: String): Boolean {
        // pieces of a link's query string, such as "?title=Error+in+SonarQube+for+IntelliJ", are part of an address, not text
        if ((value.startsWith("?") || value.startsWith("&")) && value.contains("=")) {
            return false
        }
        return PRODUCT.containsMatchIn(value.replace(LINK, ""))
    }

    private fun lineOf(text: String, offset: Int) = text.substring(0, offset).count { it == '\n' } + 1

    companion object {
        private const val TRIPLE_QUOTE = "\"\"\""

        // a product name on its own; "SonarLint.someKey" is a stored setting name and "SonarLintPlugin" a class name
        private val PRODUCT = Regex("""\b(SonarQube|SonarCloud|SonarLint|SonarSource)\b(?!\.\w)""")
        private val LINK = Regex("""[a-zA-Z]+://[^\s"'<>\\]*""")

        // comments, then Kotlin raw strings and Java text blocks, then plain strings, then characters, so a quote inside one is not read as the start of another.
        // A plain string may hold a Kotlin "${...}" placeholder with its own quoted strings, such as "to ${if (cloud) "A" else "B"} now".
        private const val PLACEHOLDER_PATTERN = """\$\{[^{}\n]*\}"""
        private val TOKEN = Regex("""//[^\n]*|/\*[\s\S]*?\*/|""" + TRIPLE_QUOTE + """[\s\S]*?""" + TRIPLE_QUOTE +
            """|"(?:""" + PLACEHOLDER_PATTERN + """|[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'""")
        private val PLACEHOLDER = Regex(PLACEHOLDER_PATTERN)
        private val STRING = Regex(""""(?:[^"\\\n]|\\.)*"""")

        private val REPEATED_NAME = Regex("""\bCodeScan\b\W+(?:\w+\W+){0,4}?CodeScan\b""")
        private val SONAR_MARKETING = Regex("""entirely free|for free|Community Build|self-managed|Software-as-a-Service|Download CodeScan""", RegexOption.IGNORE_CASE)

        private val SAME_BOTH_WAYS = Regex("""[)?]\s*("[^"\n]*")\s*(?:else|:)\s*\1(?!\s*\+)""")
        private val FORM_TEXT = Regex("<(?:text|toolTipText)\\s+value=\"([^\"]*)\"|\\btitle=\"([^\"]*)\"")

        // change notes are release history, handled with the README and NOTICE (P30), so only attributes are read here
        private val DESCRIPTOR_TEXT = Regex("\\b(?:text|description|displayName)=\"([^\"]*)\"")

        private val ALLOWED = mapOf(
            // the product name reported to telemetry; P31 decides what it becomes
            "BackendService.kt" to setOf("SonarLint IntelliJ"),
        )
    }
}
