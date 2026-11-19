-- neutralize-filestore.sql — a seed/clone must not depend on ANY file from
-- production, and no production file may ever reach a staging host.
--
-- Why this exists: `createdb -T` copies the DATABASE, not the filestore. The
-- attachment rows it brings point at files that live in the filestore of the
-- database the seed was cloned into, so a clone whose filestore directory is not
-- that one answers 500 on every compiled bundle:
--   FileNotFoundError: .../filestore/<db>/aa/aa6baa9…  (web.assets_web.min.css)
-- Copying production's filestore fixes the 500s and is the wrong answer: it is
-- heavy (measured: 1.5 GB for 23k rows on a small Brazilian ERP) and it ships the
-- customer's invoices, employee documents and images onto a staging host.
--
-- So the seed is made filestore-FREE in three guarded steps:
--   1. compiled asset bundles: DELETE the rows. Every database regenerates them
--      from its own code and ir_asset definitions on the next request — which is
--      what you want anyway, since a staging clone often runs different code.
--   2. module static files: DELETE the index rows. Those files ship in the
--      addons and are served from there; the row is only a cache entry.
--   3. everything else is a production document. Keep the row (counts, links and
--      tests that reference it stay coherent) but blank the pointer, so Odoo
--      serves an empty stream instead of raising FileNotFoundError.
--
-- Consequence, accepted on purpose: business attachments (invoice PDFs, images,
-- employee documents) are EMPTY in staging. Files generated in staging (reports,
-- exports, new uploads) are written normally to that database's own filestore.
BEGIN;

DELETE FROM ir_attachment WHERE url LIKE '/web/assets/%';
DELETE FROM ir_attachment WHERE url LIKE '%/static/%';

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_name = 'ir_attachment' AND column_name = 'file_size') THEN
        UPDATE ir_attachment SET store_fname = NULL, file_size = 0
         WHERE store_fname IS NOT NULL;
    ELSE
        UPDATE ir_attachment SET store_fname = NULL
         WHERE store_fname IS NOT NULL;
    END IF;
END $$;

COMMIT;
