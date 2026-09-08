"""Marker module for the odoo-debian-bedrock 'odoo' stub distribution.

The real Odoo comes from the official deb in dist-packages, made visible
to the venv via --system-site-packages. This stub only exists so that
pip's resolver sees an 'odoo' distribution when installing odoo-addon-*.
"""
