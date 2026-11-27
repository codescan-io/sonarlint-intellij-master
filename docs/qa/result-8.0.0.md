# Result: CodeScan plugin 8.0.0-CODESCAN (upstream catch-up)

Date: 2026-11-14. Plan: `docs/superpowers/plans/2026-11-13-intellij-upstream-catchup.md` (in the top-level folder), Task 9.

Short version: the plugin now builds on upstream 10.14.1 with every CodeScan change kept. In the real-IDE runs on IntelliJ 2023.1.7 and 2026.1.5, none of the "slow operation" errors came from CodeScan code. The one step still open is the 10-minute manual check by a person on the built zip.

## What changed

Merged in this order:

| Task | What it did |
|---|---|
| T1 | QA scripts (`scripts/qa/`): a Docker run of a real IDE, plus a scanner for the IDE log. |
| T2 | CodeScan's own changes were written down and are checked by `scripts/qa/check-customizations.sh` (12 checks). |
| T5 | Upstream plugin 10.14.1.80220 on top of CodeScan's changes. Rider and CLion support removed. |
| T5b | Error reports go to CodeScan's `/_codescan/errors/intellij`. Help links go to https://knowledgebase.autorabit.com/. |
| T6 | IntelliJ Gradle add-on 2.7.2 and Gradle 8.14.3. Compiled against IC 2023.1.7. since-build 231, no until-build. |
| T8 step 1 | Upstream fixes for slow operations on the UI thread: Project Settings no longer searches every settings page, rule highlights in Settings no longer block, and the before-commit check offers Commit Anyway / Abort after 60 seconds. |
| T7 | The real-IDE test loop in Docker (`scripts/qa/run-ide-scenarios.sh`). Pressing Space on a rule in Settings > Rules now works. |
| T8 steps 2-3 | The Security Hotspots tab no longer shows a false "service stopped working" (at start and after a restart). The bundled Kotlin analyzer is now 3.0.1.6889, so Kotlin works on IntelliJ 2026.1 (Java 25) for projects not bound to a server. |
| Core | In the `sonarlint-core` repo, branch `intellij-upstream-catchup`: upstream 10.12.1.79852 with CodeScan changes, and sonar-plugin-api 10.14.1-CODESCAN (variable type on issues). Analysis settings mask passwords and tokens in the log. |

Version: `version=8.0.0-CODESCAN` in `gradle.properties`. The core version is `10.12.1-CODESCAN`.

## Errors before and after

Before (Task 1, `docs/qa/baseline-7.2.3.md`, top-level folder): the old logs on real machines (7.3.x plugin) held 46 slow-operation or thread-access errors that came from CodeScan code. 44 were "read access" errors in `LiveFinding.isValid`, `CodeAnalyzerRestarter.getPsi` and `FindingDetailsPanel.show`. 2 were slow operations when opening Project Settings. The short Docker run on the old plugin showed 0, because it was only 5 minutes and light.

After (Task 7, real IDE in Docker with the slow-operation switch on):

| IDE | Slow operations from CodeScan code |
|---|---|
| IntelliJ 2023.1.7 | 0 |
| IntelliJ 2026.1.5 | 0 |

The "before" and "after" numbers do not measure the same thing. The old logs are weeks of real use. The new runs are scripted loops of minutes. The Docker run of the old plugin (0) is the fair comparison, and it did not show the problem either. What backs the claim are the fixes for the exact call sites in the old logs, plus the new runs showing 0.

## Plugin verifier

The JetBrains verifier passed on IC-231 (2023.1.7), IC-241, IC-243, IC-252 and IU-261 (T6). It was not re-run in Task 9.

## Checks run in Task 9

| Check | Result |
|---|---|
| `./gradlew buildPlugin` (JDK 17) | Passed. Zip: `build/distributions/CodeScan-8.0.0-CODESCAN.zip` (197.5 MB). |
| `bash scripts/qa/check-customizations.sh --zip build/distributions/CodeScan-8.0.0-CODESCAN.zip` | Exit 0, 12 checks passed, 0 failed. The zip check confirms `plugin.xml` says version 8.0.0-CODESCAN. |

Test counts: the unit-test and UI-test suites were not re-run in Task 9 (by request). The results of the earlier tasks stand as they were recorded when each task was merged.

## Not done, or open

1. **The 10-minute manual check (plan Task 9 Step 2) is not done.** A person has to do it on the built zip: install from disk on IntelliJ 2026.1 and 2023.1, connect to the real CodeScan org, bind a project, see server issues, open an issue in the browser, analyse an Apex file.
2. **Kotlin in projects bound to CodeScan on IntelliJ 2026.1 finds nothing.** The server sends sonar-kotlin 2.21. Left for later by decision.
3. **ConnectedAnalysisTests' unbind check is flaky on 2023.1.7.** It is an old timing race, and only the tab text is affected.
4. **CodeScan's `/errors/intellij` server endpoint requires login**, so anonymous error reports may be refused. This is for the server team. The live test is still pending.
5. **UI tests not run:** ConfigurationTests, OpenInIdeTests and PLSQLTest. They need a licensed SonarQube.
6. **A full run of the IDE loop needs `--indexing-project`**, or the real-indexing scenario is skipped.
7. **An old CodeScan token is in the core repo's git history.** It should be revoked (the user has been told).
8. **`-Dsonarlint.debug.rpc=true` writes tokens to the `~/.sonarlint` logs.** This is upstream behaviour.
9. **CI file `.cirrus.yml`:** only stale names and versions were changed (`runPluginVerifier` to `verifyPlugin`, 2022.3.1 to 2023.1.7, Gradle 8.9 to 8.14.3). It still points at SonarSource infrastructure, still lists Rider and CLion matrix entries, and `.cirrus/Dockerfile` still downloads IC 2022.3.1. CI was not redesigned and was not run.
