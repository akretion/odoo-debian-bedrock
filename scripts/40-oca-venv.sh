#!/usr/bin/env bash
# 40-oca-venv: venv layered over the deb for OCA addons + pinned deps.
#
# Key trick: --system-site-packages makes the deb's Odoo visible inside
# the venv; pip then installs odoo-addon-* into the venv's own
# site-packages, which shadows dist-packages. apt never touches the
# venv, pip never touches dist-packages -> no --break-system-packages,
# no dpkg/pip file fights, pinning (cryptography & co) is safe.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
: "${ODOO_VERSION:=18.0}"
: "${OCA_ADDONS:=}"

VENV=/usr/lib/odoo/venv
BEDROCK_DIR="$(cd "$(dirname "$0")/.." && pwd)"

apt-get install -y -qq python3-venv python3-pip
python3 -m venv --system-site-packages "$VENV"

# Odoo needs `packaging` to parse addon external_dependencies (e.g.
# erpbrasil.base). The odoo deb doesn't declare it and some distros
# (Ubuntu 24.04) don't ship it in the base python — pin it in the venv
# where it's guaranteed and shadow-safe.
"$VENV/bin/pip" install -q packaging

# Odoo 16 imports `lxml.html.clean`, which was split out of lxml 5.2+
# into lxml_html_clean. Older distros (jammy/bookworm) still ship the
# bundled path, so only act when the import is actually missing.
if ! "$VENV/bin/python3" -c "import lxml.html.clean" 2>/dev/null; then
  apt-get install -y -qq python3-lxml-html-clean 2>/dev/null || \
    "$VENV/bin/pip" install -q lxml_html_clean || true
fi

# The deb ships no pip metadata, so odoo-addon-* would try to pull an
# "odoo" package from PyPI. Install an empty stub dist named "odoo"
# with the matching series version to satisfy the resolver.
STUB=$(mktemp -d)
sed "s/@ODOO_VERSION@/${ODOO_VERSION}.0/" "$BEDROCK_DIR/odoo-stub/pyproject.toml" > "$STUB/pyproject.toml"
cp "$BEDROCK_DIR/odoo-stub/_odoo_deb_stub.py" "$STUB/"
"$VENV/bin/pip" install -q "$STUB"
rm -rf "$STUB"

# OCA addons and their (pinned-able) python deps, venv-only:
if [ -n "$OCA_ADDONS" ]; then
  # shellcheck disable=SC2086
  "$VENV/bin/pip" install $OCA_ADDONS
fi

# gevent (longpolling/websocket) wants greenlet>=3.1.1; the distro one
# may lag. greenlet has no deps, so this is safe.
# Deliberately NOT upgrading pyopenssl/cryptography here: a newer
# cryptography shadows the distro one and breaks the older urllib3
# (1.26 on jammy/bookworm), whose contrib/pyopenssl still imports a
# `cryptography` path removed in 37+. Heavy chains that truly need a
# newer cryptography (l10n-brazil + signxml) must pin explicitly.
"$VENV/bin/pip" install -q --upgrade greenlet 2>/dev/null || true

# NOTE: running module tests additionally needs test-only deps that
# odoo-addon-* doesn't declare, e.g.: pip install xmldiff vcrpy

# Discover where the venv's odoo/addons namespace dir is and wire the
# addons_path + hardened config:
PYVER=$("$VENV/bin/python3" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
VENV_ADDONS="$VENV/lib/python${PYVER}/site-packages/odoo/addons"

sed -e "s|@ADMIN_PASSWD@|${ODOO_ADMIN_PASSWD:-admin}|" \
    -e "s|@VENV_ADDONS@|$VENV_ADDONS|" \
    "$BEDROCK_DIR/templates/odoo.conf" > /etc/odoo/odoo.conf
chown odoo:odoo /etc/odoo/odoo.conf
chmod 0640 /etc/odoo/odoo.conf

# Run Odoo through the venv interpreter + systemd hardening:
install -d /etc/systemd/system/odoo.service.d
sed "s|@VENV@|$VENV|" "$BEDROCK_DIR/templates/systemd-override.conf" \
  > /etc/systemd/system/odoo.service.d/akretion.conf
systemctl daemon-reload 2>/dev/null || true   # no systemd under proot/tests
