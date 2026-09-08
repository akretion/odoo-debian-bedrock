# shellcheck shell=bash
# lib-instance.sh — shared helpers for per-instance (prod/staging/...) setup.
# Source this from the numbered scripts; functions read the ambient env vars
# (APP_USER, VENV, ODOO_CONF, DBFILTER, UNIT, PROJECT_NAME, PROJECT_REPO,
#  PROJECT_BRANCH, ODOO_VERSION, ODOO_ADMIN_PASSWD).
BEDROCK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Create (or refresh) a venv layered over the deb: --system-site-packages +
# packaging + lxml_html_clean backport + odoo stub + greenlet.
make_venv() {
  apt-get install -y -qq python3-venv python3-pip
  python3 -m venv --system-site-packages "$VENV"
  "$VENV/bin/pip" install -q packaging
  # Odoo 16 imports lxml.html.clean (split out of lxml 5.2+): backport if missing.
  if ! "$VENV/bin/python3" -c "import lxml.html.clean" 2>/dev/null; then
    apt-get install -y -qq python3-lxml-html-clean 2>/dev/null || \
      "$VENV/bin/pip" install -q lxml_html_clean || true
  fi
  # Empty "odoo" stub dist so odoo-addon-* resolve without PyPI.
  local stub
  stub=$(mktemp -d)
  sed "s/@ODOO_VERSION@/${ODOO_VERSION}.0/" "$BEDROCK_DIR/odoo-stub/pyproject.toml" > "$stub/pyproject.toml"
  cp "$BEDROCK_DIR/odoo-stub/_odoo_deb_stub.py" "$stub/"
  "$VENV/bin/pip" install -q "$stub"
  rm -rf "$stub"
  # gevent (longpolling/websocket) wants greenlet>=3.1.1. Safe, dep-free.
  "$VENV/bin/pip" install -q --upgrade greenlet 2>/dev/null || true
}

# Path of the venv's odoo/addons namespace dir (for addons_path).
venv_addons_dir() {
  local pyver
  pyver=$("$VENV/bin/python3" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
  echo "$VENV/lib/python${pyver}/site-packages/odoo/addons"
}

# Comma-joined project addon dirs (links, local-src, external-src/*).
project_addons_path() {  # $1 = project dir
  local proj="$1" out=""
  [ -d "$proj/odoo/links" ] && out="$proj/odoo/links,"
  [ -d "$proj/odoo/local-src" ] && out="${out}$proj/odoo/local-src,"
  if [ -d "$proj/odoo/external-src" ]; then
    local repo
    for repo in "$proj/odoo/external-src"/*/; do
      [ -d "$repo" ] && out="${out}${repo%/},"
    done
  fi
  echo "${out%,}"
}

# Idempotently (re)write the project addons_path + dbfilter block in a config.
inject_project_block() {  # $1=conf $2=project_name $3=project_addons $4=dbfilter
  local conf="$1" name="$2" addons="$3" dbfilter="$4" base
  sed -i '/^# bedrock-project-begin/,/^# bedrock-project-end/d' "$conf"
  base=$(grep -m1 '^addons_path' "$conf" | cut -d= -f2- | tr -d ' ')
  cat >> "$conf" <<EOF
# bedrock-project-begin ($name)
addons_path = $addons,$base
dbfilter = $dbfilter
# bedrock-project-end
EOF
}

# Clone/pull the project as APP_USER, install requirements into VENV,
# and wire the config. Reads env vars set by the caller.
attach_project() {
  local proj="/home/$APP_USER/$PROJECT_NAME"
  id "$APP_USER" &>/dev/null || adduser --disabled-password --gecos "" "$APP_USER"
  if [ ! -d "$proj/.git" ]; then
    # shellcheck disable=SC2086
    su -s /bin/bash "$APP_USER" -c "git clone ${PROJECT_BRANCH:+--branch $PROJECT_BRANCH} $PROJECT_REPO $proj"
  else
    su -s /bin/bash "$APP_USER" -c "git -C $proj pull --ff-only"
  fi
  chmod -R a+rX "$proj/odoo"
  if [ -f "$proj/odoo/requirements.txt" ]; then
    "$VENV/bin/pip" install -r "$proj/odoo/requirements.txt"
  fi
  local addons
  addons=$(project_addons_path "$proj")
  inject_project_block "$ODOO_CONF" "$PROJECT_NAME" "$addons" "$DBFILTER"
  chown "$RUNTIME_USER":"$RUNTIME_USER" "$ODOO_CONF" 2>/dev/null || true
  systemctl restart "$UNIT" 2>/dev/null || \
    echo "no systemd here — restart $UNIT manually (proot/container testbed)"
}

# Render the nginx vhost (ports are parameterized upstreams).
render_nginx() {  # $1=domain $2=ws_path $3=odooport $4=longpollport $5=outfile
  sed -e "s/@DOMAIN@/$1/g" -e "s|@WS_PATH@|$2|" \
      -e "s/@ODOO_PORT@/$3/g" -e "s/@LONGPOLLING_PORT@/$4/g" \
      "$BEDROCK_DIR/templates/nginx.conf" > "$5"
}
