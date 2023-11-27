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
package org.sonarlint.intellij.finding.persistence;

import com.intellij.openapi.vfs.VirtualFile;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class PathStoreKeyValidatorTests {
  private VirtualFile projectBaseDir = mock(VirtualFile.class);
  PathStoreKeyValidator validator = new PathStoreKeyValidator(projectBaseDir);
  private VirtualFile file = mock(VirtualFile.class);

  @BeforeEach
  void setUp() {
    when(projectBaseDir.findFileByRelativePath("file1")).thenReturn(file);
  }

  @Test
  void should_validate_if_file_valid() {
    when(file.isValid()).thenReturn(true);
    assertThat(validator.apply("file1")).isTrue();
  }

  @Test
  void should_not_validate_if_file_invalid() {
    when(file.isValid()).thenReturn(false);
    assertThat(validator.apply("file1")).isFalse();
  }

  @Test
  void should_not_validate_if_file_not_found() {
    assertThat(validator.apply("file2")).isFalse();
  }

}
