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

# wkhtmltopdf with patched Qt (required for proper report headers/footers;
# the distro build is broken). Latest builds (0.12.6.1-3) ship only for
# bullseye/bookworm/jammy; noble runs the jammy build, trixie the bookworm one.
. /etc/os-release
ARCH=$(dpkg --print-architecture)
case "${VERSION_CODENAME}" in
  bookworm|trixie) WKDIST=bookworm ;;
  jammy|noble)     WKDIST=jammy ;;
  bullseye)        WKDIST=bullseye ;;
  *) echo "no wkhtmltox build known for ${VERSION_CODENAME}; skipping (reports will lack proper headers/footers)"; WKDIST="" ;;
esac
if [ -n "$WKDIST" ] && ! command -v wkhtmltopdf > /dev/null; then
  wget -q "https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox_0.12.6.1-3.${WKDIST}_${ARCH}.deb" \
    -O /tmp/wkhtmltox.deb && apt-get install -y /tmp/wkhtmltox.deb && rm -f /tmp/wkhtmltox.deb
fi
# (acsone/odoo-bedrock instead ships a kwkhtmltopdf CLIENT and runs the
# renderer in a separate container — an option for layer 2/3 images.)


# Never let apt bump Odoo silently: upgrades are a maintenance-window op:
#   apt-mark unhold odoo && apt install odoo=<dated-build> && \
#   sudo -u odoo odoo -c /etc/odoo/odoo.conf -u all --stop-after-init
apt-mark hold odoo
