# odoo-debian-bedrock

Akretion's minimal, layered Odoo host installation for Debian/Ubuntu.

(Not to be confused with acsone/odoo-bedrock, the excellent Docker base
image we already use in our docky installs — that image remains the
Layer 2/3 app runtime; odoo-debian-bedrock is the HOST layer beneath it.)

The idea: the official Odoo deb package gives you the boring 15%
(system user, /etc/odoo/odoo.conf, postgres role, logrotate, base
systemd unit). bedrock adds the production 85% as a thin, auditable
overlay of idempotent shell scripts — no Ansible, no Proxmox, no
framework to learn.

## Layers

- **Layer 1 (default):** official odoo deb + a venv layered on top with
  `--system-site-packages` for OCA addons (`odoo-addon-*`) and pinned
  Python deps. apt and pip never manage the same directory, so
  unattended-upgrades keeps working without breaking the install.
  This is the tier for small on-premise customers and the basis of the
  public PT-BR install guide.
- **Layer 2 (`--with-docker`):** everything from Layer 1 host prep,
  plus Docker + docky for docker-compose based projects
  (docky-odoo-template-shared). The Odoo app itself then runs in
  containers built from the same pinned addon set.

## Layout

```
bin/bedrock            orchestrator: run all or selected steps
scripts/10-base.sh     host hardening basics, unattended-upgrades
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

One-liner (git NOT required — fetches a tarball):

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
export OCA_ADDONS="odoo-addon-l10n_br_base odoo-addon-l10n_br_fiscal"
export DOMAIN=odoo.example.com    # enables the nginx vhost (50-nginx.sh)
export CERTBOT_EMAIL=you@example.com  # unattended Let's Encrypt issuance
export PGDG=1                     # use postgresql.org repo instead of distro PG
```

## Compatibility matrix

What the official deb + bedrock overlay support, per distro Python
(Odoo 19+ needs Python >= 3.12; the deb resolves the rest):

| Distro                    | Python | Odoo 16 | 17 | 18 | 19 | 20 |
|---------------------------|--------|---------|----|----|----|----|
| Debian 12 (bookworm)      | 3.11   | OK      | OK | OK | -- | -- |
| Debian 13 (trixie)        | 3.13   | ??      | ?? | OK | OK | OK |
| Ubuntu 22.04 LTS (jammy)  | 3.10   | OK      | OK | OK | -- | -- |
| Ubuntu 24.04 LTS (noble)  | 3.12   | OK      | OK | OK | OK | OK |

Notes:

- "OK" on 18/trixie is validated end-to-end by this repo's testbed
  (deb install + venv overlay + l10n_br_nfe test suite passing).
- On trixie the nightly deb still depends on the removed
  python3-pypdf2 package — 30-odoo-deb.sh auto-installs a tiny equivs
  shim (Odoo imports pypdf). Harmless elsewhere.
- Odoo 16/17 on Python 3.13 (trixie) is untested and likely fragile —
  use bookworm/jammy for those series.
- Odoo 20 is unreleased at writing; support assumed identical to 19.
- The nginx vhost adapts to the Odoo series automatically
  (/websocket for >= 16, /longpolling/ for older).

## Why not pip --break-system-packages?

pip and dpkg managing the same /usr/lib/python3/dist-packages
directory is unsound: either tool can silently overwrite the other's
files, and an apt security upgrade can downgrade a pinned
cryptography/pyopenssl under your feet. The venv overlay gives pip a
private site-packages that shadows the system one — same convenience,
no fight.
