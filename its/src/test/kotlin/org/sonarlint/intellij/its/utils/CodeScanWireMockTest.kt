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

import java.net.ConnectException
import java.net.HttpURLConnection
import java.net.URL
import org.assertj.core.api.Assertions.assertThat
import org.assertj.core.api.Assertions.assertThatThrownBy
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Test

// Runs without an IDE: checks the CodeScan copy the connected-mode UI tests talk to.
class CodeScanWireMockTest {

    private val port = System.getProperty("its.wiremock.port", "18089")

    @AfterEach
    fun stopCopy() {
        CodeScanWireMock.stop()
    }

    @Test
    fun `answers like CodeScan from the recordings`() {
        CodeScanWireMock.start()

        val (code, body) = get("/api/system/status", CodeScanWireMock.TOKEN)

        assertThat(code).isEqualTo(200)
        assertThat(body).contains("\"status\":\"UP\"")
    }

    @Test
    fun `accepts the test token and refuses the made-up one`() {
        CodeScanWireMock.start()

        assertThat(get("/api/authentication/validate?format=json", CodeScanWireMock.TOKEN).second).isEqualTo("{\"valid\":true}")
        assertThat(get("/api/authentication/validate?format=json", "REDACTED").second).isEqualTo("{\"valid\":false}")
    }

    @Test
    fun `refuses the IP allowlist token with the server's 403 message`() {
        CodeScanWireMock.start()

        val (code, body) = get("/api/authentication/validate?format=json", CodeScanWireMock.IP_ALLOWLIST_BLOCKED_TOKEN)

        assertThat(code).isEqualTo(403)
        assertThat(body).isEqualTo("{\"errors\":[{\"msg\":\"${CodeScanWireMock.IP_ALLOWLIST_BLOCK_MESSAGE}\"}]}")
        assertThat(get("/api/authentication/validate?format=json", CodeScanWireMock.TOKEN).second).isEqualTo("{\"valid\":true}")
    }

    @Test
    fun `tells which addresses the IDE asked for`() {
        CodeScanWireMock.start()

        get("/api/qualityprofiles/search.protobuf?project=${CodeScanWireMock.PROJECT_KEY}", CodeScanWireMock.TOKEN)

        assertThat(CodeScanWireMock.wasCalled("/api/qualityprofiles/search.protobuf", "project", CodeScanWireMock.PROJECT_KEY)).isTrue()
        assertThat(CodeScanWireMock.wasCalled("/api/qualityprofiles/search.protobuf", "project", "another-project")).isFalse()
    }

    @Test
    fun `stops answering once stopped`() {
        CodeScanWireMock.start()
        CodeScanWireMock.stop()

        assertThatThrownBy { get("/api/system/status", CodeScanWireMock.TOKEN) }.isInstanceOf(ConnectException::class.java)
        assertThat(CodeScanWireMock.wasCalled("/api/system/status", "any", "any")).isFalse()
    }

    private fun get(pathAndQuery: String, token: String): Pair<Int, String> {
        val connection = URL("http://localhost:$port$pathAndQuery").openConnection() as HttpURLConnection
        connection.connectTimeout = 5000
        connection.readTimeout = 10000
        connection.setRequestProperty("Authorization", "Bearer $token")
        try {
            val code = connection.responseCode
            val stream = if (code < 400) connection.inputStream else connection.errorStream
            return code to (stream?.bufferedReader()?.use { it.readText() } ?: "")
        } finally {
            connection.disconnect()
        }
    }
}
