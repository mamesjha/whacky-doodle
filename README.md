# whacky-doodle

A self-contained bootstrap kit for standing up a Postgres database that
matches the **TDM PoC** OLTP schema — the same shape used by the
synthetic-data corpus and by the Alation data-dictionary upload.

## What's in here

```
postgres/
├── schema.sql       # 24-table OLTP DDL with {schema} placeholder
└── bootstrap.sh     # one-shot apply-to-DSN script (Bash + psql)
```

That's it. No Python, no Docker, no dependencies beyond `bash` and `psql`.

## Quick start

```bash
# 1. Provision a Postgres anywhere (Neon free tier shown — see below for others)
#    Grab the connection string the provider hands you.

export DSN='postgresql://USER:PASS@HOST:5432/DBNAME?sslmode=require'

# 2. Apply the prod (unmasked) schema
./postgres/bootstrap.sh prod_bronze

# 3. (Optional) apply the lower (masked) schema in the same database
./postgres/bootstrap.sh lower_bronze

# 4. Verify
psql "$DSN" -c "\dt prod_bronze.*"
```

You should see 24 tables under `prod_bronze` — `oltp_countries`,
`oltp_currencies`, `oltp_individuals`, `oltp_cards`,
`oltp_card_transactions`, etc., plus `audit_event_log`.

## What the schema looks like

24 tables organized as a small banking OLTP system:

| Domain          | Tables                                                                                          |
| --------------- | ----------------------------------------------------------------------------------------------- |
| Reference       | `oltp_countries`, `oltp_currencies`, `oltp_departments`                                         |
| Party / identity | `oltp_parties` (polymorphic), `oltp_individuals`, `oltp_organizations`                         |
| Addresses       | `oltp_addresses`, `oltp_party_addresses`                                                        |
| Customer        | `oltp_customers`                                                                                |
| Accounts        | `oltp_accounts`, `oltp_account_holders`                                                         |
| Cards (PCI)     | `oltp_cards`                                                                                    |
| Transactions    | `oltp_card_transactions`, `oltp_transactions`                                                   |
| Employees       | `oltp_employees` (self-ref manager hierarchy)                                                   |
| Support         | `oltp_support_tickets`, `oltp_ticket_messages`                                                  |
| Telemetry       | `oltp_devices`, `oltp_sessions`                                                                 |
| GDPR            | `oltp_consent_records`, `oltp_deleted_individuals_archive`                                      |
| Invoices        | `oltp_invoices`, `oltp_invoice_lines`                                                           |
| Audit           | `audit_event_log`                                                                               |

Notable shape:

* **Polymorphic party** — `oltp_parties` is the supertype; `oltp_individuals`
  and `oltp_organizations` are subtype tables keyed by `party_id`.
* **Self-referencing FK** — `oltp_employees.manager_id → oltp_employees.employee_id`.
* **Deepest declared chain (5 hops)** — `customers → account_holders → accounts → cards → card_transactions → invoices`.
* Every table carries `_ingested_at` / `_source_op` metadata columns to match
  the bronze-layer CDC contract.

The DDL is parameterized: `{schema}` is replaced by the value you pass to
`bootstrap.sh` (default `prod_bronze`). Re-run the script with a different
schema name to mirror the same shape into a second namespace — that's how
`prod_bronze` (unmasked source) and `lower_bronze` (masked target) coexist
in one database.

## Choosing a host

Any Postgres 12+ works. Common options:

| Provider                                  | Why                                                                                         |
| ----------------------------------------- | ------------------------------------------------------------------------------------------- |
| [Neon](https://neon.tech)                 | Free tier (10 GB, Postgres 16). Connection string in 30 seconds. Always-on TLS.             |
| [Supabase](https://supabase.com)          | Free tier (500 MB). Adds a UI / REST layer on top.                                          |
| [Railway](https://railway.app) / [Render](https://render.com) | Tiny free credits. Good for throwaway demos.                              |
| AWS RDS for Postgres                       | Production. Use a security group inbound rule on 5432 + `rds.force_ssl=1`.                  |
| GCP Cloud SQL                              | Production. Same idea — authorized networks + SSL enforced.                                 |
| Aiven / Crunchy Bridge                     | Compliance-friendly (SOC2 / HIPAA available).                                               |

## Hooking it up to Alation

This DDL is the source-of-truth for the data dictionary in the parent
`env_tonic/tdm_poc/` repo. Once the schema is loaded:

1. Register the database in Alation as a new data source. Capture the
   numeric `ds_id` Alation assigns it (it appears in the URL:
   `/app/data/<ds_id>/...`).
2. Run a crawl. Wait for the 24 tables to appear under `prod_bronze`
   (and / or `lower_bronze`).
3. Upload the matching dictionary CSV from
   `env_tonic/tdm_poc/corpus/alation_data_dictionary.prod_bronze.csv`
   (or `…lower_bronze.csv`) via the data source's Settings → Data
   Dictionary page.

The `key` format Alation expects on the per-data-source upload page is
`<schema>.<table>` and `<schema>.<table>.<column>` — which matches the
schema name you passed to `bootstrap.sh`.

## Caveats

* **The synthetic data is PII-shaped on purpose.** If you later populate
  these tables with the generators in `env_tonic/tdm_poc/generators/`, the
  rows include Luhn-valid PANs, populated CVVs, formatted SSNs/NINs, and
  free-text fields containing embedded PII. None of it maps to real
  people, but DLP scanners will scream. Tag the database "synthetic / TDM
  PoC test fixture" wherever your security team will see it.
* **`bootstrap.sh` is idempotent** (uses `CREATE TABLE IF NOT EXISTS` and
  `CREATE SCHEMA IF NOT EXISTS`) but does not drop existing tables. To
  reset, drop the schema first: `DROP SCHEMA <name> CASCADE`.
* **No data is loaded.** This kit creates an empty schema. If you want
  populated tables, run the generators in `env_tonic/tdm_poc/generators/`
  against `$DSN`:
  ```bash
  cd env_tonic/tdm_poc
  pip install -r requirements.txt
  TDM_PG_DSN="$DSN" python3 -m generators.generate_corpus --primary 500 --out ./data/remote
  TDM_PG_DSN="$DSN" python3 -m generators.load_postgres --schema prod_bronze --src ./data/remote/corpus
  ```

## License

Internal use. Not for redistribution outside Jack Henry.
