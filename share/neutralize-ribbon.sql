-- neutralize-ribbon.sql — the environment ribbon's LOOK, applied AFTER
-- `odoo -i web_environment_ribbon` on the seed.
--
-- Why after, and UPDATE-only: the module's own data file CREATES the two
-- ir_config_parameter rows (ribbon.name, ribbon.background.color). Inserting them
-- before the install makes that data file die on
-- "duplicate key value violates unique constraint ir_config_parameter_key_uniq",
-- which aborts the whole module graph — the seed then ends up with the module
-- still 'to install'. UPDATE-only is also the honest behaviour when the module is
-- not installed at all (0 rows, no harm) and when it already was installed in
-- production (2 rows, re-labelled).
--
-- Parameters read by web_environment_ribbon (OCA/web): ribbon.name accepts
-- {db_name} formatting and is injected as HTML; ribbon.color colours the text;
-- ribbon.background.color the ribbon itself.
--
-- Usage: psql -v ON_ERROR_STOP=1 -d <seed> \
--          -v seed_label='STAGING' -v seed_color='rgba(255,153,0,.6)' \
--          -f neutralize-ribbon.sql
BEGIN;

UPDATE ir_config_parameter
   SET value = :'seed_label'
 WHERE key = 'ribbon.name';

UPDATE ir_config_parameter
   SET value = :'seed_color'
 WHERE key = 'ribbon.background.color';

COMMIT;
