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

# Idempotently (re)write the project addons_path + dbfilter in a config.
# REPLACES the existing addons_path/dbfilter lines instead of appending
# duplicates — Odoo's configparser is strict and raises DuplicateOptionError
# on a second occurrence, which crashes Odoo at startup.
inject_project_block() {  # $1=conf $2=project_name $3=project_addons $4=dbfilter
  local conf="$1" name="$2" addons="$3" dbfilter="$4" base
  # base = venv site-packages + deb core (deterministic, from the template)
  base="$(venv_addons_dir),/usr/lib/python3/dist-packages/odoo/addons"
  # Odoo's configparser is strict: one addons_path/dbfilter only, else it
  # raises DuplicateOptionError and crashes at startup. Remove any prior
  # block, drop existing lines, then write single occurrences.
  sed -i '/^# bedrock-project-begin/,/^# bedrock-project-end/d' "$conf"
  sed -i '/^addons_path[[:space:]]*=/d; /^dbfilter[[:space:]]*=/d' "$conf"
  cat >> "$conf" <<EOF
# bedrock-project-begin ($name)
addons_path = $addons,$base
dbfilter = $dbfilter
# bedrock-project-end
EOF
}

# Generate a default ed25519 deploy key for a user IF missing (never
# overwrite a key the operator may have placed). Prints the public part so
# it can be added as a repo deploy key.
ensure_deploy_key() {  # $1 = username
  local user="$1" home key
  command -v ssh-keygen > /dev/null 2>&1 || apt-get install -y -qq openssh-client
  home=$(getent passwd "$user" | cut -d: -f6)
  [ -n "$home" ] && [ -d "$home" ] || return 0
  key="$home/.ssh/id_ed25519"
  if [ ! -f "$key" ]; then
    # generate AS the user so ownership/perms are naturally correct
    su -s /bin/bash "$user" -c "ssh-keygen -q -t ed25519 -N '' -C 'bedrock-deploy-$user' -f '$key'"
  fi
  echo "deploy key for '$user' (add the public part below as a repo deploy key):"
  cat "$key.pub"
}

# Clone/pull the project as APP_USER, install requirements into VENV,
# and wire the config. Reads env vars set by the caller.
attach_project() {
  local proj="/home/$APP_USER/$PROJECT_NAME"
  id "$APP_USER" &>/dev/null || adduser --disabled-password --gecos "" "$APP_USER"
  ensure_deploy_key "$APP_USER"
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

# Odoo-oriented postgres tuning into conf.d/bedrock.conf. The fixed defaults
# are safe for SSD + Odoo's write churn; override each via PG_* env vars, or
# append arbitrary settings via PG_EXTRA_CONF (one "key = value" per line —
# these come LAST so they win over the defaults, e.g. the RAM-dependent
# shared_buffers / work_mem). listen_addresses is deliberately NOT here: it
# is opened only on layer 2 by configure_pg_for_docker.
configure_pg_tuning() {
  local pgver confdir conffile mem_mb sb ecs wm mwm
  pgver=$(ls /etc/postgresql | head -1)
  confdir="/etc/postgresql/$pgver/main/conf.d"
  conffile="$confdir/bedrock.conf"
  mkdir -p "$confdir"

  # RAM-derived defaults (overridable via PG_* env vars). Percentages follow
  # the usual Odoo/Postgres guidance, capped to avoid over-subscription:
  #   shared_buffers        25% RAM (cap 8GB)
  #   effective_cache_size  75% RAM
  #   maintenance_work_mem  10% RAM (cap 2GB)
  #   work_mem              RAM/256, clamped [16MB, 256MB]
  mem_mb=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 ))
  [ "$mem_mb" -gt 0 ] || mem_mb=4096
  sb=$(( mem_mb / 4 ));  [ "$sb"  -gt 8192 ] && sb=8192
  ecs=$(( mem_mb * 3 / 4 ))
  mwm=$(( mem_mb / 10 )); [ "$mwm" -gt 2048 ] && mwm=2048
  wm=$(( mem_mb / 256 )); [ "$wm" -lt 16 ] && wm=16; [ "$wm" -gt 256 ] && wm=256

  {
    echo "# odoo-debian-bedrock: Odoo-oriented tuning (override via PG_* env vars)"
    echo "# detected RAM: ${mem_mb}MB"
    echo "password_encryption = '${PG_PASSWORD_ENCRYPTION:-scram-sha-256}'"
    echo "shared_buffers = ${PG_SHARED_BUFFERS:-${sb}MB}"
    echo "effective_cache_size = ${PG_EFFECTIVE_CACHE_SIZE:-${ecs}MB}"
    echo "maintenance_work_mem = ${PG_MAINTENANCE_WORK_MEM:-${mwm}MB}"
    echo "work_mem = ${PG_WORK_MEM:-${wm}MB}"
    echo "random_page_cost = ${PG_RANDOM_PAGE_COST:-1.1}"
    echo "checkpoint_completion_target = ${PG_CHECKPOINT_COMPLETION_TARGET:-0.9}"
    echo "autovacuum_max_workers = ${PG_AUTOVACUUM_MAX_WORKERS:-4}"
    echo "autovacuum_vacuum_scale_factor = ${PG_AUTOVACUUM_VACUUM_SCALE_FACTOR:-0.05}"
    echo "autovacuum_analyze_scale_factor = ${PG_AUTOVACUUM_ANALYZE_SCALE_FACTOR:-0.02}"
    if [ -n "${PG_EXTRA_CONF:-}" ]; then
      echo "# --- PG_EXTRA_CONF (last, so it overrides the above) ---"
      printf '%s\n' "$PG_EXTRA_CONF"
    fi
  } > "$conffile"
  chown postgres:postgres "$conffile" 2>/dev/null || true
  chmod 644 "$conffile"
  pg_ctlcluster "$pgver" main reload 2>/dev/null || service postgresql reload 2>/dev/null || true
}

# Make host postgres reachable from docker containers over TCP
# (listen_addresses='*' gated by pg_hba + ufw; see README).
configure_pg_for_docker() {
  local pgver pgconf pghba
  pgver=$(ls /etc/postgresql | head -1)
  pgconf="/etc/postgresql/$pgver/main/postgresql.conf"
  pghba="/etc/postgresql/$pgver/main/pg_hba.conf"
  if grep -qE '^[#]?listen_addresses' "$pgconf"; then
    sed -i -E "s|^[#]?listen_addresses.*|listen_addresses = '*'|" "$pgconf"
  else
    echo "listen_addresses = '*'" >> "$pgconf"
  fi
  grep -q "172.16.0.0/12" "$pghba" || cat >> "$pghba" <<'EOF'
# odoo-debian-bedrock: docker containers reach host postgres over TCP
host    all             all             172.16.0.0/12           scram-sha-256
EOF
  pg_ctlcluster "$pgver" main reload 2>/dev/null || service postgresql reload 2>/dev/null || true
}

# Install a CLI tool via pipx into a SHARED home (/opt/pipx) and
# /usr/local/bin, so every user (notably `app`) sees it on PATH.
# $1 = install spec (PyPI name or git+https URL), $2 = command to verify,
# $3 = "1" to force reinstall (refresh from git) even if already present.
install_pipx_tool() {
  apt-get install -y -qq pipx
  if [ "${3:-}" = "1" ] || ! command -v "$2" > /dev/null 2>&1; then
    PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin pipx install --force "$1" --include-deps
  fi
  command -v "$2" > /dev/null || { echo "ERROR: pipx install failed for $2" >&2; exit 1; }
}
