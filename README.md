# odoo-debian-bedrock

Akretion's minimal on-premise, layered Odoo host installation for Debian/Ubuntu.

(Not to be confused with acsone/odoo-bedrock, the excellent Docker base
image we already use in our optional docker installs)

The idea: the official Odoo deb package gives you the boring 20%
(system user, /etc/odoo/odoo.conf, postgres role, logrotate, base
systemd unit). bedrock adds the production 80% as a thin, auditable
overlay of only 400 lines of idempotent shell scripts — no framework to learn.

## Layers

- **Layer 1 (default):** official odoo deb + a venv layered on top with
  `--system-site-packages` for OCA addons (`odoo-addon-*`) and pinned
  Python deps. apt and pip never manage the same directory, so
  unattended-upgrades keeps working without breaking the install.
  This is the tier for small on-premise Odoo users or customers.
- **Layer 2 (`--with-docker`):** host prep (hardening, ak, host postgres,
  backup) + Docker + docky. The Odoo *deb is skipped* — Odoo and its
  dependencies come from the acsone/odoo-bedrock image (with the source
  tarball mounted), so the host deb/venv would be redundant. Host nginx
  still proxies to the container's published 8069; backup still runs
  (point FILESTORE_DIR at the container's mounted filestore volume).

## Layout

```
bin/bedrock            orchestrator: run all or selected steps
scripts/10-base.sh     host hardening basics, unattended-upgrades
scripts/11-tools.sh    pipx + ak (Akretion's addon-management CLI)
scripts/20-postgres.sh postgresql (distro or PGDG)
scripts/30-odoo-deb.sh nightly.odoo.com repo + odoo deb (apt-mark hold)
scripts/40-oca-venv.sh venv --system-site-packages + odoo-stub + addons
scripts/50-nginx.sh    nginx reverse proxy vhost (+certbot hook point)
scripts/60-backup.sh   pg_dump + filestore cron backup
scripts/70-docker.sh   LAYER 2: docker + docky
odoo-stub/             empty "odoo" dist so odoo-addon-* resolves
templates/             odoo.conf, systemd override, nginx vhost
```

## Install (as root on a fresh Debian 13 / Ubuntu 24.04)

One-liner:

```bash
curl -fsSL https://raw.githubusercontent.com/akretion/odoo-debian-bedrock/main/install.sh | sudo sh
```

This installs into /opt/odoo-debian-bedrock and runs the full Layer 1
setup. Re-run the same command any time to update the scripts.

If you prefer to inspect before executing (the scripts are short and
readable — that's the point):

```bash
sudo apt install -y git
git clone https://github.com/akretion/odoo-debian-bedrock
cd odoo-debian-bedrock
sudo bash bin/bedrock                  # layer 1
sudo bash bin/bedrock --with-docker    # layer 1 + layer 2 (docker/docky)
```

Optional environment variables (sensible defaults otherwise):

```bash
export ODOO_VERSION=18.0          # odoo series to install
export ODOO_ADMIN_PASSWD=...      # odoo master password (random if unset)
export OCA_ADDONS="odoo-addon-mis_builder odoo-addon-web_responsive"
export DOMAIN=odoo.example.com    # enables the nginx vhost (50-nginx.sh)
export CERTBOT_EMAIL=you@example.com  # unattended Let's Encrypt issuance
export PGDG=1                     # use postgresql.org repo instead of distro PG
export FILESTORE_DIR=/home/app/soleio/data/filestore  # docker: mounted filestore volume (backup)

# PostgreSQL tuning overrides (RAM-dependent defaults are auto-sized):
export PG_SHARED_BUFFERS=2GB        # default: 25% RAM (cap 8GB)
export PG_EFFECTIVE_CACHE_SIZE=6GB  # default: 75% RAM
export PG_MAINTENANCE_WORK_MEM=1GB  # default: 10% RAM (cap 2GB)
export PG_WORK_MEM=64MB             # default: RAM/256, [16..256]MB
export PG_RANDOM_PAGE_COST=1.1
export PG_CHECKPOINT_COMPLETION_TARGET=0.9
export PG_AUTOVACUUM_MAX_WORKERS=4
export PG_AUTOVACUUM_VACUUM_SCALE_FACTOR=0.05
export PG_AUTOVACUUM_ANALYZE_SCALE_FACTOR=0.02
# anything else, one "key = value" per line (appended last, wins over defaults):
export PG_EXTRA_CONF="max_connections = 200"
```

## Compatibility matrix

What the official deb + bedrock overlay support, per distro Python
(Odoo 19+ needs Python >= 3.12; the deb resolves the rest):

| Distro                    | Python | Odoo 16 | 17 | 18 | 19 | 20 |
|---------------------------|--------|---------|----|----|----|----|
| Debian 12 (bookworm)      | 3.11   | OK      | OK | OK | no | no |
| Debian 13 (trixie)        | 3.13   | no      | no | OK | OK | OK |
| Ubuntu 22.04 LTS (jammy)  | 3.10   | OK      | OK | OK | no | no |
| Ubuntu 24.04 LTS (noble)  | 3.12   | OK      | OK | OK | OK | OK |

Notes:

- On trixie the nightly deb still depends on the removed
  python3-pypdf2 package — 30-odoo-deb.sh auto-installs a tiny equivs
  shim (Odoo imports pypdf). Harmless elsewhere.
- The nginx vhost adapts to the Odoo series automatically
  (/websocket for >= 16, /longpolling/ for older).

## Security & updates

This is where the deb-based design pays off vs a Docker image nobody
rebuilds:

1. OS security updates (openssl, python3, postgresql, nginx, kernel
   libs) install AUTOMATICALLY via unattended-upgrades. A bedrock
   server left alone for a year still gets its CVE fixes.
2. Odoo fixes: the nightly deb is designed for in-series upgrades —
   Odoo's stable series only receive backward-compatible fixes
   (including security fixes). To update Odoo:

   ```bash
   sudo apt update && sudo apt upgrade     # pulls the latest nightly of your series
   sudo systemctl restart odoo
   ```

   Rarely, a nightly requires a module refresh — if the logs complain
   after an upgrade, run once:

   ```bash
   sudo -u odoo odoo -c /etc/odoo/odoo.conf -d <your_db> -u all --stop-after-init
   sudo systemctl restart odoo
   ```

   Managed fleets that prefer deliberate upgrade windows can install
   with ODOO_APT_HOLD=1 (apt-mark hold odoo).
3. OCA addons live in the venv (pip). Update them deliberately:

   ```bash
   sudo /usr/lib/odoo/venv/bin/pip install -U odoo-addon-mis_builder
   sudo -u odoo odoo -c /etc/odoo/odoo.conf -d <your_db> -u mis_builder --stop-after-init
   sudo systemctl restart odoo
   ```

   Note: venv pip packages are NOT covered by apt security updates —
   that's the trade for version pinning. Watch erpbrasil/signxml/
   cryptography releases if you use the fiscal chain.
4. bedrock's own scripts: re-run the install.sh one-liner (it
   self-updates /opt/odoo-debian-bedrock first).

## PostgreSQL tuning

`20-postgres.sh` writes an Odoo-oriented drop-in at
/etc/postgresql/<ver>/main/conf.d/bedrock.conf. The RAM-dependent settings
are sized automatically from the detected total RAM (percentage rules, capped
to avoid over-subscription):

- shared_buffers = 25% RAM (cap 8GB)
- effective_cache_size = 75% RAM
- maintenance_work_mem = 10% RAM (cap 2GB)
- work_mem = RAM/256, clamped to [16MB, 256MB]

Fixed defaults:

- password_encryption = scram-sha-256
- random_page_cost = 1.1            (SSD/NVMe: prefer index scans)
- checkpoint_completion_target = 0.9 (smooth checkpoint I/O)
- autovacuum_max_workers = 4
- autovacuum_vacuum_scale_factor = 0.05  (aggressive cleanup)
- autovacuum_analyze_scale_factor = 0.02  (fresher stats)

Every value is overridable via a PG_* env var (see the install section),
e.g. `PG_SHARED_BUFFERS=2GB`. Anything else — or a final override of the
above — goes in PG_EXTRA_CONF, one "key = value" per line, appended LAST
so it wins:

```bash
export PG_SHARED_BUFFERS=2GB
export PG_EXTRA_CONF="max_connections = 200
synchronous_commit = off"
```

`listen_addresses` is deliberately NOT set here: layer-1 Odoo talks to
postgres over the unix socket, so the port stays closed by default. It is
opened only on layer 2 (docker) by 70-docker.sh, gated by pg_hba + ufw.

## Custom project / custom code

Projects with custom modules (repos carrying
odoo/links, odoo/local-src, odoo/external-src, odoo/requirements.txt)
attach to a bedrock host without changing the layout:

```bash
PROJECT_NAME=acme PROJECT_REPO=git@github.com:akretion/acme.git \
  sudo -E bash /opt/odoo-debian-bedrock/scripts/80-project.sh
```

What this does:

- keeps the 'app' user convention: clone at /home/app/<project>,
  owned by app (deploy/SSH identity); the odoo runtime user only READS
  the code (chmod a+rX). Not /home/odoo — the deb's odoo user has its
  home at /var/lib/odoo and stays a pure runtime identity.
- pip-installs odoo/requirements.txt into the bedrock venv
  (odoo-addon-* pins resolve via the odoo stub).
- PREPENDS odoo/links, odoo/local-src and every odoo/external-src/*
  repo to addons_path, so customer code shadows the venv/deb addons
  (the block in /etc/odoo/odoo.conf is idempotent — safe to re-run,
  e.g. after adding an external-src repo).
- scopes dbfilter to ^<project>.* and restarts odoo.

The deploy user gets a default ed25519 deploy key generated on first run
(only if ~/.ssh/id_ed25519 doesn't already exist — never overwritten).
The public key is printed so you can add it as a read-only deploy key on
the project repo, letting `app`/`app-staging` pull private repos over SSH
without stored credentials.

## Staging on the same host (multiple instances)

A bedrock host can run several isolated Odoo instances sharing the one
core deb — typically prod + staging. Each instance gets its own deploy
user, runtime user, venv, config, postgres role, ports, and systemd
unit. `81-staging.sh` creates one:

```bash
PROJECT_NAME=acme PROJECT_REPO=git@github.com:akretion/acme.git \
  PROJECT_BRANCH=staging STAGING_DOMAIN=staging.acme.example.com \
  sudo -E bash /opt/odoo-debian-bedrock/scripts/81-staging.sh
```

Isolation map (prod → staging):

| layer        | prod                          | staging                              |
|--------------|-------------------------------|--------------------------------------|
| deploy user  | app  (/home/app/<project>)    | app-staging  (/home/app-staging/...) |
| runtime user | odoo (/var/lib/odoo)          | odoo-staging (/var/lib/odoo-staging) |
| venv         | /usr/lib/odoo/venv            | /usr/lib/odoo/venv-staging           |
| config       | /etc/odoo/odoo.conf           | /etc/odoo/odoo-staging.conf          |
| postgres role| odoo                          | odoo-staging                         |
| ports        | 8069 / 8072                   | 8070 / 8073                          |
| systemd      | odoo.service                  | odoo-staging.service                 |
| code branch  | (prod branch)                 | (staging branch via PROJECT_BRANCH)  |

Key design points:

- **Deploy user separation** is the reason this exists: grant SSH keys to
  app-staging for developers allowed to deploy staging but not prod.
- **Separate postgres user comes free** from peer auth: the runtime user
  odoo-staging maps to the PG role odoo-staging (no passwords anywhere).
- **Separate venv** lets staging pin different odoo-addon versions than
  prod — a shared venv cannot hold two versions of the same addon.
- Different Odoo *core* version per instance is NOT covered by the deb
  (one core per host): for that, add a source clone to that instance's
  addons_path and point its unit at odoo-bin (see "Patching Odoo core").

## Docker + host Postgres (layer 2)

A docky/docker-compose project on a bedrock host should reach the HOST
postgres over TCP — not by mounting the socket. Why:

- **Peer auth breaks across the socket.** The container's odoo uid doesn't
  match the host's postgres user, so peer auth on a mounted socket fails;
  you end up loosening to trust just to make it work.
- **Monitoring attribution.** TCP connections appear in pg_stat_activity
  with the real user/db; a socket-mounted setup collapses everything to
  one local connection.
- **No socket-dir coupling.** TCP keeps working regardless of
  `unix_socket_directories`, container images, or where PG moves later.

`70-docker.sh` already prepares the host when you install with
`--with-docker`: postgres listens on `*` and pg_hba allows the docker
bridge subnet (172.16.0.0/12) with scram-sha-256. External 5432 stays
closed by ufw (10-base.sh) and the pg_hba scoping — so `*` is not an
open door.

Per project, create a role + database:

```bash
DB_NAME=myproj DB_PASSWORD=<secret> \
  sudo -E bash /opt/odoo-debian-bedrock/scripts/72-pg-docker-user.sh
```

Then in the project's docker-compose/docky config, point Odoo at the
host via the bridge gateway (Linux docker doesn't auto-provide
`host.docker.internal`, so add it explicitly):

```yaml
services:
  odoo:
    extra_hosts:
      - "host.docker.internal:host-gateway"
    environment:
      DB_HOST: host.docker.internal
      DB_USER: myproj
      DB_PASSWORD: ${DB_PASSWORD}
```

## CI

GitHub Actions (.github/workflows/ci.yml) runs on every push:

- **lint** — shellcheck over all scripts.
- **install** — a REAL install job per README "OK" cell: runs the
  bedrock scripts inside the actual distro container (Debian 12/13,
  Ubuntu 22.04/24.04 × Odoo 16/17/18/19), starts postgres, installs
  mis_builder + web_responsive on a fresh db, and checks Odoo serves HTTP.
- **tools** — installs docky (PyPI) and ak (git) via pipx on each of
  the four distros, so our own tooling is proven installable everywhere.

## Patching Odoo core (commits / PRs / forks)

The deb installs Odoo into /usr/lib/python3/dist-packages/odoo — it is
dpkg-owned and has NO .git. To apply a fix from github.com/odoo/odoo (or
a fork) you have two options.

### Option A — patch the installed files in place (quick, untracked)

GitHub serves a unified diff for any commit or PR:

    # a specific commit (on odoo/odoo or any fork):
    curl -L https://github.com/odoo/odoo/commit/<sha>.diff -o /tmp/fix.diff
    # or an entire PR (same URL shape, /pull/<n>.diff)
    curl -L https://github.com/odoo/odoo/pull/12345.diff -o /tmp/pr.diff

    cd /usr/lib/python3/dist-packages/odoo
    sudo patch -p1 < /tmp/pr.diff
    sudo systemctl restart odoo

Caveats: nothing is tracked (keep your .diff files somewhere versioned),
and `apt upgrade` of the odoo deb silently overwrites patched files — you
must re-apply after every upgrade. Good for one-off hotfixes.

### Option B — source mode (shallow clone, full git)

Cleaner once you're patching core: run from a shallow git clone instead
of the deb's copy. A nightly is just tip-of-branch at build time, so
this reproduces your installed version:

    git clone --depth 1 --single-branch --branch 18.0 \
      https://github.com/odoo/odoo /opt/odoo-src

    # apply a PR as a real branch, then cherry-pick:
    git -C /opt/odoo-src fetch origin pull/12345/head:pr-12345
    git -C /opt/odoo-src cherry-pick pr-12345

    # or apply a single commit/PR patch and commit it:
    curl -L https://github.com/odoo/odoo/pull/12345.patch | git -C /opt/odoo-src am

IMPORTANT layout difference: a git clone keeps framework addons
(odoo/addons — `base` etc.) SEPARATE from business addons (addons/ — web,
account, ...), whereas the deb merges both into odoo/addons. So in source
mode your addons_path must list BOTH clone dirs, then the OCA venv, and
you must run the clone's odoo-bin:

    addons_path = /opt/odoo-src/odoo/addons,/opt/odoo-src/addons,\
        /usr/lib/odoo/venv/lib/python3.12/site-packages/odoo/addons
    # run: /usr/lib/odoo/venv/bin/python3 /opt/odoo-src/odoo-bin -c /etc/odoo/odoo.conf

(For a build pinned to a specific date rather than tip-of-branch, clone
with `--shallow-since=<date>` so there is history to search.)

## Why not pip --break-system-packages?

pip and dpkg managing the same /usr/lib/python3/dist-packages
directory is unsound: either tool can silently overwrite the other's
files, and an apt security upgrade can downgrade a pinned
cryptography/pyopenssl under your feet. The venv overlay gives pip a
private site-packages that shadows the system one — same convenience,
no fight.
