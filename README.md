# odoo-debian-bedrock

Akretion's minimal substrate for hosting Odoo yourself — on a cloud VPS or onsite, on Debian/Ubuntu. Short, idempotent shell scripts you can read end to end: nothing to learn, nothing that will surprise you in two years — a foundation you stay in control of and extend.

(Not to be confused with acsone/odoo-bedrock, the excellent Docker base
image we use in the docker option below.)

The idea: bedrock prepares the host — hardening, postgres, nginx, backups —
and stays out of the way; you choose how Odoo itself runs: from the official
`.deb` (with a venv for OCA addons), inside Docker (acsone/odoo-bedrock
image + a mounted source tarball), or under a container control plane of
your own (hosted apps). One deployment path runs roughly half the tree
(~900 of ~1300 shell lines); the rest is the other options, which a given
host never executes.

## Three install options

```
odoo-debian-bedrock
│
├── Option A — VENV (default)          bin/bedrock
│   ├─ odoo .deb  (official nightly)     ← Odoo core
│   ├─ venv overlay (OCA addons via pip) ← addons
│   ├─ host postgres
│   └─ host nginx → 127.0.0.1:8069
│
├── Option B — DOCKER                  bin/bedrock --with-docker
│   ├─ docker + docky
│   ├─ odoo in a container (acsone/odoo-bedrock + mounted source)
│   ├─ host postgres (reached over the bridge)
│   └─ host nginx → container's 8069
│
└── Option C — HOSTED APPS             bin/bedrock --with-paas
    ├─ docker engine (no docky, no ak)
    ├─ one containerised app per project, built from git by a control plane
    ├─ host postgres (the same role/db a venv instance can share)
    └─ host nginx serves each app; vhosts stay in sites-enabled/
```

|                     | Option A — venv (default)                         | Option B — docker                              |
|---------------------|---------------------------------------------------|------------------------------------------------|
| Odoo core           | official `.deb`, apt-managed                       | acsone/odoo-bedrock image + mounted source     |
| OCA addons          | pip into a venv overlay (`--system-site-packages`) | baked into the project image                   |
| Postgres            | host (unix socket, peer auth)                      | host (TCP over the docker bridge)              |
| Best for            | small on-prem, free users, the "viral" tier        | larger / multi-tenant / managed docker projects|
| Command             | `bin/bedrock`                                      | `bin/bedrock --with-docker`                    |

A third option, **hosted apps** (`bin/bedrock --with-paas`), prepares the same
kind of host for a mini-PaaS control plane that builds one image per app and
lets the host nginx serve it. It installs the docker engine plus the database
wiring and **not** docky or ak: on that tier the build happens in the image.
See "Option C" below.

## Quick start

One-liner (runs **Option A**):

```bash
curl -fsSL https://raw.githubusercontent.com/akretion/odoo-debian-bedrock/main/install.sh | sudo sh
```

Or inspect first (the scripts are short and readable — that's the point):

```bash
sudo apt install -y git
git clone https://github.com/akretion/odoo-debian-bedrock
cd odoo-debian-bedrock
sudo bash bin/bedrock                  # Option A — venv
sudo bash bin/bedrock --with-docker    # Option B — docker
```

This installs into /opt/odoo-debian-bedrock. Re-run the same command any
time to update the scripts.

## Environment variables

Sensible defaults otherwise.

Option A — venv only:

```bash
export ODOO_VERSION=18.0          # odoo series to install
export ODOO_ADMIN_PASSWD=...      # odoo master password (random if unset)
export OCA_ADDONS="odoo-addon-mis_builder odoo-addon-web_responsive"
export ODOO_APT_HOLD=1            # pin the deb (managed fleets); default: no hold
export ODOO_PORT=8069             # venv instance HTTP port (nginx upstream)
export LONGPOLLING_PORT=8072      # gevent/websocket port (nginx upstream)
export HTTP_INTERFACE=127.0.0.1   # bind loopback: nginx is the front door
```

Common to all:

```bash
export DOMAIN=odoo.example.com    # enables the nginx vhost (50-nginx.sh)
export CERTBOT_EMAIL=you@example.com  # unattended Let's Encrypt issuance
export BEDROCK_BANNER=0           # silence the attribution line (CI, log diffs)
export PGDG=1                     # use postgresql.org repo instead of distro PG
export PG_MAJOR=18                # PGDG: explicit major (default: newest in PGDG)
# Never `apt install postgresql` on a PGDG host: that metapackage is the
# newest major AND depends on postgresql-all (every major 10..18 + dev
# headers + LLVM/clang, ~2.5 GB). The script installs postgresql-$PG_MAJOR.

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

Options B / C — container tiers:

```bash
export HOSTED_APPS_INSTALLER=/path/to/installer.sh  # private control plane installer (C)
export DOCKY=1                    # 0 skips the docky compose wrapper (--with-paas does)
export DOCKY_SPEC=...            # overrides scripts/docky-spec (how docky is
                                  # installed: the PyPI sdist builds an invalid
                                  # wheel on modern pip; `docky` once a fixed
                                  # release exists, or a commit SHA to pin)
export PG_ALLOW_RESTART=1         # 0: write listen_addresses but never restart postgres
```

## Layout

```
bin/bedrock            orchestrator: run all or selected steps
scripts/10-base.sh     host hardening basics, unattended-upgrades   [common]
scripts/11-tools.sh    pipx + ak (Akretion's addon-management CLI)  [A,B]
scripts/20-postgres.sh postgresql (distro or PGDG) + tuning         [common]
scripts/30-odoo-deb.sh nightly.odoo.com repo + odoo deb             [A]
scripts/40-oca-venv.sh venv --system-site-packages + odoo-stub      [A]
scripts/50-nginx.sh    nginx reverse proxy vhost (+certbot)         [common]
scripts/60-backup.sh   pg_dump + filestore cron backup              [common]
scripts/70-docker.sh   docker engine (+ docky unless DOCKY=0) + PG-for-docker [B,C]
scripts/73-hosted-apps.sh  host ready for a mini-PaaS control plane  [C]
scripts/72-pg-docker-user.sh  PG role+db for a docker project       [B]
scripts/80-project.sh  attach a customer project (venv)             [A]
scripts/81-staging.sh  staging instance on the same host (venv)     [A]
odoo-stub/             empty "odoo" dist so odoo-addon-* resolves   [A]
templates/             odoo.conf, systemd override, nginx vhost
```

---

# Option A — venv (the official deb + venv overlay)

The default. Odoo runs from the official nightly `.deb`; a venv layered on
top (`python3 -m venv --system-site-packages`) holds OCA addons and pinned
Python deps. apt and pip never manage the same directory, so
unattended-upgrades keeps working without breaking the install. This is the
tier for small on-premise Odoo users, free users, and the community play.

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
- scopes dbfilter to ^<project>.* (override with PROJECT_DBFILTER when the
  databases don't carry the project name, e.g.
  PROJECT_DBFILTER='^(database1|database2).*') and restarts odoo.

The deploy user gets a default ed25519 deploy key generated on first run
(only if ~/.ssh/id_ed25519 doesn't already exist — never overwritten).
The public key is printed so you can add it as a read-only deploy key on
the project repo, letting `app`/`app-staging` pull private repos over SSH
without stored credentials.

> For the docker option, custom code lives in the project image (built via
> docky/copier template) — not via 80-project.sh.

## Staging on the same host (multiple instances)

A venv bedrock host can run several isolated Odoo instances sharing the one
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

### The staging seed: a neutralized template, refreshed nightly

Staging data should never be a dump loaded into a staging database: that is
slow, and it silently inherits live crons, live SMTP servers and the production
URL. Instead keep ONE neutralized template on the same cluster and clone it
(`CREATE DATABASE … TEMPLATE <seed>` — seconds, disk-thin):

```bash
sudo bash scripts/82-seed.sh                 # install helper + config + cron (03:40)
sudoedit /etc/odoo-seed.conf                 # SEED_TARGETS, see below
sudo odoo-seed-refresh all                   # refresh now
```

`SEED_TARGETS` holds one line per seed:
`name|source_db|seed_db|role|url|hook_dir`. Each night
`/usr/local/bin/odoo-seed-refresh` dumps production (read-only), restores into
`<seed>_new`, neutralizes it, installs `SEED_MODULES` on the seed with a real
`odoo -i` (that is what gives clones the environment ribbon — SQL can only queue
a module state), swaps the seed and optionally re-clones the databases listed in
`SEED_CLONE_DBS`.

**The seed carries no production file.** `CREATE DATABASE … TEMPLATE` copies the
database, never the filestore directory, so a clone inheriting attachment rows
would answer 500 on every compiled bundle
(`FileNotFoundError: .../filestore/<db>/aa/aa6baa9…` on `web.assets_web.min.css`).
Copying production's filestore fixes that and is the wrong answer: it is heavy
(measured 1.5 GB / 23k rows on a small ERP) and it puts the customer's invoices,
employee documents and images on a staging host. `neutralize-filestore.sql` makes
the seed filestore-free instead: asset bundles and module-static index rows are
deleted (each clone regenerates them from its own code), and business attachments
keep their rows with a blanked pointer, so Odoo serves an empty stream rather than
raising. Set `SEED_FILESTORE=yes` only for a project that genuinely needs the
documents.

Neutralization is **three layers**, and the split is the whole point:

| layer | file | why there |
|-------|------|-----------|
| 1. the series itself | `<installed odoo>/addons/base/data/neutralize.sql` | read from the installation, never vendored: 18 adds the webhook update, 19 adds the SMTP-credential and `database.secret` rewrites, 20 will bring its own — so 16→20 stays correct by construction |
| 2. the gaps core leaves | `share/neutralize-extras.sql` | queued mail/jobs, fetchmail, payment providers in test, the seed URL. Basic on purpose, every statement guarded per table, so a missing module is a no-op |
| 3. project facts | `hook_dir/*.sql` (this host) | fiscal environment, discuss history, third-party URLs, password policy — nothing generic ever lands here |

The ribbon's look (`ribbon.name`, `ribbon.background.color`) is applied by
`share/neutralize-ribbon.sql`, UPDATE-only and **after** the install: the module's
data file CREATES those rows, so writing them beforehand aborts the module graph
on a unique violation.

`odoo neutralize` proper (EVERY installed module's `data/neutralize.sql`,
including OCA ones) rewrites far more than most projects accept on staging, so it
is opt-in: `SEED_MODULE_SQL=yes`.

The two shared SQL files are also shipped by the application-image tooling used
on hosts where production runs in a container: it prefers the installed copies in
`/usr/local/lib/odoo-seed/`, so a host running both keeps one source of truth.

## Patching Odoo core (commits / PRs / forks)

The deb installs Odoo into /usr/lib/python3/dist-packages/odoo — it is
dpkg-owned and has NO .git. To apply a fix from github.com/odoo/odoo (or
a fork) you have two options.

### Option A.1 — patch the installed files in place (quick, untracked)

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

### Option A.2 — source mode (shallow clone, full git)

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

## Security & updates

Item 1 applies to **both** options; items 2–4 are venv-specific.

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

## Why not pip --break-system-packages?

pip and dpkg managing the same /usr/lib/python3/dist-packages
directory is unsound: either tool can silently overwrite the other's
files, and an apt security upgrade can downgrade a pinned
cryptography/pyopenssl under your feet. The venv overlay gives pip a
private site-packages that shadows the system one — same convenience,
no fight.

## Compatibility matrix

The official deb + overlay, per distro Python (Odoo 19+ needs
Python >= 3.12; the deb resolves the rest):

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

---

# Option B — Docker (acsone/odoo-bedrock image)

For larger, managed, or multi-tenant deployments. Odoo runs in a container
built on the acsone/odoo-bedrock image (dependencies baked in) with the
Odoo source mounted from a tarball — so the host `.deb` and venv are
skipped entirely. The host still provides: hardening, postgres, nginx, and
backup.

## Docker + host Postgres (TCP over the bridge)

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

`70-docker.sh` prepares the host: postgres listens on `*` and pg_hba allows
the docker bridge subnet (172.16.0.0/12) using the cluster's own
`password_encryption` policy (`md5` or `scram-sha-256` — inherited clusters
often force md5 in a `conf.d` file, and a `scram-sha-256` line then rejects
every role created under the md5 policy). External 5432 stays closed by ufw
(10-base.sh) and the pg_hba scoping — so `*` is not an open door.

Per project, create a role + database:

```bash
DB_NAME=myproj DB_USER=myproj bash scripts/72-pg-docker-user.sh
```

The script generates a password when you don't pass one, resets it on every
run (so the database and the file can never drift), and writes the credentials
to `/etc/odoo/db-credentials-<db>.env` (0600, group `app`).

Then in the project's docker-compose/docky config, point Odoo at the
host via the bridge gateway (plain Linux docker doesn't auto-provide
`host.docker.internal`, so add it explicitly — **a hosted-apps control plane does it for you**):

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

## Database credentials: which prefix does what

Three naming schemes coexist and mixing them up is the usual docky / hosted-apps
integration bug. `/etc/odoo/db-credentials-<db>.env` carries all of the
meaningful ones, so a project (or a CI job) can source one file:

| prefix | read by | note |
|---|---|---|
| `DB_*` (`DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`, `DB_FILTER`) | the Odoo container / app | the docky compose files map the `PG*` values into these |
| `PG*` (`PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, `PGPASSWORD`) | libpq: `psql`, CI job env, a hosted-apps `--env-file`, `pg_dump` | the deployment-env convention (Jung, Airandme CI) |
| `POSTGRES_*` (`POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD`) | a **postgres server container** bootstrap | NOT for the Odoo app — this is the docker `postgres` image's own contract |

`72-pg-docker-user.sh` accepts `DB_*` **or** `PG*` on input (PG\* wins) and
emits both on output; nothing in bedrock reads `POSTGRES_*`.

**Peer auth or password?** The venv instance uses peer auth over the unix
socket (`db_host = False`) and needs no password at all. Containers cannot use
peer auth (their uid never matches a PG role), so they need a password. To let
a container reuse the *same* runtime role as a venv instance — the step that
prepares a hosted-apps deployment of a project that already runs on the deb — give
that role a password explicitly:

```bash
RUNTIME_DB_PASSWORD=<secret> RUNTIME_DB_NAME=myproj \
  sudo -E bash scripts/20-postgres.sh
# writes /etc/odoo/db-credentials.env, leaves odoo.conf on peer auth
```

The password is stored as SCRAM even when the cluster policy is md5: a SCRAM
verifier also authenticates through a pg_hba line that says `md5`, whereas an
md5 verifier does not survive a `scram-sha-256` line. Setting a password is
additive and needs no restart — the running instance keeps using the socket.

**Ownership, not just access.** An app pointed at an EXISTING database needs the
runtime role to **own** it: `odoo/service/db.py::list_dbs()` enumerates with
`where datdba = (select usesysid … current_user)`, and with `dbfilter` set (which
a host serving several databases requires) an empty list means every request
303s to `/web/database/selector` — while the build, the container and the logs
all look fine. So when `72-pg-docker-user.sh` prepares an existing database:

```sql
ALTER DATABASE myproj OWNER TO myproj_runtime;   -- the role the app connects as
```

Two roles are the wrong shape for this: the app role would own the database
while the venv role keeps owning every table, and PostgreSQL refuses the
membership in both directions, so one of the two instances always lacks
something. Give the instance's own role a password instead.

**Two instances, one database (the cutover window).** Running the venv and the
container at the same time is fine for a short verification, but only with the
newcomer's cron threads at zero (`MAX_CRON_THREADS=0` on the new instance): two
copies of the same `ir.cron` double-send mail and can transmit fiscal documents
twice. Do **not** use a `DISABLE_CRONS`-style switch that runs
`UPDATE ir_cron SET active=false` — that mutates the customer's database and
outlives the cutover. And disable the legacy systemd unit, do not merely stop
it: a reboot would restore the double-crons state. Finally, a module update
during the cutover moves the schema forward, so the legacy process stops being a
faithful rollback — the dump is.

---

---

# Option C — hosted apps (mini-PaaS)

The tier where several applications share one VPS: a **control plane** creates
a container per app from a git push, the **host postgres** is the database, and
the **host nginx** serves each app on its own name. No control plane is
published by bedrock; bedrock prepares everything it consumes, so installing it
is the only remaining step:

```bash
sudo HOSTED_APPS_INSTALLER=/root/install-control-plane.sh bash bin/bedrock --with-paas
```

`73-hosted-apps.sh` guarantees, idempotently:

- containers reach the host cluster over TCP — `listen_addresses` is a
  **postmaster** parameter, so the script restarts the cluster once when it
  really changes (a reload silently does nothing and the container gets
  `connection refused`); the pg_hba rule is **inserted before** any catch-all
  reject, because pg_hba.conf is first-match;
- ufw lets the docker subnet reach 5432 while 5432 stays closed to the world
  (10-base.sh opens only 22/80/443; without the rule the symptom is
  `connection timed out`, which reads like a dead postgres);
- the `app` deploy user exists, is in the `docker` group, owns
  `/home/app/data` (where each app's filestore is mounted) and has an ed25519
  deploy key for its git remotes;
- the host nginx keeps its own vhosts in `sites-enabled/` while the control
  plane owns `conf.d/`, and `nginx -t` proves the two do not collide.

### doodba compatibility (opt-in, DIY)

A [doodba](https://github.com/Tecnativa/doodba) project (built with the
[doodba-copier-template](https://github.com/Tecnativa/doodba-copier-template) or
deployed with [lefilament's ansible role](https://github.com/lefilament/ansible_role_odoo_docker))
is a plain docker-compose stack whose odoo service is a project subimage built
`FROM tecnativa/doodba`, talking libpq `PG*` to a postgres over TCP. That is the
same contract the container tiers already provide, so bedrock installs **no
doodba tooling** — choosing doodba is like choosing docky: a decision the user
makes on top of the substrate, and the doodba install itself (copier template,
ansible role, subimage build) stays theirs. What the substrate already gives
such a stack:

- docker engine + compose plugin (`70-docker.sh`);
- the host postgres reachable from containers over TCP
  (`configure_pg_for_docker`: `listen_addresses`, pg_hba scoped to
  172.16.0.0/12, ufw rule, cluster restart when the parameter really changes);
- per-project `PG*` credentials in `/etc/odoo/db-credentials-<db>.env`
  (`72-pg-docker-user.sh`) — which **are** doodba's own connection variables
  (`PGDATABASE`/`PGUSER`/`PGPASSWORD`/`PGHOST`), so the file can be passed to
  compose as-is (`--env-file`).

To run one, add the minimal overrides to the generated compose (the template
otherwise ships its own `db` container, which is redundant on a bedrock host):

```yaml
services:
  odoo:
    extra_hosts:
      - "host.docker.internal:host-gateway"
    environment:
      PGHOST: host.docker.internal   # was: the template's db service
      # PGDATABASE / PGUSER / PGPASSWORD come from db-credentials-<db>.env
    # and remove the `db` service + depends_on
```

Nothing to enable in bedrock for this: the hosted-apps wiring **is** the whole
door, and it is exercised on every CI run by the `docker-pg` job (a container
reaching the host postgres over the bridge gateway — exactly what a doodba
stack does).

It does **not** install docky (the compose wrapper belongs to Option B) or ak
(the image aggregates its addons at build time), and it does not install the
control plane unless `HOSTED_APPS_INSTALLER` points at one.

Per-app settings stay app-specific and are printed at the end of the layer:
publish `http:80:8069` + `https:443:8069` + the 8072 chat port, raise the
client body size to 200m and the read timeout to 720s, route `/websocket` to
8072, mount the filestore under `/home/app/data/<app>` with the app uid, give
the container `host.docker.internal` (host-gateway), feed it `DB_*` from
`/etc/odoo/db-credentials-<db>.env`, and declare a `/web/health` check in the
image — without it the app receives traffic ~10s after start, while the
registry is still loading.

# Common to all options

## PostgreSQL major upgrade (keeping the data)

`20-postgres.sh` installs binaries only; it never touches an existing
cluster. To move a live cluster to a new major, on a host where both majors
are installed:

```bash
pg_lsclusters                                   # note the online cluster + port
pg_upgradecluster --check -v 18 15 main         # validates packages/extension bumps
time pg_upgradecluster --method=upgrade -v 18 15 main
```

- `--method=upgrade` is pg_upgrade with a full COPY: the old cluster stays
  intact (moved to the next free port, `start.conf=manual`), so rollback is
  `pg_dropcluster 18 main` + `pg_ctlcluster 15 main start` after restoring
  its port. Needs free space for a second copy of the data.
- `--method=dump` (the default) is a pg_dumpall/restore: slower, safest.
- Checksums are handled: postgresql-common adds `--no-data-checksums` for
  18+ when the old cluster has none (18 enables them in initdb by default).
- Extensions must exist for the new major; contrib ships inside the
  postgresql-NN package on PGDG, `postgresql-contrib-NN` on some distros.
- Test the app before `pg_dropcluster` on the old major, and only then purge
  the retired binaries/dev packages.

## nginx never hijacks a live domain

`50-nginx.sh` refuses to render a vhost whose `server_name` is already
declared by another enabled site (nginx would silently serve whichever
duplicate block loads first — typically how a fresh, empty instance takes
over a production domain). Deliberate takeover: `FORCE_NGINX=1`.

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

The tuning always targets the cluster that is ONLINE (fallback: newest
major installed) — never "the first directory in /etc/postgresql", which
after a major upgrade is the retired cluster.

Every value is overridable via a PG_* env var (see the environment
variables section), e.g. `PG_SHARED_BUFFERS=2GB`. Anything else — or a
final override of the above — goes in PG_EXTRA_CONF, one "key = value" per
line, appended LAST so it wins:

```bash
export PG_SHARED_BUFFERS=2GB
export PG_EXTRA_CONF="max_connections = 200
synchronous_commit = off"
```

`listen_addresses` is deliberately NOT set here: venv Odoo talks to
postgres over the unix socket, so the port stays closed by default. It is
opened only in the docker option (70-docker.sh), gated by pg_hba + ufw.

## Backups

60-backup.sh installs `/usr/local/bin/odoo-backup` plus a nightly cron
(03:17) doing a `pg_dump -Fc` of the selected databases, a
`pg_dumpall --globals-only` (roles/passwords, makes a bare restore
possible) and a tar of the Odoo filestore(s).

It is configured in **`/etc/odoo-backup.conf`**, created on the first run
and never overwritten afterwards (re-running the script only refreshes the
helper and the cron entry):

```bash
BACKUP_DBS="all"          # or: "prod_db other_db" — space-separated
BACKUP_FILESTORE="yes"
RETENTION_DAYS="7"
RCLONE_REMOTE=""          # off-site copy, needs rclone
EXTRA_FILESTORE_DIRS=""   # filestore dirs auto-discovery misses
```

Seed the database list directly on the first run:

```bash
sudo BACKUP_DBS=prod_db bash scripts/60-backup.sh
```

**Always list the real business databases instead of relying on `all`.**
Shared and inherited hosts accumulate old copies, CI databases and
vestigial prod DBs: dumping everything exhausts the disk in a night or two
(the default is a safety net, not a backup platform — premium setups get
gobackup/barman). With an explicit list, only the filestore
sub-directories named after those databases are archived, which is where
most of the volume usually sits.

The filestore is auto-discovered, covering both options:

- venv:  /var/lib/odoo/.local/share/Odoo/filestore
- docker (dev):  /home/app/<project>/data/filestore
- docker (prod): /home/app/data/<project>/filestore

(the two docker shapes are the `./data/filestore` vs `~/data/<project>/filestore`
conventions from the docky template). Add `EXTRA_FILESTORE_DIRS` for an
exotic layout.

Retention is one knob for both kinds of archive; measure one night before
raising it (the filestore tar is typically 20x the dump). Set
`RCLONE_REMOTE` (e.g. `b2:backups/host`) so the archives leave the host.
Run `journalctl`-free checking with `tail /var/log/odoo-backup.log` and a
first manual `sudo /usr/local/bin/odoo-backup` — then confirm a restore:
`pg_restore -l /var/backups/odoo/*-<db>.dump | head`.

## CI

GitHub Actions (.github/workflows/ci.yml) runs on every push:

- **lint** — shellcheck over all scripts.
- **install** — a REAL install job per README "OK" cell: runs the
  bedrock scripts inside the actual distro container (Debian 12/13,
  Ubuntu 22.04/24.04 × Odoo 16/17/18/19), starts postgres, installs
  mis_builder + web_responsive on a fresh db, checks Odoo serves HTTP,
  and verifies a staging instance boots.
- **tools** — installs docky (PyPI) and ak (git) via pipx on each of
  the four distros, so our own tooling is proven installable everywhere.
- **docker-pg** — proves a container reaches host postgres over
  host.docker.internal (the docker-option pattern).
