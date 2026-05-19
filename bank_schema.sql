-- bank_schema.sql -- DDL for the BANK demo transaction.
--
-- Five tables (accounts, transactions, account_salary, vendors,
-- employers) plus one sequence (bank_acct_seq) for generating the
-- 23-digit account numbers used by the OPEN-account screen.
--
-- Every table reserves five generic VARCHAR(80) columns at the end
-- so the demo can grow without altering the schema or re-running
-- the seeder. Rename a reserved column with ALTER COLUMN ... RENAME
-- when you need a new field.
--
-- All money columns are NUMERIC(15,2). Account numbers are CHAR(23)
-- (exactly 23 digits, zero-padded -- this is the BANK transaction's
-- hard requirement).

BEGIN;

-- ---------------------------------------------------------------
-- accounts: one row per banking customer.
-- ---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS accounts (
    account_number  CHAR(23)      PRIMARY KEY,
    last_name       VARCHAR(40)   NOT NULL,
    first_name      VARCHAR(40)   NOT NULL,
    middle_init     CHAR(1)       DEFAULT '',
    street          VARCHAR(60)   NOT NULL DEFAULT '',
    city            VARCHAR(40)   NOT NULL DEFAULT '',
    state           CHAR(2)       NOT NULL DEFAULT '',
    zip             CHAR(10)      NOT NULL DEFAULT '',
    email           VARCHAR(60)   NOT NULL DEFAULT '',
    phone           CHAR(15)      NOT NULL DEFAULT '',
    balance         NUMERIC(15,2) NOT NULL DEFAULT 0,
    status          CHAR(1)       NOT NULL DEFAULT 'O',   -- 'O' open, 'C' closed
    opened_date     DATE          NOT NULL DEFAULT CURRENT_DATE,
    closed_date     DATE,
    reserved1       VARCHAR(80)   NOT NULL DEFAULT '',
    reserved2       VARCHAR(80)   NOT NULL DEFAULT '',
    reserved3       VARCHAR(80)   NOT NULL DEFAULT '',
    reserved4       VARCHAR(80)   NOT NULL DEFAULT '',
    reserved5       VARCHAR(80)   NOT NULL DEFAULT ''
);

CREATE INDEX IF NOT EXISTS accounts_last_name_idx
    ON accounts (last_name);
CREATE INDEX IF NOT EXISTS accounts_first_name_idx
    ON accounts (first_name);
CREATE INDEX IF NOT EXISTS accounts_city_idx
    ON accounts (city);

-- Account-number generator used by the OPEN screen and by the seeder.
-- Starting at 10000000000000000000001 keeps every generated number
-- exactly 23 digits when LPAD'd with zeros so it round-trips through
-- the COBOL CHAR(23) field without ambiguity.
CREATE SEQUENCE IF NOT EXISTS bank_acct_seq
    AS BIGINT
    START WITH 1
    INCREMENT BY 1
    NO CYCLE;

-- ---------------------------------------------------------------
-- transactions: append-only money movements.
-- ---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS transactions (
    tx_id           BIGSERIAL     PRIMARY KEY,
    account_number  CHAR(23)      NOT NULL REFERENCES accounts (account_number),
    tx_ts           TIMESTAMP     NOT NULL DEFAULT NOW(),
    tx_type         CHAR(4)       NOT NULL,    -- 'CR  ' 'ATM ' 'WIRE' 'SAL '
    amount          NUMERIC(15,2) NOT NULL,    -- signed: +credit, -debit
    description     VARCHAR(60)   NOT NULL DEFAULT '',
    counterparty    VARCHAR(60)   NOT NULL DEFAULT '',
    balance_after   NUMERIC(15,2) NOT NULL,
    reserved1       VARCHAR(80)   NOT NULL DEFAULT '',
    reserved2       VARCHAR(80)   NOT NULL DEFAULT '',
    reserved3       VARCHAR(80)   NOT NULL DEFAULT '',
    reserved4       VARCHAR(80)   NOT NULL DEFAULT '',
    reserved5       VARCHAR(80)   NOT NULL DEFAULT ''
);

-- Newest-first scroll on the detail screen reads this index forwards.
CREATE INDEX IF NOT EXISTS transactions_acct_ts_idx
    ON transactions (account_number, tx_ts DESC);

-- ---------------------------------------------------------------
-- account_salary: payroll metadata, one row per account.
-- ---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS account_salary (
    account_number   CHAR(23)      PRIMARY KEY
                                    REFERENCES accounts (account_number),
    employer_name    VARCHAR(60)   NOT NULL,
    salary_amount    NUMERIC(12,2) NOT NULL,
    last_paid        DATE,
    pay_period_days  INT           NOT NULL DEFAULT 14,
    reserved1        VARCHAR(80)   NOT NULL DEFAULT '',
    reserved2        VARCHAR(80)   NOT NULL DEFAULT '',
    reserved3        VARCHAR(80)   NOT NULL DEFAULT '',
    reserved4        VARCHAR(80)   NOT NULL DEFAULT '',
    reserved5        VARCHAR(80)   NOT NULL DEFAULT ''
);

-- ---------------------------------------------------------------
-- vendors: lookup table for realistic credit-transaction names.
-- ---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS vendors (
    vendor_id     SERIAL        PRIMARY KEY,
    name          VARCHAR(60)   NOT NULL UNIQUE,
    category      VARCHAR(20)   NOT NULL,
    typical_min   NUMERIC(8,2)  NOT NULL,
    typical_max   NUMERIC(8,2)  NOT NULL,
    reserved1     VARCHAR(80)   NOT NULL DEFAULT '',
    reserved2     VARCHAR(80)   NOT NULL DEFAULT '',
    reserved3     VARCHAR(80)   NOT NULL DEFAULT '',
    reserved4     VARCHAR(80)   NOT NULL DEFAULT '',
    reserved5     VARCHAR(80)   NOT NULL DEFAULT ''
);

-- ---------------------------------------------------------------
-- employers: lookup table for realistic salary-deposit names.
-- ---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS employers (
    employer_id   SERIAL        PRIMARY KEY,
    name          VARCHAR(60)   NOT NULL UNIQUE,
    salary_min    NUMERIC(10,2) NOT NULL,
    salary_max    NUMERIC(10,2) NOT NULL,
    reserved1     VARCHAR(80)   NOT NULL DEFAULT '',
    reserved2     VARCHAR(80)   NOT NULL DEFAULT '',
    reserved3     VARCHAR(80)   NOT NULL DEFAULT '',
    reserved4     VARCHAR(80)   NOT NULL DEFAULT '',
    reserved5     VARCHAR(80)   NOT NULL DEFAULT ''
);

-- ---------------------------------------------------------------
-- Seed vendors. ON CONFLICT keeps the script idempotent so a
-- re-run never errors and never duplicates.
-- ---------------------------------------------------------------
INSERT INTO vendors (name, category, typical_min, typical_max) VALUES
    ('Whole Foods Market',       'GROCERY',       8.00,   180.00),
    ('Trader Joes',              'GROCERY',       5.00,   140.00),
    ('Safeway',                  'GROCERY',       6.00,   160.00),
    ('Costco Wholesale',         'GROCERY',      40.00,   420.00),
    ('Kroger',                   'GROCERY',       5.00,   150.00),
    ('Aldi',                     'GROCERY',       4.00,    90.00),
    ('Publix',                   'GROCERY',       6.00,   140.00),
    ('Walmart Supercenter',      'GROCERY',       7.00,   210.00),
    ('Starbucks',                'RESTAURANT',    4.00,    18.00),
    ('Chipotle',                 'RESTAURANT',    9.00,    26.00),
    ('Sweetgreen',               'RESTAURANT',   11.00,    24.00),
    ('Panera Bread',             'RESTAURANT',    8.00,    30.00),
    ('Shake Shack',              'RESTAURANT',   10.00,    32.00),
    ('Five Guys',                'RESTAURANT',   11.00,    38.00),
    ('Olive Garden',             'RESTAURANT',   18.00,    72.00),
    ('Cheesecake Factory',       'RESTAURANT',   24.00,    95.00),
    ('PF Changs',                'RESTAURANT',   22.00,    88.00),
    ('Local Diner',              'RESTAURANT',    9.00,    35.00),
    ('Pacific Gas Electric',     'UTILITY',      45.00,   320.00),
    ('Con Edison',               'UTILITY',      50.00,   340.00),
    ('Duke Energy',              'UTILITY',      40.00,   290.00),
    ('Verizon Wireless',         'UTILITY',      35.00,   210.00),
    ('AT and T Mobility',        'UTILITY',      32.00,   200.00),
    ('Comcast Xfinity',          'UTILITY',      55.00,   170.00),
    ('Spectrum Internet',        'UTILITY',      45.00,   140.00),
    ('Water and Sewer Dept',     'UTILITY',      28.00,   120.00),
    ('City Trash Services',      'UTILITY',      18.00,    60.00),
    ('Netflix',                  'SUBSCRIPTION', 12.00,    23.00),
    ('Spotify Premium',          'SUBSCRIPTION',  9.00,    17.00),
    ('Apple Services',           'SUBSCRIPTION',  3.00,    35.00),
    ('Amazon Prime',             'SUBSCRIPTION', 15.00,    16.00),
    ('Hulu',                     'SUBSCRIPTION',  8.00,    20.00),
    ('Disney Plus',              'SUBSCRIPTION', 11.00,    14.00),
    ('New York Times',           'SUBSCRIPTION',  5.00,    19.00),
    ('NYT Cooking',              'SUBSCRIPTION',  5.00,     6.00),
    ('Adobe Creative Cloud',     'SUBSCRIPTION', 22.00,    60.00),
    ('GitHub',                   'SUBSCRIPTION',  4.00,    24.00),
    ('Dropbox',                  'SUBSCRIPTION', 10.00,    24.00),
    ('Amazon Marketplace',       'RETAIL',        8.00,   320.00),
    ('Target',                   'RETAIL',       12.00,   240.00),
    ('Best Buy',                 'RETAIL',       28.00,   850.00),
    ('Home Depot',               'RETAIL',       15.00,   480.00),
    ('Lowes',                    'RETAIL',       15.00,   460.00),
    ('IKEA',                     'RETAIL',       22.00,   720.00),
    ('Macys',                    'RETAIL',       18.00,   380.00),
    ('REI Co-op',                'RETAIL',       30.00,   420.00),
    ('Nike Store',               'RETAIL',       40.00,   260.00),
    ('Uniqlo',                   'RETAIL',       18.00,   180.00),
    ('Apple Store',              'RETAIL',       29.00,  1400.00),
    ('Etsy',                     'RETAIL',       12.00,   180.00),
    ('Shell',                    'GAS',          18.00,    95.00),
    ('Chevron',                  'GAS',          18.00,   100.00),
    ('Exxon',                    'GAS',          18.00,    95.00),
    ('BP',                       'GAS',          18.00,    90.00),
    ('76 Station',               'GAS',          18.00,    90.00),
    ('Costco Gas',               'GAS',          25.00,   110.00),
    ('Mobil',                    'GAS',          18.00,    95.00),
    ('Speedway',                 'GAS',          18.00,    85.00),
    ('Uber Rides',               'RETAIL',        7.00,    65.00),
    ('Lyft',                     'RETAIL',        7.00,    60.00),
    ('DoorDash',                 'RESTAURANT',   14.00,    72.00),
    ('Instacart',                'GROCERY',      30.00,   220.00)
ON CONFLICT (name) DO NOTHING;

-- ---------------------------------------------------------------
-- Seed employers.
-- ---------------------------------------------------------------
INSERT INTO employers (name, salary_min, salary_max) VALUES
    ('Acme Aerospace Inc',          2200.00, 5400.00),
    ('Northwind Logistics',         1900.00, 4600.00),
    ('Contoso Insurance Group',     2100.00, 5100.00),
    ('Fabrikam Software',           2600.00, 6800.00),
    ('Globex Corporation',          2400.00, 6200.00),
    ('Initech Systems',             2300.00, 5900.00),
    ('Stark Industries',            3000.00, 7800.00),
    ('Wayne Enterprises',           2800.00, 7200.00),
    ('Tyrell Robotics',             2700.00, 6900.00),
    ('Cyberdyne Research',          2500.00, 6400.00),
    ('Soylent Foods Inc',           1800.00, 4100.00),
    ('Vandelay Imports',            1700.00, 3900.00),
    ('Pied Piper Networks',         2400.00, 6000.00),
    ('Hooli Cloud Services',        2600.00, 6700.00),
    ('Massive Dynamic',             2900.00, 7400.00),
    ('Bluth Property Group',        1900.00, 4400.00),
    ('Dunder Mifflin Paper',        1600.00, 3700.00),
    ('Sterling Cooper Agency',      2100.00, 5300.00),
    ('Los Pollos Restaurants',      1700.00, 3800.00),
    ('Olivia Pope Associates',      2500.00, 6300.00),
    ('Riverside Medical Center',    2200.00, 5800.00),
    ('Mercer Hospital',             2300.00, 5900.00),
    ('Public School District 42',   1800.00, 4200.00),
    ('State University',            2000.00, 5200.00),
    ('Atlas City Government',       1900.00, 4700.00)
ON CONFLICT (name) DO NOTHING;

COMMIT;
