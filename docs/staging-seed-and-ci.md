# Staging seed + on-prem CI (design proposal)

Status: PROPOSAL, not implemented. Nothing in this document has been applied to
a host yet. Written after the tecservice18 bedrock standardization.

## 1. Goal

Give every non-production consumer of a customer's data a **cheap, disposable,
neutralized copy of production**, without touching the production database and
without a per-run dump:

- an on-prem CI job that tests a branch against **real data (no demo data)**;
- a long-lived **staging** instance the customer logs into and approves;
- (later) a paid off-site backup, out of scope here.

Non-goals: replacing 60-backup (the seed is *derived from* its dump), CI
provider migration, multi-tenant SaaS.

## 2. Why a "seed" database and not "copy prod"

`CREATE DATABASE x TEMPLATE prod` is impossible while prod runs: PostgreSQL
refuses to copy a database that has open sessions, and a production Odoo always
has workers connected. The only ways to read prod are `pg_dump`/`pg_basebackup`.

Doing a dump+restore per test run costs minutes and puts read-I/O on the prod
instance at a random time of day. So we materialize the dump **once a day**, in
a database nobody ever connects to, which then serves instant copies:

    prod (busy)  --pg_dump 03:17-->  /var/backups/odoo/*.dump
                                          |
                                   04:10  v  restore + neutralize
                                  seed DB (IDLE, phase 4 below)
                                    |        |         |
                        createdb -T |        |         |
                                    v        v         v
                             test_<run>  staging   throwaway experiments

Constraints the design must respect (single PG cluster, modest disk):

- **The seed must be idle.** Every consumer takes a *copy*; nobody connects to
  the seed itself. This single invariant is what makes `TEMPLATE` copies
  possible at any moment and what lets tomorrow's refresh drop it.
- **Neutralize once, in the seed, not per copy.** A copy made after the seed is
  neutralized inherits the neutralization. A copy made before is a live fiscal
  and e-mail cannon — see §6.
- **Distinct roles.** The consumer roles must never be able to authenticate as
  the production role, and the production role must not be a member of them.

## 3. Objects and roles

Example for Tecservice (names are the defaults proposed for the script; every
one is configurable).

| object            | name                          | owner          | notes |
|-------------------|-------------------------------|----------------|-------|
| prod DB           | `tecservice18`                | `odoo`         | peer auth, instance on 9089 |
| seed DB           | `tecservice18_seed`           | `odoo_seed`    | idle, refreshed nightly, never served |
| staging DB        | `tecservice18_staging`        | `odoo-staging` | long-lived, customer approval |
| CI test DBs       | `ci_tecservice18_<run_id>`    | `odoo_ci`      | throwaway, dropped by the job |
| staging instance  | `odoo-staging.service`        | runtime `odoo-staging` | port 8070/8073 (81-staging.sh defaults) |

Role properties:

```
odoo            NOSUPERUSER NOCREATEDB   # prod only; owns nothing else
odoo_seed       NOLOGIN NOSUPERUSER NOCREATEDB   # owns the seed, logs in as nobody
odoo-staging    NOLOGIN NOSUPERUSER NOCREATEDB   # peer auth as the runtime user
odoo_ci         LOGIN NOSUPERUSER CREATEDB       # runner user; owns the seed too *
```

\* `CREATE DATABASE ... TEMPLATE seed` requires being a superuser or **the owner
of the seed**, so the CI role must own the seed. That is acceptable: owning the
seed only lets it copy/drop the seed, not read prod. It must NOT be a member of
`odoo`, and `odoo` must not be a member of it.

Alternative considered and rejected: rotating the seed owner daily. It adds no
security (each role can still copy the seed while it exists) and breaks grant
bookkeeping. A dedicated stable role is enough.

Naming compatibility: Akretion France's `bin/get_db/get_db.py` (Favex) already
implements the same pattern with the convention
`<project>_<ver>_spare_N` > `<project>_<ver>_template` > `<project>_template` >
`template1`, and accepts any name via `--force_template`. Naming the seed
`<db>_template` makes that script usable unchanged; naming it `<db>_seed` costs
nothing but one flag. **Decision needed (§11).**

## 4. Seed lifecycle (`82-db-seed.sh`, new script)

### 4.1 Refresh (nightly, after the backup)

```
1. pick the dump:  latest /var/backups/odoo/*-<source_db>.dump
   abort if its mtime is older than 24h  (backup failed -> never recycle an
   old dump silently)
2. dropdb --if-exists <seed>_new
   createdb -O <seed_role> <seed>_new
   pg_restore --no-owner --role=<seed_role> -d <seed>_new <dump>
3. neutralize <seed>_new   (§6)
4. swap, seed idle assumption enforced by PostgreSQL itself:
     ALTER DATABASE <seed>       RENAME TO <seed>_old   -- fails if a copy is in progress
     ALTER DATABASE <seed>_new   RENAME TO <seed>
     DROP DATABASE <seed>_old WITH (FORCE)              -- PG13+, kills stale sessions
5. filestore: rsync --link-dest=<prod>/filestore/<source_db> \
       <prod>/filestore/<source_db>/ <seed_store>/<seed>/     (hardlinks)
6. verify: row counts + owner, then exit non-zero on any failure
```

- Step 4 failing because a copy is running is a **non-event**: retry the next
  night, or run on demand. Never force it.
- Keeping exactly one `<seed>_old` gives a one-command rollback if the new seed
  is broken (`--rollback`).
- Restoring into `_new` and renaming gives an atomic swap: consumers never see a
  half-restored seed.
- Do **not** mark the seed `datistemplate = true`. It is not needed for
  `TEMPLATE` copies, it requires superuser, and it would make 60-backup skip it
  only by accident. 60-backup is already scoped to an explicit DB list, which is
  the correct exclusion mechanism.

### 4.2 Clone (the consumer operation, seconds)

```
createdb -O <target_role> -T <seed> <dst>
rsync -a --link-dest=... (filestore, hardlinks)
```

- `DROP DATABASE <dst> WITH (FORCE)` before recreating (PG13+).
- Copy cost on this host is a file copy of ~1.1 GB (measure it once during
  rollout; expected seconds). If it ever stops being cheap, the pre-made
  `<dst>_spare_N` + `ALTER DATABASE ... RENAME` trick from get_db.py removes the
  copy entirely at the price of one extra DB per spare (not worth it on a host
  with ~10 GB free).
- The clone is **neutralized by inheritance**: it is a byte copy of a
  neutralized seed.

### 4.3 Garbage collection

```
82-db-seed.sh --gc 7
```
Drops `ci_<db>_*` databases older than N days (a killed runner job leaves one
behind) and refuses to touch anything not matching the configured prefixes.

## 5. Filestore

Hardlinks (`--link-dest` / `cp -al`) are correct here and nearly free:

- Odoo's filestore is content-addressed and append-mostly; editing an
  attachment writes a new file, deleting one only unlinks a name.
- A hardlinked copy therefore cannot be corrupted by normal Odoo use in either
  direction.

Caveats: same filesystem only (`df` first — `/var/lib/odoo` and the staging home
must be on `/`); a module that rewrites a file **in place** would affect both
copies (rare, and the reason the staging instance must not be pointed at prod's
filestore *directory* — the hardlink copy is a different directory tree).

Each database gets a filestore directory **named after itself**; that is
mandatory and is the step people forget when they only copy the DB.

## 6. Neutralization (once per seed refresh)

Do it by **instance config** and by **SQL**, because the SQL is wiped at the
next refresh and anything the instance does between restore and `UPDATE` has
already happened.

Config (staging instance, survives every refresh):

```
max_cron_threads = 0
```

SQL on `<seed>_new`, before the swap:

```sql
UPDATE ir_cron SET active = false;
UPDATE ir_mail_server SET active = false;
UPDATE fetchmail_server SET active = false;
DELETE FROM mail_mail;
DELETE FROM mail_message_res_partner_needaction_rel;   -- optional, noisy UI
UPDATE ir_config_parameter SET value = '<staging url>' WHERE key = 'web.base.url';
-- payment providers -> test environment
UPDATE payment_provider SET state = 'test' WHERE state = 'enabled';
```

Brazil-specific, and the reason this section exists at all: **an authorized
NF-e/NFS-e/DPS from a restored production DB is a real fiscal document emitted
under the production CNPJ.** Before any consumer can reach the data, disable
transmission in the fiscal configuration (l10n_br_fiscal_edi / NFS-e settings,
and the certificate/NFS-e job if present), and keep the seed's
`ir_cron` off so no scheduled transmission can start. Check `mail.catchall.domain`
too.

## 7. CI flows

### 7.1 Today

- `tecservice/.github/workflows/test.yml` — GitHub-hosted, OCA CI image, demo
  data, PG service pinned to **postgres:12.0** while production runs **PG 15**
  (mismatch worth fixing; Odoo 18 → `postgres:15`).
- `pre-commit.yml` — fine.
- No on-prem job. `airandme` has one (`staging.yml`) and it is the model, with
  three defects to fix rather than copy: it puts `secrets.CI_DB_PASSWORD` in the
  job env (peer auth makes it unnecessary), it gives the runner the **docker
  socket** (root on the host), and its `TEMPLATE_DB: staging` has no refresh job
  anywhere, so it drifts silently.

### 7.2 Proposed chain

```
push to 18.0*  /  PR to 18.0
  |
  |-- job "pre-commit"            GitHub-hosted        no secrets, seconds
  |-- job "test" (demo data)      GitHub-hosted        OCA image, PG 15
  |
  +--> on success, workflow "on-prem (real data)"
         runs-on: [self-hosted, tecservice]
         triggered by: workflow_run  (so untrusted PR code never runs on the host)
         |
         |-- clone seed -> ci_tecservice18_<run_id>            (seconds)
         |-- odoo -d $TEST_DB -u all --stop-after-init         (schema sync)
         |-- odoo -d $TEST_DB --test-tags /tecservice_*        (tests, no demo)
         |-- on success: print "promotable <run_id>"  (+ artifact)
         `-- always: dropdb $TEST_DB
```

Promotion is deliberately **not** automatic from a branch push (any branch push
would then replace the customer's staging). Two options, decide (§11):

- **A (recommended).** `workflow_dispatch` "promote-staging" with a GitHub
  Environment requiring a reviewer: renames the *tested* DB into
  `tecservice18_staging`, or clones the seed fresh if the tested DB is gone,
  then restarts the staging unit.
- **B.** Auto-promote only on pushes to a `staging` branch, guarded so fork PRs
  can never reach the runner.

Production deploy stays a manual, human-run step (bedrock's deploy flow) until
the staging approval ritual proves itself.

## 8. Self-hosted runner: threat model

A self-hosted runner executes whatever the workflow file says. On a customer
server that means the runner user is a **trust boundary**, not a convenience.

| risk | consequence | mitigation |
|---|---|---|
| workflow code runs as the `odoo` user | full read of prod DB + filestore (peer auth) | dedicated `gh-runner` / `odoo_ci` user; never `odoo`, never root |
| docker socket on the runner | root on the host (container escape / `-v /`) | run tests in the **staging venv**, no docker; if a container is unavoidable, rootless podman |
| secrets in job env (`PGPASSWORD`) | any branch push exfiltrates them | peer auth over the unix socket: no password to steal |
| `pull_request` trigger from forks | untrusted code on the prod host | `workflow_run` after the GitHub-hosted job, restricted to in-repo branches; GitHub "require approval for first-time contributors" |
| token scope | push/deploy rights inside the job | `permissions: contents: read`; no PAT, no production SSH key; read-only deploy key for clones |
| state between jobs | one job's leftovers break the next | `--ephemeral` runner registration + `dropdb` in `trap`/`always()` |
| DB sprawl | disk fills up | `82-db-seed.sh --gc`, plus the job drops its own DB |

The runner user needs exactly: login as its own PG role with `CREATEDB`, write
access to its own filestore directory, and a read-only deploy key. Nothing else.
Verify with `id`, `\du`, and by trying the forbidden operations once
(`psql -d tecservice18 -c 'select 1'` must fail).

## 9. Staging instance: venv, not dokku

Recommendation: **venv instance via `81-staging.sh`**, owned by `odoo-staging`.

- same core deb as prod, so a staging bug is not an image bug;
- independent venv → independent odoo-addon pins per branch, which is the whole
  point of testing a branch;
- no docker socket and no image build in the loop (seconds, not minutes);
- the CI job can reuse that same venv, so "the tests passed" and "staging runs"
  mean the same dependency set;
- dokku stays available for unrelated apps (it is already installed and shares
  the host nginx); it adds a build + proxy layer that buys nothing here.

Dokku is still a reasonable choice if the customer wants a "one container per
branch" story later; the seed is orthogonal to it (a dokku app can connect to
`tecservice18_staging` over `host.docker.internal`/`172.17.0.1` exactly like the
existing containers do).

## 10. bedrock amendments, in implementation order

1. **`scripts/82-db-seed.sh`** (new). Subcommands `refresh`, `clone <dst>
   --owner <role>`, `gc [days]`, `rollback`, `status`; config in
   `/etc/odoo-seed.conf` seeded once (like `/etc/odoo-backup.conf`), so a
   re-run/update never clobbers the operator's choices. Cron installed with
   `--install-cron` at 04:10 (after 60-backup's 03:17).
2. **`scripts/81-staging.sh`**: `STAGING_SEED_DB=<seed>` provisions the staging
   DB from the seed (clone + filestore hardlink) instead of leaving it empty;
   render `max_cron_threads = 0` in the instance conf; optional
   `STAGING_BASIC_AUTH=user:pass` on the vhost until the customer is invited.
3. **`templates/odoo-instance.conf`**: add `max_cron_threads = @MAX_CRON_THREADS@`.
4. **`scripts/74-gh-runner.sh`** (new, optional but recommended): installs an
   `--ephemeral` runner as a dedicated user, with the §8 checklist enforced and
   printed (repo settings the script cannot do from the host: environment
   reviewers, fork-PR policy).
5. **`templates/ci/staging.yml`**: the project-side workflow template (no
   secrets, no docker, `workflow_run`), so the next project copies a file
   instead of re-deriving the design.
6. **README**: new section "Staging seed and on-prem CI" (+ the reference doc).
7. Extend this repo's reference doc (`references/staging-db-refresh.md` in the
   Hermes skill) with the seed layer, the get_db.py naming compatibility and the
   threat model.

`60-backup.sh` needs no change: the seed consumes its dump. It does need its
`BACKUP_DBS` **not** to include the seed (it is an explicit list, so this is
already true) and the seed refresh must fail loudly when the dump is stale.

## 11. Decisions needed before coding

1. **Seed name**: `<db>_seed` (clear) or `<db>_template` (drop-in compatible with
   Akretion France's `get_db.py`)?
2. **Promotion trigger**: manual `workflow_dispatch` with a reviewer (A,
   recommended) or auto on a `staging` branch (B)?
3. **On-prem tests run in the staging venv (no docker socket)** — accept that
   the job uses the staging venv's pinned addons instead of the OCA CI image?
4. **Disk**: the staging layer needs ~2.2 GB steady + ~2.2 GB transient on top
   of ~8.4 GB of nightly backups, against ~14 GB free. Prune the ten stale
   `bk-*` databases (~9.2 GB) first? They are currently the only safety net
   besides the new nightly backup (which by then will have a week of history).
5. **Runner scope**: install it now on odoo.tecservice.com.br (it will also need
   a GitHub-side registration token), or stage the whole thing on a copy of the
   workflow first?

## 12. Rollout sequence (once the decisions are taken)

1. Prune `bk-*` DBs after the backup has run for a few nights (frees ~9 GB).
2. Create `odoo_seed` + `82-db-seed.sh`; run one refresh **by hand** and verify:
   owner, row counts vs prod, neutralization (`ir_cron` all inactive), filestore
   hardlink count, then `time createdb -T` a throwaway copy and drop it.
3. Install the refresh cron.
4. `81-staging.sh` with `STAGING_SEED_DB`; verify the customer can log in on the
   staging domain and that **nothing** can emit a fiscal document.
5. Install the runner as `gh-runner` + `odoo_ci`; prove the CI job clones the
   seed, tests, and cleans up.
6. Wire `workflow_run` chaining and the promotion job.
7. Only then consider the paid off-site backup.
