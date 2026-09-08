#!/usr/bin/env bash
# 11-tools: install Akretion's own CLI tooling on EVERY install (layer 1
# and layer 2). `ak` manages Odoo addons (git-aggregator checkout/build).
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# shellcheck source=lib-instance.sh
source "$(dirname "$0")/lib-instance.sh"

# force=1: always refresh ak from its default git branch on re-runs.
install_pipx_tool "git+https://github.com/akretion/ak" ak 1
