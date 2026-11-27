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
package org.sonarlint.intellij.util;

import com.google.gson.JsonPrimitive;
import java.util.Collections;
import java.util.IdentityHashMap;
import java.util.Optional;
import java.util.regex.Pattern;
import org.eclipse.lsp4j.jsonrpc.ResponseErrorException;
import org.jetbrains.annotations.Nullable;

/**
 * Recognizes the error CodeScan returns when an organization's IP allowlist refuses the request, so that the IDE can
 * show the server's own message instead of a generic failure.
 */
public final class IpAllowlistBlock {
  public static final String MARKER = "is blocked by its IP allowlist";
  public static final String ADVICE = "Ask an administrator of the organization to add your network to the IP allowlist.";

  /** Limits the walk down a chain of causes, also when the chain loops back on itself. */
  private static final int MAX_CAUSES = 20;
  /** One "msg" entry of the server's JSON error body: {"errors":[{"msg":"..."}]}. */
  private static final Pattern JSON_MSG = Pattern.compile("\"msg\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"");
  /** "Caused by: " and exception class names before the message on a stack trace line. */
  private static final Pattern EXCEPTION_PREFIX = Pattern.compile("^(?:Caused by:\\s*)?(?:(?:[A-Za-z_$][\\w$]*\\.)+[A-Za-z_$][\\w$]*:\\s*)+");

  private IpAllowlistBlock() {
  }

  /** The server's message when this error, or one of its causes, is an IP allowlist block. */
  public static Optional<String> find(@Nullable Throwable error) {
    var seen = Collections.newSetFromMap(new IdentityHashMap<Throwable, Boolean>());
    var current = error;
    for (var step = 0; current != null && step < MAX_CAUSES && seen.add(current); step++) {
      var found = find(current.getMessage());
      if (found.isEmpty() && current instanceof ResponseErrorException) {
        found = findInResponseError((ResponseErrorException) current);
      }
      if (found.isPresent()) {
        return found;
      }
      current = current.getCause();
    }
    return Optional.empty();
  }

  /**
   * The server's message when this text carries an IP allowlist block: a raw JSON error body, a connection check
   * result such as "HTTP Connection failed (403): {...}", an exception message or a printed stack trace.
   */
  public static Optional<String> find(@Nullable String text) {
    if (text == null || !text.contains(MARKER)) {
      return Optional.empty();
    }
    var json = JSON_MSG.matcher(text);
    while (json.find()) {
      var msg = unescapeJson(json.group(1));
      if (msg.contains(MARKER)) {
        return Optional.of(msg.trim());
      }
    }
    for (var line : text.split("\\R")) {
      if (line.contains(MARKER)) {
        return Optional.of(EXCEPTION_PREFIX.matcher(line.trim()).replaceFirst("").trim());
      }
    }
    return Optional.empty();
  }

  /** "headline server-message advice" when the error is an IP allowlist block, otherwise the fallback unchanged. */
  public static String explain(@Nullable Throwable error, String headline, String fallback) {
    return find(error).map(msg -> describe(headline, msg)).orElse(fallback);
  }

  /** "headline server-message advice" when the text carries an IP allowlist block, otherwise the fallback unchanged. */
  public static String explain(@Nullable String text, String headline, String fallback) {
    return find(text).map(msg -> describe(headline, msg)).orElse(fallback);
  }

  public static String withAdvice(String serverMessage) {
    return serverMessage + " " + ADVICE;
  }

  private static String describe(String headline, String serverMessage) {
    return headline + " " + withAdvice(serverMessage);
  }

  /**
   * A request to the backend that failed with an unexpected exception reaches the IDE as "Internal error.", with the
   * backend's stack trace in the error's data.
   */
  private static Optional<String> findInResponseError(ResponseErrorException error) {
    var responseError = error.getResponseError();
    if (responseError == null) {
      return Optional.empty();
    }
    var data = responseError.getData();
    if (data == null) {
      return Optional.empty();
    }
    if (data instanceof JsonPrimitive && ((JsonPrimitive) data).isString()) {
      return find(((JsonPrimitive) data).getAsString());
    }
    return find(String.valueOf(data));
  }

  private static String unescapeJson(String value) {
    var out = new StringBuilder(value.length());
    for (var i = 0; i < value.length(); i++) {
      var c = value.charAt(i);
      if (c != '\\' || i + 1 >= value.length()) {
        out.append(c);
        continue;
      }
      var next = value.charAt(++i);
      switch (next) {
        case 'n':
          out.append('\n');
          break;
        case 't':
          out.append('\t');
          break;
        case 'r':
          out.append('\r');
          break;
        case 'b':
          out.append('\b');
          break;
        case 'f':
          out.append('\f');
          break;
        case 'u':
          if (i + 4 < value.length() && value.substring(i + 1, i + 5).matches("[0-9A-Fa-f]{4}")) {
            out.append((char) Integer.parseInt(value.substring(i + 1, i + 5), 16));
            i += 4;
          } else {
            out.append("\\u");
          }
          break;
        default:
          out.append(next);
      }
    }
    return out.toString();
  }
}
