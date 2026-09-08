#!/bin/sh
# odoo-debian-bedrock one-liner installer.
#
#   curl -fsSL https://raw.githubusercontent.com/akretion/odoo-debian-bedrock/main/install.sh | sudo sh
#
# Does NOT assume git is installed: fetches a tarball instead.
# Re-running it updates an existing /opt/odoo-debian-bedrock install.
set -eu

REPO=akretion/odoo-debian-bedrock
BRANCH=main
DEST=/opt/odoo-debian-bedrock

if [ "$(id -u)" != 0 ]; then
  echo "Please run as root, e.g.:" >&2
  echo "  curl -fsSL https://raw.githubusercontent.com/$REPO/$BRANCH/install.sh | sudo sh" >&2
  exit 1
fi

# need a downloader; bootstrap curl via apt if we have neither
if ! command -v curl > /dev/null && ! command -v wget > /dev/null; then
  apt-get update -qq && apt-get install -y -qq curl
fi
fetch() {
  if command -v curl > /dev/null; then curl -fsSL "$1"; else wget -qO- "$1"; fi
}

if [ -d "$DEST/scripts" ]; then
  echo "odoo-debian-bedrock already at $DEST — updating..."
  if command -v git > /dev/null && [ -d "$DEST/.git" ]; then
    git -C "$DEST" pull --ff-only
  else
    fetch "https://codeload.github.com/$REPO/tar.gz/refs/heads/$BRANCH" | tar xz --strip-components=1 -C "$DEST"
  fi
else
  mkdir -p "$DEST"
  fetch "https://codeload.github.com/$REPO/tar.gz/refs/heads/$BRANCH" | tar xz --strip-components=1 -C "$DEST"
fi

cd "$DEST"
exec bash bin/bedrock "$@"
