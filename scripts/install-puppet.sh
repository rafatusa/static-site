#!/usr/bin/env bash
# Install the Puppet 8 agent on Ubuntu 22.04 (jammy).
#
# WHY a release package: Ubuntu's base apt repos ship an old, differently-laid-out
# puppet package (/usr/bin/puppet, Puppet 5/7 era). Puppet Labs' own APT repo is
# the supported path and gives us /opt/puppetlabs/bin/puppet, which is what the
# configure stage invokes.
#
# Agent-less by design: we only ever run `puppet apply` locally against a manifest
# copied by CI. There is no Puppet server, no certificates, no agent daemon.
set -euo pipefail

PUPPET_BIN=/opt/puppetlabs/bin/puppet

if [ -x "$PUPPET_BIN" ]; then
  echo "Puppet already installed: $($PUPPET_BIN --version)"
  exit 0
fi

# shellcheck disable=SC1091
. /etc/os-release
CODENAME="$VERSION_CODENAME"
RELEASE_DEB="puppet8-release-${CODENAME}.deb"

echo "Installing Puppet 8 for ${CODENAME}..."

# Retry apt operations: fresh cloud instances often race with mirror availability.
for i in 1 2 3; do
  sudo apt-get update && break
  echo "apt-get update failed (attempt $i), retrying..."
  sleep 10
done

sudo apt-get install -y --no-install-recommends curl ca-certificates

TMP_DEB="$(mktemp -d)/${RELEASE_DEB}"
curl -fsSL --retry 3 --retry-delay 5 \
  "https://apt.puppet.com/${RELEASE_DEB}" -o "$TMP_DEB"

sudo dpkg -i "$TMP_DEB"

for i in 1 2 3; do
  sudo apt-get update && break
  echo "apt-get update failed (attempt $i), retrying..."
  sleep 10
done

sudo apt-get install -y puppet-agent

echo "Installed: $($PUPPET_BIN --version)"
