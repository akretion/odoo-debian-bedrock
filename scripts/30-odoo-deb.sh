#!/usr/bin/env bash
# 30-odoo-deb: official nightly deb, pinned and held.
# The deb provides: odoo system user, /var/lib/odoo, /etc/odoo/odoo.conf,
# /var/log/odoo, logrotate, base systemd unit, odoo in dist-packages.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
: "${ODOO_VERSION:=18.0}"

wget -q -O - https://nightly.odoo.com/odoo.key | gpg --dearmor -o /usr/share/keyrings/odoo-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/odoo-archive-keyring.gpg] https://nightly.odoo.com/${ODOO_VERSION}/nightly/deb/ ./" \
  > /etc/apt/sources.list.d/odoo.list
apt-get update -qq

# Debian 13 removed python3-pypdf2 (renamed python3-pypdf) but the
# nightly debs still hard-depend on it. Install a tiny equivs shim first.
if ! apt-get install -y --simulate odoo > /dev/null 2>&1; then
  if apt-cache policy python3-pypdf2 2>/dev/null | grep -q "Candidate: (none)"; then
    apt-get install -y -qq equivs python3-pypdf
    SHIMDIR=$(mktemp -d)
    cat > "$SHIMDIR/control" <<'EOF'
Section: python
Priority: optional
Standards-Version: 4.5.0
Package: python3-pypdf2
Version: 5.4.0-1~bedrock1
Depends: python3-pypdf
Architecture: all
Description: transitional shim - pypdf2 was renamed pypdf in Debian 13
 The Odoo nightly deb still depends on python3-pypdf2 while Odoo
 imports pypdf. This empty shim satisfies the dependency.
EOF
    (cd "$SHIMDIR" && equivs-build control > /dev/null)
    dpkg -i "$SHIMDIR"/python3-pypdf2_*.deb
    rm -rf "$SHIMDIR"
  fi
fi

apt-get install -y odoo

# wkhtmltopdf (patched qt) for proper PDF reports: distro builds break
# headers/footers. Install Odoo's own build per-distro; see
# https://github.com/odoo/odoo/wiki/Wkhtmltopdf

# Never let apt bump Odoo silently: upgrades are a maintenance-window op:
#   apt-mark unhold odoo && apt install odoo=<dated-build> && \
#   sudo -u odoo odoo -c /etc/odoo/odoo.conf -u all --stop-after-init
apt-mark hold odoo
