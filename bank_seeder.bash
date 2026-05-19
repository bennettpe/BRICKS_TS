#!/usr/bin/env bash
# bank_seeder.bash -- populate and drive the BANK demo database.
#
# Two modes:
#
#   bash bank_seeder.bash          (continuous)
#       Endless loop. Ensures the 200 demo accounts exist (creating
#       them on first run), then trickles money transactions at
#       roughly TICK_SECONDS cadence, mixing 90% credits / 5% ATM /
#       5% wires and emitting a salary deposit every two weeks per
#       account. Per-tick log line goes to stdout (tee-friendly);
#       every minute a stats block prints tx_total, top-5 accounts,
#       and current DB size. Stops only on Ctrl-C.
#
#   bash bank_seeder.bash -init    (one-shot bulk backfill)
#       Ensures the 200 accounts exist, then synthesises 180 days
#       of past transactions for every account -- respecting the
#       10/day cap, the 90/5/5 mix, and bi-weekly salary deposits.
#       Uses set-based PL/pgSQL so the whole backfill finishes in
#       seconds-to-minutes rather than months of real time. Exits
#       0 when done; does NOT enter the continuous loop afterwards.
#
# Connection settings are at the top of this file. Override at the
# shell or environment if your Postgres differs:
#
#     BANK_HOST=db.local BANK_USER=alice bash bank_seeder.bash -init
#
# Designed to be tee'd:
#
#     bash bank_seeder.bash | tee -a bank_seeder.log
#
# Pre-req: bank_schema.bash has been run, so the five BANK tables
# and the vendor / employer lookups already exist.

set -euo pipefail

# ---- editable connection settings -----------------------------------
BANK_HOST="${BANK_HOST:-localhost}"
BANK_PORT="${BANK_PORT:-5432}"
BANK_USER="${BANK_USER:-bricks}"
BANK_PASS="${BANK_PASS:-bricks}"
BANK_DB="${BANK_DB:-bank}"
# ---- editable runtime settings --------------------------------------
TICK_SECONDS="${TICK_SECONDS:-30}"     # base sleep between txs
DAILY_TX_CAP="${DAILY_TX_CAP:-10}"     # per-account ceiling per day
TOTAL_ACCOUNTS="${TOTAL_ACCOUNTS:-200}"
BACKFILL_DAYS="${BACKFILL_DAYS:-180}"  # used by -init mode
STATS_INTERVAL="${STATS_INTERVAL:-60}" # seconds between stats lines
# ---------------------------------------------------------------------

MODE="continuous"
if [[ "${1:-}" == "-init" ]]; then
    MODE="init"
elif [[ -n "${1:-}" ]]; then
    echo "bank_seeder: unknown argument '$1' (only -init is recognised)" >&2
    exit 2
fi

export PGPASSWORD="$BANK_PASS"
PSQL=(psql -h "$BANK_HOST" -p "$BANK_PORT" -U "$BANK_USER" -d "$BANK_DB"
      -v ON_ERROR_STOP=1 --no-psqlrc -qtAX)

# Wrapper: returns stdout, errors abort the script.
q() { "${PSQL[@]}" -c "$1"; }
# Wrapper: like q() but reads a multi-line statement from stdin.
q_stdin() { "${PSQL[@]}" -f -; }

trap 'echo; echo "bank_seeder: stopped."; exit 0' INT TERM

# ---------------------------------------------------------------------
# Install helper PL/pgSQL functions in the bank database. CREATE OR
# REPLACE so re-running just refreshes; nothing else in the schema
# touches these names. They are kept inside this script (rather than
# in bank_schema.sql) so they live with the seeder logic.
# ---------------------------------------------------------------------
install_helpers() {
    q_stdin <<'PLSQL'
-- ---- migrate any pre-existing rows to the new type taxonomy ------
-- The TYPE column is now strictly accounting:
--    'DEB ' = outgoing (debit -- amount negative)
--    'CR  ' = incoming non-payroll (credit -- amount positive)
--    'SAL ' = payroll deposit (credit -- amount positive)
-- Old rows used 'CR  ' for purchases, 'ATM ' for ATM, 'WIRE' for
-- wires; fold them all into 'DEB ' so the operator sees consistent
-- TYPE labels on the BANK detail screen.
UPDATE transactions
   SET tx_type = 'DEB '
 WHERE amount < 0
   AND tx_type IN ('CR  ', 'ATM ', 'WIRE');

-- All incoming amounts collapse into a single TYPE label 'CRE ' so
-- the BANK detail screen reads as a plain debit/credit ledger. The
-- specific flavour (payroll, refund, incoming wire) still lives in
-- the description column.
UPDATE transactions
   SET tx_type = 'CRE '
 WHERE amount > 0
   AND tx_type IN ('SAL ', 'CR  ');

-- Re-roll every biweekly salary on a per-account basis so no two
-- account holders earn identical pay. Range is $3,500..$7,000 --
-- the floor comfortably covers ~$2k of typical debits per pay
-- period (2-6 tx/day * 14 days * avg ~$35 vendor charge plus the
-- occasional ATM / wire) and still leaves balances trending up.
UPDATE account_salary
   SET salary_amount = round((3500 + random() * 3500)::numeric, 2);

-- Same minimum applies to new accounts created from BANK4 (the
-- "Open new account" screen seeds account_salary from a random
-- employer row).
UPDATE employers
   SET salary_min = greatest(salary_min, 3500.00),
       salary_max = greatest(salary_max, 7000.00);

-- ---- repair balance_after relative to current accounts.balance --
-- accounts.balance is written atomically with every INSERT in all
-- three seeder paths, so it is the authoritative current balance.
-- Each historical row's balance_after must therefore equal:
--
--     accounts.balance - SUM(amount of every row strictly newer
--                            than this row)
--
-- so the displayed running balance lines up with reality at the
-- newest row and rolls backwards consistently through history.
-- (The previous repair anchored at zero and ignored each account's
-- opening balance -- that left rows internally consistent against
-- each other but disagreeing with accounts.balance, AND every
-- absolute number in the history was wrong.)
WITH ordered AS (
    SELECT t.tx_id, t.account_number, t.amount,
           a.balance AS cur_bal,
           sum(t.amount) OVER (
               PARTITION BY t.account_number
               ORDER BY t.tx_ts DESC, t.tx_id DESC
               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
           ) AS sum_top_incl_self
      FROM transactions t
      JOIN accounts a USING (account_number)
)
UPDATE transactions t
   SET balance_after =
           o.cur_bal - (o.sum_top_incl_self - t.amount)
  FROM ordered o
 WHERE t.tx_id = o.tx_id
   AND t.balance_after IS DISTINCT FROM
       (o.cur_bal - (o.sum_top_incl_self - t.amount));

-- ---- bank_seed_acct(idx int) -> char(23) -------------------------
CREATE OR REPLACE FUNCTION bank_seed_acct(idx int) RETURNS char(23) AS $$
    SELECT lpad((10000000000000000000000 + idx)::text, 23, '0')::char(23)
$$ LANGUAGE sql IMMUTABLE;

-- ---- bank_seed_credit(out vendor, out amt) ------------------------
-- Picks a random vendor + amount. Uses OFFSET with a random offset
-- (computed at call time) rather than ORDER BY random() LIMIT 1,
-- because the latter has fooled the planner into caching the result
-- across continuous-mode invocations.
CREATE OR REPLACE FUNCTION bank_seed_credit(out vendor varchar, out amt numeric)
RETURNS record AS $$
DECLARE
    v_count int;
    v_off   int;
    v_min   numeric;
    v_max   numeric;
BEGIN
    SELECT count(*) INTO v_count FROM vendors;
    v_off := floor(random() * v_count)::int;
    SELECT name, typical_min, typical_max
      INTO vendor, v_min, v_max
      FROM vendors
     ORDER BY vendor_id
     OFFSET v_off
     LIMIT 1;
    amt := round((v_min + (v_max - v_min) * random())::numeric, 2);
END;
$$ LANGUAGE plpgsql VOLATILE;

-- ---- bank_seed_atm() -> numeric -----------------------------------
CREATE OR REPLACE FUNCTION bank_seed_atm() RETURNS numeric AS $$
    SELECT (ARRAY[20, 40, 60, 80, 100, 200])
           [1 + floor(random() * 6)::int]::numeric
$$ LANGUAGE sql VOLATILE;

-- ---- bank_seed_wire(out cp, out amt) ------------------------------
-- Outgoing wires are tighter than before ($150 -- $1000) so a
-- single wire can't sink a paycheck's worth of headroom.
CREATE OR REPLACE FUNCTION bank_seed_wire(out cp varchar, out amt numeric)
RETURNS record AS $$
    SELECT (ARRAY[
                'Smith Family Trust',
                'Hudson Property Mgmt',
                'Westwood Mortgage Co',
                'Quarterly Tax Payment',
                'Bay Area Auto Finance',
                'Greenfield Investments',
                'Pine Hill Title Co',
                'Coastal Wealth Advisors',
                'Childrens Tuition Fund',
                'Sunrise Self Storage'
           ])[1 + floor(random() * 10)::int],
           round((150 + random() * 850)::numeric, 2)
$$ LANGUAGE sql VOLATILE;

-- ---- bank_seed_one_tx(cap int) -> text ----------------------------
-- Pick one eligible account, choose a type by the 90/5/5 roll,
-- insert the transaction, update balance, return one-line summary.
-- Every outgoing transaction (vendor charge, ATM, wire) is stored
-- with tx_type='DEB '; the description carries the specific flavour.
CREATE OR REPLACE FUNCTION bank_seed_one_tx(cap int) RETURNS text AS $$
DECLARE
    a_acct char(23);
    a_bal  numeric(15,2);
    r      double precision;
    v_amt  numeric(15,2);
    v_desc varchar(60);
    v_cp   varchar(60);
    v_cred record;
    v_wire record;
    new_bal numeric(15,2);
BEGIN
    SELECT a.account_number, a.balance
      INTO a_acct, a_bal
      FROM accounts a
     WHERE a.status = 'O'
       AND (SELECT count(*) FROM transactions t
             WHERE t.account_number = a.account_number
               AND t.tx_ts::date = CURRENT_DATE) < cap
     ORDER BY random()
     LIMIT 1;

    IF a_acct IS NULL THEN
        RETURN '';
    END IF;

    r := random();
    IF r < 0.90 THEN
        v_cred := bank_seed_credit();
        v_amt  := -v_cred.amt;
        v_desc := v_cred.vendor;
        v_cp   := v_cred.vendor;
    ELSIF r < 0.95 THEN
        v_amt  := -bank_seed_atm();
        v_desc := 'ATM cash withdrawal';
        v_cp   := 'ATM Network';
    ELSE
        v_wire := bank_seed_wire();
        v_amt  := -v_wire.amt;
        v_desc := 'Outgoing wire to ' || v_wire.cp;
        v_cp   := v_wire.cp;
    END IF;

    new_bal := a_bal + v_amt;

    INSERT INTO transactions (account_number, tx_type, amount,
                              description, counterparty, balance_after)
         VALUES (a_acct, 'DEB ', v_amt, v_desc, v_cp, new_bal);

    UPDATE accounts SET balance = new_bal
     WHERE account_number = a_acct;

    RETURN a_acct || ' DEB '
         || to_char(v_amt, 'SG999,999,990.00') || ' bal='
         || to_char(new_bal, 'FM999,999,990.00');
END;
$$ LANGUAGE plpgsql;

-- ---- bank_seed_salaries_due() -> int ------------------------------
-- Insert any salary deposits whose pay_period has elapsed since
-- last_paid (or since opened_date when last_paid IS NULL). Updates
-- account balance and last_paid. Returns the number of salaries
-- deposited this call. Safe to call once per outer tick.
CREATE OR REPLACE FUNCTION bank_seed_salaries_due() RETURNS int AS $$
DECLARE
    n_paid int := 0;
    s RECORD;
    a_bal numeric(15,2);
    new_bal numeric(15,2);
BEGIN
    -- Table alias is `sal`, not `s`: `s` is the PL/pgSQL loop record
    -- declared above, and a SQL alias colliding with it makes the
    -- planner read `s.account_number` as the not-yet-assigned record
    -- ("record s is not assigned yet").
    FOR s IN
        SELECT sal.account_number, sal.employer_name, sal.salary_amount,
               COALESCE(sal.last_paid, a.opened_date) AS effective_last,
               sal.pay_period_days
          FROM account_salary sal
          JOIN accounts a USING (account_number)
         WHERE a.status = 'O'
           AND CURRENT_DATE - COALESCE(sal.last_paid, a.opened_date)
               >= sal.pay_period_days
    LOOP
        SELECT balance INTO a_bal FROM accounts
         WHERE account_number = s.account_number;
        new_bal := a_bal + s.salary_amount;

        INSERT INTO transactions (account_number, tx_type, amount,
                                  description, counterparty, balance_after)
             VALUES (s.account_number, 'CRE ', s.salary_amount,
                     'Payroll deposit', s.employer_name, new_bal);

        UPDATE accounts SET balance = new_bal
         WHERE account_number = s.account_number;

        UPDATE account_salary
           SET last_paid = COALESCE(last_paid + (pay_period_days || ' day')::interval,
                                    CURRENT_DATE)::date
         WHERE account_number = s.account_number;

        n_paid := n_paid + 1;
    END LOOP;
    RETURN n_paid;
END;
$$ LANGUAGE plpgsql;

-- ---- bank_seed_backfill(days int, cap int) -> bigint --------------
-- One-shot bulk loader: for every open account, generate `days` of
-- past transactions back-dated across the last `days` calendar days
-- (3..cap transactions per simulated day, randomly distributed
-- across 24h). Computes balance_after via a window function so the
-- running total reflects the chosen amounts in tx_ts order.
-- Returns the number of rows inserted.
-- ---- bank_seed_backfill(days int, cap int) -> bigint --------------
-- Set-based bulk loader. Per-account, per-simulated-day we generate
-- 2..6 transactions (well below `cap` so per-period totals stay
-- comfortably under salary), assign each a random vendor / ATM /
-- wire detail, compute the running balance, INSERT everything in
-- one shot, then advance accounts.balance and account_salary.last_paid.
--
-- Vendor / wire / ATM picks are made by computing a per-row random
-- INDEX in the `raw` CTE (so random() is forced to evaluate per
-- row) and then JOINing against a row-numbered `vlist` -- the older
-- LATERAL subquery here was being short-circuited by the planner
-- and every row got the same vendor.
CREATE OR REPLACE FUNCTION bank_seed_backfill(days int, cap int)
RETURNS bigint AS $$
DECLARE
    n_ins   bigint;
    v_total int;
    w_total int := 10;
    a_total int := 6;
    w_cps text[] := ARRAY[
        'Smith Family Trust',
        'Hudson Property Mgmt',
        'Westwood Mortgage Co',
        'Quarterly Tax Payment',
        'Bay Area Auto Finance',
        'Greenfield Investments',
        'Pine Hill Title Co',
        'Coastal Wealth Advisors',
        'Childrens Tuition Fund',
        'Sunrise Self Storage'
    ];
    atm_amts numeric[] := ARRAY[20, 40, 60, 80, 100, 200];
BEGIN
    SELECT count(*) INTO v_total FROM vendors;

    WITH
    plan AS (
        SELECT a.account_number,
               a.opened_date,
               a.balance AS opening_balance,
               (CURRENT_DATE - d.day_off) AS sim_date,
               2 + floor(random() * 5)::int AS tx_n   -- 2..6 / day
          FROM accounts a
         CROSS JOIN generate_series(0, days - 1) AS d(day_off)
         WHERE a.status = 'O'
           AND (CURRENT_DATE - d.day_off) >= a.opened_date
    ),
    raw AS (
        SELECT p.account_number,
               p.opening_balance,
               (p.sim_date::timestamp
                + (floor(random() * 86400)::int || ' second')::interval) AS tx_ts,
               random() AS r_type,
               random() AS r_amt,
               1 + floor(random() * v_total)::int AS v_idx,
               1 + floor(random() * a_total)::int AS a_idx,
               1 + floor(random() * w_total)::int AS w_idx
          FROM plan p
         CROSS JOIN generate_series(1, p.tx_n) AS g(idx)
    ),
    vlist AS (
        SELECT name, typical_min, typical_max,
               row_number() OVER (ORDER BY vendor_id) AS rn
          FROM vendors
    ),
    fleshed AS (
        SELECT r.account_number, r.opening_balance, r.tx_ts,
               'DEB '::char(4) AS tx_type,
               CASE WHEN r.r_type < 0.90 THEN
                       -round((v.typical_min
                              + (v.typical_max - v.typical_min) * r.r_amt)::numeric, 2)
                    WHEN r.r_type < 0.95 THEN
                       -atm_amts[r.a_idx]
                    ELSE
                       -round((150 + r.r_amt * 850)::numeric, 2)
               END AS amount,
               CASE WHEN r.r_type < 0.90 THEN v.name
                    WHEN r.r_type < 0.95 THEN 'ATM cash withdrawal'
                    ELSE 'Outgoing wire to ' || w_cps[r.w_idx]
               END AS description,
               CASE WHEN r.r_type < 0.90 THEN v.name
                    WHEN r.r_type < 0.95 THEN 'ATM Network'
                    ELSE w_cps[r.w_idx]
               END AS counterparty
          FROM raw r
          LEFT JOIN vlist v ON v.rn = r.v_idx
    ),
    sal AS (
        SELECT s.account_number,
               a.opening_balance,
               (a.opened_date::timestamp + (gs.k || ' day')::interval)
                   + (floor(random() * 43200)::int || ' second')::interval AS tx_ts,
               'CRE '::char(4) AS tx_type,
               s.salary_amount AS amount,
               'Payroll deposit'::varchar AS description,
               s.employer_name::varchar AS counterparty
          FROM account_salary s
          JOIN (SELECT account_number, opened_date, balance AS opening_balance
                  FROM accounts WHERE status = 'O') a USING (account_number)
         CROSS JOIN LATERAL generate_series(s.pay_period_days,
                          (CURRENT_DATE - a.opened_date),
                          s.pay_period_days) AS gs(k)
    ),
    combined AS (
        SELECT account_number, opening_balance, tx_ts, tx_type,
               amount, description, counterparty FROM fleshed
        UNION ALL
        SELECT account_number, opening_balance, tx_ts, tx_type,
               amount, description, counterparty FROM sal
    ),
    capped AS (
        SELECT *
          FROM (SELECT c.*,
                       row_number() OVER (PARTITION BY account_number, tx_ts::date
                                          ORDER BY tx_ts) AS rn
                  FROM combined c) z
         WHERE rn <= cap
    ),
    withbal AS (
        SELECT account_number, tx_ts, tx_type, amount, description, counterparty,
               opening_balance
                   + sum(amount) OVER (PARTITION BY account_number
                                       ORDER BY tx_ts
                                       ROWS BETWEEN UNBOUNDED PRECEDING
                                                AND CURRENT ROW)
                   AS balance_after
          FROM capped
    ),
    inserted AS (
        INSERT INTO transactions (account_number, tx_ts, tx_type, amount,
                                  description, counterparty, balance_after)
        SELECT account_number, tx_ts, tx_type, amount, description,
               counterparty, balance_after
          FROM withbal
        RETURNING account_number, tx_ts, balance_after
    ),
    finals AS (
        SELECT DISTINCT ON (account_number) account_number, balance_after
          FROM inserted
         ORDER BY account_number, tx_ts DESC
    ),
    bal_update AS (
        UPDATE accounts a
           SET balance = f.balance_after
          FROM finals f
         WHERE a.account_number = f.account_number
        RETURNING 1
    ),
    sal_update AS (
        UPDATE account_salary s
           SET last_paid = CURRENT_DATE
         WHERE EXISTS (SELECT 1 FROM accounts a
                        WHERE a.account_number = s.account_number
                          AND a.status = 'O')
        RETURNING 1
    )
    SELECT count(*) INTO n_ins FROM inserted;

    RETURN n_ins;
END;
$$ LANGUAGE plpgsql;
PLSQL
}

# ---------------------------------------------------------------------
# Ensure $TOTAL_ACCOUNTS demo accounts exist. Builds names+addresses
# from inline arrays, generates emails+phones, and inserts via
# ON CONFLICT DO NOTHING so re-running is safe. Also seeds
# account_salary for any new account.
# ---------------------------------------------------------------------
ensure_accounts() {
    local have
    have=$(q "SELECT count(*) FROM accounts")
    if [[ "$have" -ge "$TOTAL_ACCOUNTS" ]]; then
        echo "bank_seeder: $have accounts present (>= $TOTAL_ACCOUNTS), skipping create"
        return
    fi

    echo "bank_seeder: have $have accounts, creating up to $TOTAL_ACCOUNTS"

    # 200 unique first+last combos via Cartesian (15 x 15 = 225 > 200).
    # Realistic street+city+state+zip taken from a 40-row list.
    q_stdin <<PLSQL
DO \$\$
DECLARE
    first_names text[] := ARRAY[
        'James','Mary','Robert','Patricia','John','Jennifer','Michael',
        'Linda','William','Elizabeth','David','Barbara','Richard',
        'Susan','Joseph','Jessica','Thomas','Sarah','Charles','Karen',
        'Daniel','Lisa','Matthew','Nancy','Anthony','Betty','Mark',
        'Sandra','Donald','Ashley','Steven','Kimberly','Paul','Donna',
        'Andrew','Emily','Joshua','Carol','Kenneth','Michelle','Kevin',
        'Amanda','Brian','Melissa','George','Deborah','Edward',
        'Stephanie','Ronald','Rebecca'
    ];
    last_names text[] := ARRAY[
        'Smith','Johnson','Williams','Brown','Jones','Garcia','Miller',
        'Davis','Rodriguez','Martinez','Hernandez','Lopez','Gonzalez',
        'Wilson','Anderson','Thomas','Taylor','Moore','Jackson',
        'Martin','Lee','Perez','Thompson','White','Harris','Sanchez',
        'Clark','Ramirez','Lewis','Robinson','Walker','Young','Allen',
        'King','Wright','Scott','Torres','Nguyen','Hill','Flores',
        'Green','Adams','Nelson','Baker','Hall','Rivera','Campbell',
        'Mitchell','Carter','Roberts'
    ];
    streets text[] := ARRAY[
        'Main St','Oak Ave','Maple Dr','Pine Rd','Elm St','Cedar Ln',
        'Park Pl','Sunset Blvd','Lakeview Ter','Hillcrest Dr','Madison Ave',
        'Jefferson St','Washington Pl','Lincoln Way','Adams Cir',
        'Riverbend Rd','Willow Brook Ln','Mountain View Dr','Forest Glen',
        'Highland Ave','Spring St','Summit Ridge','Valley Rd','Birch Way',
        'Magnolia Ct','Aspen Dr','Cypress Ln','Sycamore St','Walnut Ave',
        'Chestnut Pl'
    ];
      -- Three parallel arrays. (We avoid text[][] here because
      -- PL/pgSQL's array indexing with a single subscript on a
      -- 2-D array returns NULL rather than a 1-D slice, which
      -- silently broke the previous design.)
    city_names text[] := ARRAY[
        'Austin','Portland','Denver','Boston','Seattle','Atlanta',
        'Chicago','Minneapolis','Nashville','Charlotte','San Diego',
        'Phoenix','Las Vegas','Salt Lake City','Kansas City',
        'Indianapolis','Columbus','Raleigh','Tampa','Pittsburgh',
        'Cleveland','Sacramento','Albany','Hartford','Providence',
        'Richmond','Louisville','Birmingham','Tulsa','Omaha'
    ];
    states text[] := ARRAY[
        'TX','OR','CO','MA','WA','GA','IL','MN','TN','NC','CA','AZ',
        'NV','UT','MO','IN','OH','NC','FL','PA','OH','CA','NY','CT',
        'RI','VA','KY','AL','OK','NE'
    ];
    zips text[] := ARRAY[
        '78701','97201','80202','02108','98101','30301','60601',
        '55401','37201','28202','92101','85001','89101','84101',
        '64101','46201','43201','27601','33601','15201','44101',
        '94203','12201','06101','02901','23218','40201','35201',
        '74101','68101'
    ];
    fn_count int := array_length(first_names, 1);
    ln_count int := array_length(last_names, 1);
    st_count int := array_length(streets, 1);
    cy_count int := array_length(city_names, 1);
    ci int;
    target   int := $TOTAL_ACCOUNTS;
    have     int := (SELECT count(*) FROM accounts);
    needed   int := target - have;
    inserted int := 0;
    attempt  int := 0;
    max_attempts int := needed * 20;
    new_acct char(23);
    fn text; ln text; mi text;
    streetnum int;
    addr text;
    em text; ph text;
    emp_id int;
    emp_name text;
    emp_min numeric; emp_max numeric;
    salary numeric(12,2);
    opened date;
BEGIN
    WHILE inserted < needed AND attempt < max_attempts LOOP
        attempt := attempt + 1;
        fn := first_names[1 + floor(random() * fn_count)::int];
        ln := last_names[1 + floor(random() * ln_count)::int];
        mi := chr(65 + floor(random() * 26)::int);
        streetnum := 1 + floor(random() * 9998)::int;
        addr := streetnum::text || ' ' || streets[1 + floor(random() * st_count)::int];
        ci := 1 + floor(random() * cy_count)::int;
        em := lower(fn) || '.' || lower(ln) || floor(random() * 900)::int::text
              || '@example.com';
        ph := '(' || (200 + floor(random() * 700)::int)::text || ') '
              || (200 + floor(random() * 700)::int)::text || '-'
              || lpad(floor(random() * 10000)::int::text, 4, '0');
        opened := CURRENT_DATE - ($BACKFILL_DAYS + floor(random() * 720)::int);

        new_acct := bank_seed_acct(nextval('bank_acct_seq')::int);

        BEGIN
            INSERT INTO accounts (account_number, last_name, first_name,
                                  middle_init, street, city, state, zip,
                                  email, phone, balance, status,
                                  opened_date)
            VALUES (new_acct, ln, fn, mi, addr,
                    city_names[ci], states[ci], zips[ci],
                    em, ph,
                    round((500 + random() * 24500)::numeric, 2),
                    'O', opened);
        EXCEPTION WHEN unique_violation THEN
            CONTINUE;
        END;

        -- Pick a random employer and salary for the new account.
        SELECT employer_id, name, salary_min, salary_max
          INTO emp_id, emp_name, emp_min, emp_max
          FROM employers ORDER BY random() LIMIT 1;
        salary := round((emp_min + (emp_max - emp_min) * random())::numeric, 2);
        INSERT INTO account_salary (account_number, employer_name,
                                    salary_amount, last_paid,
                                    pay_period_days)
             VALUES (new_acct, emp_name, salary, opened, 14);

        inserted := inserted + 1;
        IF inserted % 25 = 0 THEN
            RAISE NOTICE 'seeded % / %', inserted, needed;
        END IF;
    END LOOP;
    RAISE NOTICE 'done. inserted % accounts (attempts=%)', inserted, attempt;
END;
\$\$;
PLSQL
}

# ---------------------------------------------------------------------
# -init: bulk backfill.
# ---------------------------------------------------------------------
do_backfill() {
    # -init is a clean-slate operation. The accounts row stays (so any
    # OPEN-account work done from BANK survives) but the transaction
    # history is truncated, every balance reverts to a small random
    # opening deposit, and account_salary.last_paid resets to NULL.
    # That way re-running -init always reproduces the same shape of
    # 180-day history with the latest seeder taxonomy / amount mix.
    local existing
    existing=$(q "SELECT count(*) FROM transactions")
    echo "bank_seeder: -init reset -- truncating $existing existing transactions"
    q_stdin <<'PLSQL'
TRUNCATE transactions RESTART IDENTITY;
UPDATE accounts
   SET balance = round((500 + random() * 2500)::numeric, 2)
 WHERE status = 'O';
UPDATE account_salary SET last_paid = NULL;
PLSQL

    echo "bank_seeder: starting -init bulk backfill ($BACKFILL_DAYS days, cap $DAILY_TX_CAP/day)"
    local started
    started=$(date +%s)
    local inserted
    inserted=$(q "SELECT bank_seed_backfill($BACKFILL_DAYS, $DAILY_TX_CAP)")
    local elapsed=$(( $(date +%s) - started ))
    local total accts span
    total=$(q "SELECT count(*) FROM transactions")
    accts=$(q "SELECT count(DISTINCT account_number) FROM transactions")
    span=$(q "SELECT to_char(min(tx_ts), 'YYYY-MM-DD') || ' .. ' || to_char(max(tx_ts), 'YYYY-MM-DD') FROM transactions")
    echo "bank_seeder: backfill done -- inserted $inserted txs across $accts accounts in ${elapsed}s"
    echo "bank_seeder: transactions table now holds $total rows spanning $span"
}

# ---------------------------------------------------------------------
# Continuous mode helpers.
# ---------------------------------------------------------------------
print_stats() {
    local ts total dbsz top5
    ts=$(date '+%H:%M:%S')
    total=$(q "SELECT count(*) FROM transactions")
    dbsz=$(q "SELECT pg_size_pretty(pg_database_size(current_database()))")
    top5=$(q "
        SELECT string_agg(
            substr(account_number, 1, 4) || '..' ||
            substr(account_number, 20, 4) || '=' || c::text,
            '  ')
        FROM (SELECT account_number, count(*) AS c
                FROM transactions
               GROUP BY account_number
               ORDER BY c DESC LIMIT 5) z")
    echo "[$ts] stats  tx_total=$total  db=$dbsz"
    echo "         top5: $top5"
}

# ---------------------------------------------------------------------
# Entry.
# ---------------------------------------------------------------------
echo "bank_seeder: host=$BANK_HOST port=$BANK_PORT db=$BANK_DB mode=$MODE"
install_helpers
ensure_accounts

if [[ "$MODE" == "init" ]]; then
    do_backfill
    exit 0
fi

# ---- continuous loop ------------------------------------------------
echo "bank_seeder: entering continuous mode (TICK=${TICK_SECONDS}s, CAP=${DAILY_TX_CAP}/day). Ctrl-C to stop."
LAST_STATS=$(date +%s)
LAST_SAL_CHECK=0

while true; do
    NOW=$(date +%s)

    # Run the salary scan at most once an hour to keep load tiny.
    if (( NOW - LAST_SAL_CHECK >= 3600 )); then
        N=$(q "SELECT bank_seed_salaries_due()")
        if [[ "$N" -gt 0 ]]; then
            echo "[$(date '+%H:%M:%S')] payroll: deposited $N salaries"
        fi
        LAST_SAL_CHECK=$NOW
    fi

    LINE=$(q "SELECT bank_seed_one_tx($DAILY_TX_CAP)")
    if [[ -z "$LINE" ]]; then
        echo "[$(date '+%H:%M:%S')] note   all accounts at daily cap; idling"
    else
        echo "[$(date '+%H:%M:%S')] tx     $LINE"
    fi

    if (( NOW - LAST_STATS >= STATS_INTERVAL )); then
        print_stats
        LAST_STATS=$NOW
    fi

    # +/- 20% jitter on the configured tick. Bash $RANDOM is 0..32767.
    JIT_RANGE=$(( TICK_SECONDS * 4 / 10 + 1 ))
    JIT=$(( RANDOM % JIT_RANGE - JIT_RANGE / 2 ))
    SLEEP=$(( TICK_SECONDS + JIT ))
    (( SLEEP < 1 )) && SLEEP=1
    sleep "$SLEEP"
done
