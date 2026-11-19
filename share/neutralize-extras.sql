-- neutralize-extras.sql — the gaps core's own data/neutralize.sql leaves open on
-- a COPY of production. Applied AFTER that file, never instead of it.
--
-- Why two files and not one: the base layer is the series' OWN file, read out of
-- the installed Odoo (base/data/neutralize.sql, imported by `odoo neutralize`).
-- It is version-correct by construction — 18 added the webhook update, 19 added
-- the SMTP-credential wipe and `database.secret`, 16 has neither — so a single
-- vendored copy cannot serve 16→20. Whatever core does is therefore NOT repeated
-- here (crons except autovacuum, outgoing mail servers + dummy fallback,
-- database.is_neutralized, webhooks on 18+).
--
-- What is left for a COPY, and stays deliberately basic: things core leaves
-- alone because they are not part of Odoo's own "neutralize a production
-- database for a demo" notion — queued work that fires at the first clone boot,
-- incoming mail, payment providers, the copy's URL, the environment ribbon.
-- Every statement that touches an optional table/column is GUARDED, so the file
-- is portable and a missing module is a no-op.
--
-- Project facts (fiscal environment, discuss history, third-party API URLs,
-- admin password policy) do NOT belong here: they go in the project hooks.
--
-- Usage (psql variables are mandatory):
--   psql -v ON_ERROR_STOP=1 -d <db> -v seed_url='https://staging.example.com' \
--        -v seed_label='STAGING' -v seed_color='rgba(255,153,0,.6)' \
--        -f neutralize-extras.sql
BEGIN;

-- 1. Every scheduled action off — INCLUDING base.autovacuum, which core keeps
--    active on purpose (it is a vacuum, not a business action). A seed is cloned
--    many times a day; a clone that boots with an active business cron is how
--    staging ends up sending real mail.
UPDATE ir_cron SET active = false;

-- 2. Incoming mail (core only handles outgoing) -------------------------------
DO $$
BEGIN
    IF to_regclass('fetchmail_server') IS NOT NULL THEN
        UPDATE fetchmail_server SET active = false;
    END IF;
END $$;

-- 3. Queued work that fires at the first clone boot ---------------------------
DO $$
BEGIN
    IF to_regclass('mail_mail') IS NOT NULL THEN
        DELETE FROM mail_mail;
    END IF;
    IF to_regclass('mail_message_res_partner_needaction_rel') IS NOT NULL THEN
        DELETE FROM mail_message_res_partner_needaction_rel;
    END IF;
    IF to_regclass('queue_job') IS NOT NULL THEN
        DELETE FROM queue_job;
    END IF;
END $$;

-- 4. Payment providers in test mode: a clone must never charge a card --------
DO $$
BEGIN
    IF to_regclass('payment_provider') IS NOT NULL THEN
        UPDATE payment_provider SET state = 'test' WHERE state = 'enabled';
    END IF;
END $$;

-- 5. Webhooks on the series where core does not neutralise them yet (18+) ----
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_name = 'ir_act_server'
                  AND column_name = 'webhook_url') THEN
        UPDATE ir_act_server
           SET webhook_url = 'neutralization - disable webhook'
         WHERE state = 'webhook';
    END IF;
END $$;

-- 6. The copy knows its own address ------------------------------------------
UPDATE ir_config_parameter SET value = :'seed_url' WHERE key = 'web.base.url';

-- 7. Environment ribbon (OCA web_environment_ribbon) -------------------------
-- The module's views/assets come from a real install on the seed
-- (`odoo -i web_environment_ribbon`, done by the seed builder); its LOOK comes
-- from these two parameters, so every clone wearing the same seed is labelled.
INSERT INTO ir_config_parameter (key, value) VALUES ('ribbon.name', :'seed_label')
     ON CONFLICT (key) DO UPDATE SET value = :'seed_label';
INSERT INTO ir_config_parameter (key, value) VALUES ('ribbon.background.color', :'seed_color')
     ON CONFLICT (key) DO UPDATE SET value = :'seed_color';

COMMIT;
