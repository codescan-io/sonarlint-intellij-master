#!/usr/bin/env bash
#
# Fetches an AWS CodeArtifact authorization token and prints the export statements so they can
# be evaluated into the current shell for local Gradle builds. Requires the AWS CLI and an SSO
# profile with CodeArtifact read access.
#
# No account-specific value is hardcoded here. They all come from CODEARTIFACTORY_URL:
#
#   export CODEARTIFACTORY_URL="https://autorabit-artifacts-domain-261140574810.d.codeartifact.us-east-1.amazonaws.com"
#   export AWS_PROFILE="<your-aws-sso-profile>"
#   eval "$(./scripts/codeartifact-bootstrap.sh)"
#   ./gradlew buildPlugin
#
# CODEARTIFACT_DOMAIN, CODEARTIFACT_DOMAIN_OWNER, CODEARTIFACT_REGION and CODEARTIFACT_REPOSITORY
# override the values derived from CODEARTIFACTORY_URL.

set -uo pipefail

# Derives domain / owner / region / Maven URL from CODEARTIFACTORY_URL and exports them.
codeartifact_resolve() {
  local url="${CODEARTIFACTORY_URL:-}"
  url="${url%/}"

  if [[ "${url#*://}" =~ ^(.+)-([0-9]+)\.d\.codeartifact\.([a-z0-9-]+)\.amazonaws\.com$ ]]; then
    CODEARTIFACT_DOMAIN="${CODEARTIFACT_DOMAIN:-${BASH_REMATCH[1]}}"
    CODEARTIFACT_DOMAIN_OWNER="${CODEARTIFACT_DOMAIN_OWNER:-${BASH_REMATCH[2]}}"
    CODEARTIFACT_REGION="${CODEARTIFACT_REGION:-${BASH_REMATCH[3]}}"
  fi

  if [[ -z "${CODEARTIFACT_DOMAIN:-}" ]] || [[ -z "${CODEARTIFACT_DOMAIN_OWNER:-}" ]]; then
    echo "ERROR: the CodeArtifact domain and owner are not configured." >&2
    echo "Export CODEARTIFACTORY_URL (the Bitbucket repository variable the codescanng pipeline" >&2
    echo "injects), e.g. https://<domain>-<owner>.d.codeartifact.<region>.amazonaws.com, or set" >&2
    echo "CODEARTIFACT_DOMAIN and CODEARTIFACT_DOMAIN_OWNER explicitly." >&2
    return 1
  fi

  CODEARTIFACT_REGION="${CODEARTIFACT_REGION:-${AWS_DEFAULT_REGION:-}}"
  CODEARTIFACT_REPOSITORY="${CODEARTIFACT_REPOSITORY:-codescan-libs-release}"

  # Rebuild the host when only the domain coordinates were supplied, so Maven still gets a URL.
  if [[ -z "$url" ]] && [[ -n "$CODEARTIFACT_REGION" ]]; then
    url="https://${CODEARTIFACT_DOMAIN}-${CODEARTIFACT_DOMAIN_OWNER}.d.codeartifact.${CODEARTIFACT_REGION}.amazonaws.com"
  fi
  CODEARTIFACT_MAVEN_URL="${CODEARTIFACT_MAVEN_URL:-${url:+$url/maven/$CODEARTIFACT_REPOSITORY/}}"

  export CODEARTIFACT_DOMAIN CODEARTIFACT_DOMAIN_OWNER CODEARTIFACT_REGION
  export CODEARTIFACT_REPOSITORY CODEARTIFACT_MAVEN_URL
  if [[ -n "$url" ]]; then
    export CODEARTIFACTORY_URL="$url"
  fi

  # The AWS CLI reads the region and profile from the environment, so no call below repeats
  # --region / --profile.
  if [[ -n "$CODEARTIFACT_REGION" ]]; then
    export AWS_REGION="$CODEARTIFACT_REGION"
    export AWS_DEFAULT_REGION="$CODEARTIFACT_REGION"
  fi
  return 0
}

codeartifact_token() {
  "$1" codeartifact get-authorization-token \
    --domain "$CODEARTIFACT_DOMAIN" \
    --domain-owner "$CODEARTIFACT_DOMAIN_OWNER" \
    --query authorizationToken --output text 2>/dev/null || true
}

codeartifact_bootstrap() {
  local profile="${AWS_PROFILE:-}"
  local auto_login="${AWS_SSO_AUTO_LOGIN:-true}"
  local aws_bin="${AWS_BIN:-$(command -v aws 2>/dev/null || true)}"
  local token

  if [[ -z "$aws_bin" ]] || [[ ! -x "$aws_bin" ]]; then
    echo "ERROR: aws CLI not found at: ${AWS_BIN:-(none)}" >&2
    echo "Tip: set AWS_BIN to the output of 'which aws'." >&2
    return 1
  fi

  codeartifact_resolve || return 1

  token="$(codeartifact_token "$aws_bin")"

  if [[ -z "${token:-}" ]] || [[ "$token" == "None" ]]; then
    if [[ "$auto_login" == "true" ]]; then
      echo "INFO: Unable to get CodeArtifact token; running 'aws sso login${profile:+ --profile $profile}'..." >&2
      if ! "$aws_bin" sso login >&2; then
        echo "ERROR: 'aws sso login' failed." >&2
        return 1
      fi
      token="$(codeartifact_token "$aws_bin")"
    fi
  fi

  if [[ -z "${token:-}" ]] || [[ "$token" == "None" ]]; then
    echo "ERROR: Failed to obtain a CodeArtifact token for domain $CODEARTIFACT_DOMAIN." >&2
    echo "Tip: run: \"$aws_bin\" sso login${profile:+ --profile $profile}" >&2
    return 1
  fi

  export CODEARTIFACT_AUTH_TOKEN="$token"
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  codeartifact_bootstrap "$@" || exit $?
  printf 'export CODEARTIFACT_AUTH_TOKEN=%q\n' "$CODEARTIFACT_AUTH_TOKEN"
  if [[ -n "${CODEARTIFACTORY_URL:-}" ]]; then
    printf 'export CODEARTIFACTORY_URL=%q\n' "$CODEARTIFACTORY_URL"
  fi
  if [[ -n "${CODEARTIFACT_MAVEN_URL:-}" ]]; then
    printf 'export CODEARTIFACT_MAVEN_URL=%q\n' "$CODEARTIFACT_MAVEN_URL"
  fi
fi
