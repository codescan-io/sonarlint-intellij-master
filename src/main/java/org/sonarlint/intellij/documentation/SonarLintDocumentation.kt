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
package org.sonarlint.intellij.documentation

object SonarLintDocumentation {

    // CodeScan: SonarSource's documentation does not describe CodeScan, so every help and "Learn more" link opens the
    // AutoRABIT knowledge base. It has no pages matching SonarSource's, so all of them open its start page.
    const val KNOWLEDGE_BASE_URL = "https://knowledgebase.autorabit.com/"

    object Intellij {
        const val BASE_DOCS_URL = KNOWLEDGE_BASE_URL
        const val CONNECTED_MODE_LINK = KNOWLEDGE_BASE_URL
        const val CONNECTED_MODE_SETUP_LINK = KNOWLEDGE_BASE_URL
        const val SECURITY_HOTSPOTS_LINK = KNOWLEDGE_BASE_URL
        const val TAINT_VULNERABILITIES_LINK = KNOWLEDGE_BASE_URL
        const val CLEAN_CODE_LINK = KNOWLEDGE_BASE_URL
        const val SUPPORT_POLICY_LINK = KNOWLEDGE_BASE_URL
        const val FOCUS_ON_NEW_CODE_LINK = KNOWLEDGE_BASE_URL
        const val CONNECTED_MODE_BENEFITS_LINK = KNOWLEDGE_BASE_URL
        const val SHARING_CONNECTED_MODE_CONFIGURATION_LINK = KNOWLEDGE_BASE_URL
        const val TROUBLESHOOTING_CONNECTED_MODE_SETUP_LINK = KNOWLEDGE_BASE_URL
        const val RULE_SECTION_LINK = KNOWLEDGE_BASE_URL
        const val FILE_EXCLUSION_LINK = KNOWLEDGE_BASE_URL
    }

    object SonarQube {
        const val SMART_NOTIFICATIONS = KNOWLEDGE_BASE_URL
    }

    object SonarCloud {
        const val SMART_NOTIFICATIONS = KNOWLEDGE_BASE_URL
    }

    // CodeScan: SonarSource's product, download and sign-up pages do not apply to CodeScan, so every product link opens the CodeScan site
    object Marketing {
        private const val BASE_MARKETING_URL = "https://www.codescan.io"
        const val COMPARE_SERVER_PRODUCTS_LINK = BASE_MARKETING_URL
        const val SONARQUBE_EDITIONS_DOWNLOADS_LINK = BASE_MARKETING_URL
        const val SONARCLOUD_PRODUCT_LINK = BASE_MARKETING_URL
        const val SONARCLOUD_PRODUCT_SIGNUP_LINK = BASE_MARKETING_URL
    }

}
