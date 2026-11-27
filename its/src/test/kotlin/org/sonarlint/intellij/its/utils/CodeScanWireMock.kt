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
package org.sonarlint.intellij.its.utils

import com.github.tomakehurst.wiremock.WireMockServer
import com.github.tomakehurst.wiremock.client.WireMock.equalTo
import com.github.tomakehurst.wiremock.client.WireMock.getRequestedFor
import com.github.tomakehurst.wiremock.client.WireMock.urlPathEqualTo
import com.github.tomakehurst.wiremock.core.WireMockConfiguration.options
import com.github.tomakehurst.wiremock.stubbing.StubMapping
import java.nio.file.Files
import java.nio.file.Paths
import kotlin.io.path.extension
import kotlin.io.path.name
import kotlin.io.path.readText

/**
 * A copy of CodeScan for the UI tests: WireMock answering with the recordings in src/test/resources/codescan-wiremock
 * (see the README there). The UI-test IDE uses it as its CodeScan address (its/build.gradle.kts, wiremockPort).
 */
object CodeScanWireMock {
    const val ORGANIZATION = "test-org"
    const val PROJECT_KEY = "test-project"

    // The recordings accept any token except the word REDACTED, which they answer as invalid.
    const val TOKEN = "ui-test-token"

    // CodeScan refuses this token as if the organization's IP allowlist blocked the caller (72-auth-ip-allowlist-blocked.json).
    const val IP_ALLOWLIST_BLOCKED_TOKEN = "ip-allowlist-blocked-token"
    const val IP_ALLOWLIST_BLOCK_MESSAGE =
        "Access to organization 'salil-nov-24' is blocked by its IP allowlist. Your IP address is 203.0.113.7."

    private val port = System.getProperty("its.wiremock.port", "18089").toInt()
    private var server: WireMockServer? = null

    @Synchronized
    fun start() {
        if (server?.isRunning == true) {
            return
        }
        val newServer = WireMockServer(options().bindAddress("127.0.0.1").port(port))
        newServer.start()
        loadRecordings(newServer)
        server = newServer
    }

    @Synchronized
    fun stop() {
        server?.let { running ->
            val unmatched = running.findAllUnmatchedRequests()
            // The list shows which recordings are missing when a CodeScan feature starts calling a new address.
            unmatched.forEach { println("CodeScan copy had no answer for: ${it.method} ${it.url}") }
            running.stop()
        }
        server = null
    }

    fun wasCalled(path: String, queryParameter: String, value: String): Boolean {
        val running = server ?: return false
        return running.findAll(getRequestedFor(urlPathEqualTo(path)).withQueryParam(queryParameter, equalTo(value))).isNotEmpty()
    }

    private fun loadRecordings(target: WireMockServer) {
        val folder = Paths.get(requireNotNull(javaClass.getResource("/codescan-wiremock")) { "recordings not on the test classpath" }.toURI())
        val files = Files.list(folder).use { list -> list.filter { it.extension == "json" }.sorted().toList() }
        check(files.size > 50) { "expected the CodeScan recordings in $folder, found ${files.size} files" }
        files.forEach { target.addStubMapping(StubMapping.buildFrom(it.readText())) }
        println("CodeScan copy on port $port answers with ${files.size} recordings from ${folder.name}")
    }
}
