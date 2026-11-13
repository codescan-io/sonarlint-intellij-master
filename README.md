CodeScan IntelliJ Plugin
=========================

CodeScan is an IDE extension that helps you detect and fix quality issues as you write code.
Like a spell checker, CodeScan squiggles flaws so they can be fixed before committing code.

This is CodeScan's fork of [SonarLint for IntelliJ](https://github.com/SonarSource/sonarlint-intellij), currently based on
upstream version 10.14.1. It supports IntelliJ IDEA only.

Useful links
------------

- [CodeScan website](https://www.codescan.io)

How to install
--------------

You can install CodeScan from the [JetBrains Plugin Repository](https://plugins.jetbrains.com/plugin/16087-codescan), directly available in the IDE preferences.

Questions and Feedback?
--------------------------

Contact CodeScan support at support@codescan.io.

How to build
------------

The plugin uses a CodeScan build of sonarlint-core (`sonarlint-core` in `gradle/libs.versions.toml`), which is not published publicly.
Install it into your local Maven repository first, from the CodeScan fork of sonarlint-core:

    ./mvnw install -DskipTests

Other CodeScan libraries come from AWS CodeArtifact; see the comment above the repositories in `build.gradle.kts`. Then:

    ./gradlew buildPlugin

Note that the above won't run tests and checks. To do that too, run:

    ./gradlew check buildPlugin

For the complete list of tasks, see:

    ./gradlew tasks

How to run UI tests
-------------------

    ./gradlew :its:runIdeForUiTests &

The above will start an IDE instance with the CodeScan plugin. Wait for the UI robot server to start, then run the ITs:

    ./gradlew :its:check

Finally, close the IDE.

To test against a specific version of IntelliJ, the `ijVersion` property can be used, e.g.:

    ./gradlew :its:runIdeForUiTests  -PijVersion=IC-2019.3 &

To test against a specific IDE, the `runIdeDirectory` property can be used as such:

    ./gradlew :its:runIdeForUiTests -PrunIdeDirectory=<IDE_PATH> &

Please note that the IDE must be in the foreground while tests are executed.

How to debug UI tests
---------------------

If you want to debug what happens on the test side, you can simply launch the test in debug mode from the IDE.

If you want to debug what happens in the CodeScan plugin, you can open the project in IntelliJ, and run the
`its:runIdeForUiTests` task in debug mode (for example from the Gradle panel on the right).


How to debug SLOOP
------------------

If you want to debug SLOOP:

* open the Run configuration you are using to launch the IDE (`runIde` or `its:runIdeForUiTests`)
* Add an environment variable: `SONARLINT_JVM_OPTS` with the value `-agentlib:jdwp=transport=dt_socket,address=8080,server=y,suspend=n`
* Run the task
* Open the sonarlint-core project and click `Run` > `Attach to process`
* Choose the SLOOP running process

If you want to plug the debugger as soon as SLOOP is started, you can modify the command above by having `suspend=y`.
This will wait for the debugger to attach the process before starting SLOOP.

How to develop in IntelliJ
--------------------------

Import the project as a Gradle project.

Note: whenever you change a Gradle setting (for example in `build.gradle.kts`),
don't forget to **Refresh all Gradle projects** in the **Gradle** toolbar.

To run an IntelliJ instance with the plugin installed, execute the Gradle task `runIde` using the command line,
or the **Gradle** toolbar in IntelliJ, under `Tasks/intellij`.
The instance files are stored under `build/idea-sandbox`.

To run against a specific IDE, the `runIdeDirectory` property can be used as such:

    ./gradlew :runIde -PrunIdeDirectory=<IDE_PATH>

Keep in mind that the `clean` task will wipe out the content of `build/idea-sandbox`,
so you will need to repeat some setup steps for that instance, such as configuring the JDK.

Whenever you change the dependency version, the previous versions are not deleted from the sandbox, and the JVM might not load the version
that you expect.
As the `clean` task may be inconvenient, an easier workaround is to delete the jars in the sandbox, for example with:

    find build/idea-sandbox/ -name '*.jar' -delete

License
-------

Copyright 2015-2024 SonarSource.

Licensed under the [GNU Lesser General Public License, Version 3.0](http://www.gnu.org/licenses/lgpl.txt)
