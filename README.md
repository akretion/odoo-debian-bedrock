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

## Usage (as root on a fresh Debian 13 / Ubuntu 24.04)

```bash
export ODOO_VERSION=18.0          # odoo series to install
export ODOO_ADMIN_PASSWD=...      # odoo master password
export OCA_ADDONS="odoo-addon-l10n_br_base odoo-addon-l10n_br_fiscal"
./bin/bedrock                     # layer 1
./bin/bedrock --with-docker       # layer 1 + layer 2
```

## Why not pip --break-system-packages?

pip and dpkg managing the same /usr/lib/python3/dist-packages
directory is unsound: either tool can silently overwrite the other's
files, and an apt security upgrade can downgrade a pinned
cryptography/pyopenssl under your feet. The venv overlay gives pip a
private site-packages that shadows the system one — same convenience,
no fight.
