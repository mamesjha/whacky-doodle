-- TDM PoC: Postgres bronze schema.
--
-- This file is read by generators/load_postgres.py which substitutes
-- {schema} before executing it.  Run it twice — once for prod_bronze
-- and once for lower_bronze — to create the two mirrored datasets that
-- map to ${BRONZE_PROD} / ${BRONZE_LOWER} in the BigQuery setup.
--
-- FK constraints are DEFERRABLE INITIALLY DEFERRED so load order does
-- not need to respect the dependency chain.
--
-- Metadata columns (_ingested_at, _source_op) are present on every
-- table to match the BigQuery bronze contract; they are used by
-- temporal_patterns.py (RI-04) and delta-mode tests.

CREATE SCHEMA IF NOT EXISTS {schema};

-- ===========================================================================
-- Reference / lookup
-- ===========================================================================
CREATE TABLE IF NOT EXISTS {schema}.oltp_countries (
    country_code   CHAR(2)       NOT NULL PRIMARY KEY,
    country_name   VARCHAR(100)  NOT NULL,
    eu_member      BOOLEAN       NOT NULL DEFAULT FALSE,
    _ingested_at   TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    _source_op     VARCHAR(1)
);

CREATE TABLE IF NOT EXISTS {schema}.oltp_currencies (
    currency_code  CHAR(3)       NOT NULL PRIMARY KEY,
    currency_name  VARCHAR(50)   NOT NULL,
    _ingested_at   TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    _source_op     VARCHAR(1)
);

CREATE TABLE IF NOT EXISTS {schema}.oltp_departments (
    department_id    INT           NOT NULL PRIMARY KEY,
    department_name  VARCHAR(100)  NOT NULL,
    cost_center      VARCHAR(20)   NOT NULL,
    _ingested_at     TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    _source_op       VARCHAR(1)
);

-- ===========================================================================
-- Party / identity
-- ===========================================================================
CREATE TABLE IF NOT EXISTS {schema}.oltp_parties (
    party_id      BIGINT        NOT NULL PRIMARY KEY,
    party_type    CHAR(3)       NOT NULL,
    external_ref  VARCHAR(64),
    created_at    TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    _ingested_at  TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    _source_op    VARCHAR(1),
    CONSTRAINT ck_{schema}_parties_type CHECK (party_type IN ('IND','ORG'))
);

CREATE TABLE IF NOT EXISTS {schema}.oltp_individuals (
    party_id             BIGINT        NOT NULL PRIMARY KEY,
    first_name           VARCHAR(100)  NOT NULL,
    middle_name          VARCHAR(100),
    last_name            VARCHAR(100)  NOT NULL,
    full_name_display    VARCHAR(300),
    date_of_birth        DATE          NOT NULL,
    gender               VARCHAR(1),
    email                VARCHAR(320),
    phone_e164           VARCHAR(20),
    national_id          VARCHAR(64),
    national_id_country  CHAR(2),
    nationality          CHAR(2),
    notes                TEXT,
    _ingested_at         TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    _source_op           VARCHAR(1),
    CONSTRAINT fk_{schema}_ind_party FOREIGN KEY (party_id)
        REFERENCES {schema}.oltp_parties(party_id) DEFERRABLE INITIALLY DEFERRED
);

CREATE TABLE IF NOT EXISTS {schema}.oltp_organizations (
    party_id         BIGINT        NOT NULL PRIMARY KEY,
    legal_name       VARCHAR(255)  NOT NULL,
    trading_name     VARCHAR(255),
    tax_id           VARCHAR(64),
    incorporated_in  CHAR(2),
    notes            TEXT,
    _ingested_at     TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    _source_op       VARCHAR(1),
    CONSTRAINT fk_{schema}_org_party FOREIGN KEY (party_id)
        REFERENCES {schema}.oltp_parties(party_id) DEFERRABLE INITIALLY DEFERRED
);

-- ===========================================================================
-- Addresses
-- ===========================================================================
CREATE TABLE IF NOT EXISTS {schema}.oltp_addresses (
    address_id    BIGINT         NOT NULL PRIMARY KEY,
    line1         VARCHAR(255)   NOT NULL,
    line2         VARCHAR(255),
    city          VARCHAR(100)   NOT NULL,
    region        VARCHAR(100),
    postcode      VARCHAR(20),
    country_code  CHAR(2)        NOT NULL,
    geo_lat       NUMERIC(9, 6),
    geo_lon       NUMERIC(9, 6),
    _ingested_at  TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
    _source_op    VARCHAR(1)
);

CREATE TABLE IF NOT EXISTS {schema}.oltp_party_addresses (
    party_id      BIGINT       NOT NULL,
    address_id    BIGINT       NOT NULL,
    address_kind  VARCHAR(20)  NOT NULL,
    valid_from    DATE         NOT NULL,
    valid_to      DATE,
    _ingested_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    _source_op    VARCHAR(1),
    PRIMARY KEY (party_id, address_id, address_kind, valid_from),
    CONSTRAINT fk_{schema}_pa_party   FOREIGN KEY (party_id)   REFERENCES {schema}.oltp_parties(party_id)   DEFERRABLE INITIALLY DEFERRED,
    CONSTRAINT fk_{schema}_pa_address FOREIGN KEY (address_id) REFERENCES {schema}.oltp_addresses(address_id) DEFERRABLE INITIALLY DEFERRED
);

-- ===========================================================================
-- Customer relationship
-- ===========================================================================
CREATE TABLE IF NOT EXISTS {schema}.oltp_customers (
    customer_id   BIGINT        NOT NULL PRIMARY KEY,
    party_id      BIGINT        NOT NULL,
    customer_no   VARCHAR(50)   NOT NULL UNIQUE,
    segment       VARCHAR(20)   NOT NULL,
    risk_score    NUMERIC(5,2),
    onboarded_at  TIMESTAMPTZ   NOT NULL,
    closed_at     TIMESTAMPTZ,
    consent_json  JSONB,
    _ingested_at  TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    _source_op    VARCHAR(1),
    CONSTRAINT fk_{schema}_cust_party FOREIGN KEY (party_id)
        REFERENCES {schema}.oltp_parties(party_id) DEFERRABLE INITIALLY DEFERRED
);

-- ===========================================================================
-- Accounts
-- ===========================================================================
CREATE TABLE IF NOT EXISTS {schema}.oltp_accounts (
    account_id     BIGINT       NOT NULL PRIMARY KEY,
    account_no     VARCHAR(30)  NOT NULL UNIQUE,
    account_type   VARCHAR(20)  NOT NULL,
    currency_code  CHAR(3)      NOT NULL,
    opened_at      TIMESTAMPTZ  NOT NULL,
    closed_at      TIMESTAMPTZ,
    balance_minor  BIGINT       NOT NULL DEFAULT 0,
    _ingested_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    _source_op     VARCHAR(1),
    CONSTRAINT fk_{schema}_acc_currency FOREIGN KEY (currency_code)
        REFERENCES {schema}.oltp_currencies(currency_code) DEFERRABLE INITIALLY DEFERRED
);

CREATE TABLE IF NOT EXISTS {schema}.oltp_account_holders (
    account_id    BIGINT       NOT NULL,
    customer_id   BIGINT       NOT NULL,
    role          VARCHAR(20)  NOT NULL,
    since         DATE         NOT NULL,
    _ingested_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    _source_op    VARCHAR(1),
    PRIMARY KEY (account_id, customer_id, role),
    CONSTRAINT fk_{schema}_ah_account  FOREIGN KEY (account_id)  REFERENCES {schema}.oltp_accounts(account_id)  DEFERRABLE INITIALLY DEFERRED,
    CONSTRAINT fk_{schema}_ah_customer FOREIGN KEY (customer_id) REFERENCES {schema}.oltp_customers(customer_id) DEFERRABLE INITIALLY DEFERRED
);

-- ===========================================================================
-- Cards (PCI scope)
-- ===========================================================================
CREATE TABLE IF NOT EXISTS {schema}.oltp_cards (
    card_id          BIGINT       NOT NULL PRIMARY KEY,
    account_id       BIGINT       NOT NULL,
    pan_full         VARCHAR(19)  NOT NULL,
    pan_token        VARCHAR(64)  NOT NULL,
    pan_bin          CHAR(6)      NOT NULL,
    pan_last4        CHAR(4)      NOT NULL,
    card_brand       VARCHAR(10)  NOT NULL,
    cardholder_name  VARCHAR(300) NOT NULL,
    expiry_month     SMALLINT     NOT NULL,
    expiry_year      SMALLINT     NOT NULL,
    cvv              VARCHAR(4),
    issued_at        TIMESTAMPTZ  NOT NULL,
    cancelled_at     TIMESTAMPTZ,
    _ingested_at     TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    _source_op       VARCHAR(1),
    CONSTRAINT fk_{schema}_card_account FOREIGN KEY (account_id)
        REFERENCES {schema}.oltp_accounts(account_id) DEFERRABLE INITIALLY DEFERRED
);

-- ===========================================================================
-- Transactions
-- ===========================================================================
CREATE TABLE IF NOT EXISTS {schema}.oltp_card_transactions (
    txn_id            BIGINT       NOT NULL PRIMARY KEY,
    card_id           BIGINT       NOT NULL,
    account_id        BIGINT       NOT NULL,
    txn_uuid          VARCHAR(36)  NOT NULL,
    occurred_at       TIMESTAMPTZ  NOT NULL,
    posted_at         TIMESTAMPTZ,
    amount_minor      BIGINT       NOT NULL,
    currency_code     CHAR(3)      NOT NULL,
    merchant_name     VARCHAR(200),
    merchant_mcc      VARCHAR(10),
    merchant_country  CHAR(2),
    description       TEXT,
    ip_address        VARCHAR(45),
    device_id         VARCHAR(64),
    session_id        VARCHAR(64),
    status            VARCHAR(20)  NOT NULL,
    _ingested_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    _source_op        VARCHAR(1),
    CONSTRAINT fk_{schema}_ct_card    FOREIGN KEY (card_id)    REFERENCES {schema}.oltp_cards(card_id)       DEFERRABLE INITIALLY DEFERRED,
    CONSTRAINT fk_{schema}_ct_account FOREIGN KEY (account_id) REFERENCES {schema}.oltp_accounts(account_id) DEFERRABLE INITIALLY DEFERRED
);

CREATE TABLE IF NOT EXISTS {schema}.oltp_transactions (
    transaction_id           BIGINT       NOT NULL PRIMARY KEY,
    account_id               BIGINT       NOT NULL,
    counterparty_account_id  BIGINT,
    txn_uuid                 VARCHAR(36)  NOT NULL,
    occurred_at              TIMESTAMPTZ  NOT NULL,
    amount_minor             BIGINT       NOT NULL,
    currency_code            CHAR(3)      NOT NULL,
    txn_type                 VARCHAR(20)  NOT NULL,
    memo                     TEXT,
    _ingested_at             TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    _source_op               VARCHAR(1),
    CONSTRAINT fk_{schema}_txn_account FOREIGN KEY (account_id)
        REFERENCES {schema}.oltp_accounts(account_id) DEFERRABLE INITIALLY DEFERRED
);

-- ===========================================================================
-- Employees (self-referencing manager hierarchy)
-- ===========================================================================
CREATE TABLE IF NOT EXISTS {schema}.oltp_employees (
    employee_id       INT           NOT NULL PRIMARY KEY,
    employee_no       VARCHAR(20)   NOT NULL,
    party_id          BIGINT        NOT NULL,
    manager_id        INT,
    department_id     INT           NOT NULL,
    title             VARCHAR(100)  NOT NULL,
    hire_date         DATE          NOT NULL,
    termination_date  DATE,
    salary_minor      BIGINT,
    work_email        VARCHAR(320),
    _ingested_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    _source_op        VARCHAR(1),
    CONSTRAINT fk_{schema}_emp_party FOREIGN KEY (party_id)
        REFERENCES {schema}.oltp_parties(party_id) DEFERRABLE INITIALLY DEFERRED,
    CONSTRAINT fk_{schema}_emp_mgr   FOREIGN KEY (manager_id)
        REFERENCES {schema}.oltp_employees(employee_id) DEFERRABLE INITIALLY DEFERRED,
    CONSTRAINT fk_{schema}_emp_dept  FOREIGN KEY (department_id)
        REFERENCES {schema}.oltp_departments(department_id) DEFERRABLE INITIALLY DEFERRED
);

-- ===========================================================================
-- Support tickets + messages
-- ===========================================================================
CREATE TABLE IF NOT EXISTS {schema}.oltp_support_tickets (
    ticket_id              BIGINT       NOT NULL PRIMARY KEY,
    customer_id            BIGINT       NOT NULL,
    opened_by_employee_id  INT,
    subject                TEXT         NOT NULL,
    status                 VARCHAR(20)  NOT NULL,
    priority               SMALLINT     NOT NULL,
    opened_at              TIMESTAMPTZ  NOT NULL,
    closed_at              TIMESTAMPTZ,
    _ingested_at           TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    _source_op             VARCHAR(1),
    CONSTRAINT fk_{schema}_st_customer FOREIGN KEY (customer_id)
        REFERENCES {schema}.oltp_customers(customer_id) DEFERRABLE INITIALLY DEFERRED
);

CREATE TABLE IF NOT EXISTS {schema}.oltp_ticket_messages (
    message_id             BIGINT       NOT NULL PRIMARY KEY,
    ticket_id              BIGINT       NOT NULL,
    author_kind            VARCHAR(20)  NOT NULL,
    author_party_id        BIGINT       NOT NULL,
    posted_at              TIMESTAMPTZ  NOT NULL,
    body                   TEXT         NOT NULL,
    body_json_attachments  JSONB,
    _ingested_at           TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    _source_op             VARCHAR(1),
    CONSTRAINT fk_{schema}_tm_ticket FOREIGN KEY (ticket_id)
        REFERENCES {schema}.oltp_support_tickets(ticket_id) DEFERRABLE INITIALLY DEFERRED
);

-- ===========================================================================
-- Devices / sessions / GDPR consent
-- ===========================================================================
CREATE TABLE IF NOT EXISTS {schema}.oltp_devices (
    device_id      VARCHAR(64)   NOT NULL PRIMARY KEY,
    customer_id    BIGINT,
    user_agent     TEXT,
    first_seen_at  TIMESTAMPTZ   NOT NULL,
    last_seen_at   TIMESTAMPTZ,
    _ingested_at   TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    _source_op     VARCHAR(1),
    CONSTRAINT fk_{schema}_dev_customer FOREIGN KEY (customer_id)
        REFERENCES {schema}.oltp_customers(customer_id) DEFERRABLE INITIALLY DEFERRED
);

CREATE TABLE IF NOT EXISTS {schema}.oltp_sessions (
    session_id    VARCHAR(64)  NOT NULL PRIMARY KEY,
    customer_id   BIGINT       NOT NULL,
    device_id     VARCHAR(64),
    ip_address    VARCHAR(45),
    started_at    TIMESTAMPTZ  NOT NULL,
    ended_at      TIMESTAMPTZ,
    _ingested_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    _source_op    VARCHAR(1),
    CONSTRAINT fk_{schema}_sess_customer FOREIGN KEY (customer_id)
        REFERENCES {schema}.oltp_customers(customer_id) DEFERRABLE INITIALLY DEFERRED
);

CREATE TABLE IF NOT EXISTS {schema}.oltp_consent_records (
    consent_id    BIGINT       NOT NULL PRIMARY KEY,
    customer_id   BIGINT       NOT NULL,
    purpose       VARCHAR(50)  NOT NULL,
    granted       BOOLEAN      NOT NULL,
    captured_at   TIMESTAMPTZ  NOT NULL,
    captured_ip   VARCHAR(45),
    captured_ua   TEXT,
    payload_json  JSONB,
    _ingested_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    _source_op    VARCHAR(1),
    CONSTRAINT fk_{schema}_con_customer FOREIGN KEY (customer_id)
        REFERENCES {schema}.oltp_customers(customer_id) DEFERRABLE INITIALLY DEFERRED
);

-- ===========================================================================
-- Invoices
-- ===========================================================================
CREATE TABLE IF NOT EXISTS {schema}.oltp_invoices (
    invoice_id     BIGINT       NOT NULL PRIMARY KEY,
    customer_id    BIGINT       NOT NULL,
    txn_id         BIGINT,
    invoice_no     VARCHAR(30)  NOT NULL,
    issued_at      TIMESTAMPTZ  NOT NULL,
    due_at         TIMESTAMPTZ  NOT NULL,
    total_minor    BIGINT       NOT NULL,
    currency_code  CHAR(3)      NOT NULL,
    status         VARCHAR(20)  NOT NULL,
    _ingested_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    _source_op     VARCHAR(1),
    CONSTRAINT fk_{schema}_inv_customer FOREIGN KEY (customer_id)
        REFERENCES {schema}.oltp_customers(customer_id) DEFERRABLE INITIALLY DEFERRED
);

CREATE TABLE IF NOT EXISTS {schema}.oltp_invoice_lines (
    line_id            BIGINT        NOT NULL PRIMARY KEY,
    invoice_id         BIGINT        NOT NULL,
    description        VARCHAR(255)  NOT NULL,
    quantity           NUMERIC(10,2) NOT NULL,
    unit_amount_minor  BIGINT        NOT NULL,
    _ingested_at       TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    _source_op         VARCHAR(1),
    CONSTRAINT fk_{schema}_il_invoice FOREIGN KEY (invoice_id)
        REFERENCES {schema}.oltp_invoices(invoice_id) DEFERRABLE INITIALLY DEFERRED
);

-- ===========================================================================
-- Soft-deleted archive
-- ===========================================================================
CREATE TABLE IF NOT EXISTS {schema}.oltp_deleted_individuals_archive (
    party_id          BIGINT       NOT NULL PRIMARY KEY,
    deletion_reason   VARCHAR(50),
    deleted_at        TIMESTAMPTZ  NOT NULL,
    redacted_payload  JSONB,
    _ingested_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    _source_op        VARCHAR(1)
);

-- ===========================================================================
-- Audit log
-- ===========================================================================
CREATE TABLE IF NOT EXISTS {schema}.audit_event_log (
    event_id        BIGINT       NOT NULL PRIMARY KEY,
    occurred_at     TIMESTAMPTZ  NOT NULL,
    actor_party_id  BIGINT,
    actor_ip        VARCHAR(45),
    event_type      VARCHAR(20)  NOT NULL,
    target_table    VARCHAR(100),
    target_pk       VARCHAR(100),
    payload_json    JSONB,
    _ingested_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    _source_op      VARCHAR(1)
);
