-- sql_bricks_statements.sql
-- copyright 2026 by moshix
-- 
-- Postgres setup for the bricks SQL sample transactions
-- (SQLD in COBOL, SQLR in REXX). Run this once, on the
-- Postgres server bricks.cnf's db_host / db_port point at,
-- against the database named in the first row of
-- runtime/databases.conf (default: bricks).
--
-- Quickstart:
--
--   psql -h <db_host> -p <db_port> -U <db_user> -d bricks \
--        -f sql_bricks_statements.sql
--
-- The user that bricks logs in as (db_user in bricks.cnf) must
-- be able to CREATE in the target schema and have INSERT /
-- UPDATE / DELETE on customers_sql. On Postgres 15+ the public
-- schema no longer grants CREATE to every user -- if the script
-- fails with "permission denied for schema public", run this
-- once as a superuser (e.g. the postgres role):
--
--   GRANT ALL ON SCHEMA public TO bricks;
--
-- and, if the table was created by a different role, also:
--
--   GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE customers_sql TO bricks;
--
-- Schema
--
-- customers_sql is the table the SQLD / SQLR sample transactions
-- read. The id column is the 10-character key the operator types
-- on the SQLD1 input screen; name is the 30-character display
-- value the program writes back via SELECT INTO :NM.

CREATE TABLE IF NOT EXISTS customers_sql (
    id   text PRIMARY KEY,
    name text NOT NULL
);

-- Seed data
--
-- Three demonstration rows. Operators on the SQLD1 screen type
-- one of these ids to see the friendly success path; any other
-- id surfaces SQL-NODATA (SQLCODE = +100) so the program's
-- "No customer with that id." branch fires.

INSERT INTO customers_sql (id, name) VALUES
    ('K001', 'Alice'),
    ('K002', 'Bob'),
    ('K003', 'Carol')
ON CONFLICT (id) DO NOTHING;

-- Verifyy
--
-- Sanity check (psql will print the three rows after the script
-- runs):

SELECT id, name FROM customers_sql ORDER BY id;
