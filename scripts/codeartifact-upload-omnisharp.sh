#!/usr/bin/env bash
#
# Uploads the OmniSharp zips to AWS CodeArtifact as
# com.villagechief.codescan.thirdparty:omnisharp:<version> with classifiers mono, net472, net6,
# which is where build.gradle.kts resolves them from. Needs an AWS profile that can publish.
#
#   AWS_PROFILE=Codescan-Devteam-261140574810 ./scripts/codeartifact-upload-omnisharp.sh <dir-with-zips> [version]
#
# <dir-with-zips> must contain omnisharp-<version>-mono.zip, -net472.zip and -net6.zip.

set -euo pipefail

zip_dir="$(cd "${1:?usage: $0 <dir-with-zips> [version]}" && pwd)"
version="${2:-1.39.6}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mvn_bin="${MVN_BIN:-$(command -v mvn || echo "$script_dir/../../sonarlint-core/mvnw")}"

export CODEARTIFACTORY_URL="${CODEARTIFACTORY_URL:-https://autorabit-artifacts-domain-261140574810.d.codeartifact.us-east-1.amazonaws.com}"
exports="$("$script_dir/codeartifact-bootstrap.sh")"
eval "$exports"

for c in mono net472 net6; do
  [[ -f "$zip_dir/omnisharp-$version-$c.zip" ]] || { echo "ERROR: missing $zip_dir/omnisharp-$version-$c.zip" >&2; exit 1; }
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cat >"$work/settings.xml" <<'EOF'
<settings><servers><server>
  <id>codeartifact-release</id><username>aws</username><password>${env.CODEARTIFACT_AUTH_TOKEN}</password>
</server></servers></settings>
EOF
cat >"$work/pom.xml" <<EOF
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.villagechief.codescan.thirdparty</groupId>
  <artifactId>omnisharp</artifactId>
  <version>$version</version>
  <packaging>pom</packaging>
  <description>OmniSharp server builds bundled into the CodeScan IntelliJ plugin</description>
</project>
EOF

# The pom is the main artifact; the zips are attached to it by classifier.
"$mvn_bin" -B -q -s "$work/settings.xml" org.apache.maven.plugins:maven-deploy-plugin:3.1.1:deploy-file \
  -DrepositoryId=codeartifact-release \
  -Durl="$CODEARTIFACT_MAVEN_URL" \
  -Dfile="$work/pom.xml" \
  -DpomFile="$work/pom.xml" \
  -Dfiles="$zip_dir/omnisharp-$version-mono.zip,$zip_dir/omnisharp-$version-net472.zip,$zip_dir/omnisharp-$version-net6.zip" \
  -Dclassifiers=mono,net472,net6 \
  -Dtypes=zip,zip,zip

echo "Uploaded com.villagechief.codescan.thirdparty:omnisharp:$version (mono, net472, net6)"
