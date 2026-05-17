      *> SQLCA  Named constants for the EXEC SQL communications
      *> area: SQLCODE values and the most common SQLSTATE strings.
      *>
      *> Bricks auto-injects the full DB2-shape SQLCA into every
      *> COBOL program's DATA DIVISION -- no `COPY` is needed for
      *> the fields themselves:
      *>
      *>   SQLCODE   PIC S9(8) signed   -- 0 ok, +100 no-data, neg=err
      *>   SQLSTATE  PIC X(5)           -- 5-char PG state, "00000" ok
      *>   SQLERRMC  PIC X(70)          -- short human message
      *>   SQLERRP   PIC X(8)           -- product tag, "BRICKS  "
      *>   SQLERRD1..SQLERRD6 PIC S9(9) -- diagnostic ints; SQLERRD3
      *>                                  carries rows-affected
      *>   SQLWARN0..SQLWARN9, SQLWARNA PIC X -- warning flags
      *>
      *> This copybook provides the named CONSTANTS programs
      *> compare against. A typical EVALUATE SQLCODE looks like:
      *>
      *>     COPY SQLCA.
      *>     ...
      *>     EXEC SQL INSERT INTO orders VALUES (:ID, :CUST) END-EXEC.
      *>     EVALUATE SQLCODE
      *>         WHEN SQL-OK         DISPLAY 'Inserted ' SQLERRD3
      *>         WHEN SQL-DUPKEY     DISPLAY 'Order exists'
      *>         WHEN SQL-FKVIOL     DISPLAY 'Unknown customer'
      *>         WHEN SQL-DEADLOCK   PERFORM RETRY-WITH-BACKOFF
      *>         WHEN SQL-TIMEOUT    DISPLAY 'Query took too long'
      *>         WHEN OTHER          DISPLAY 'See bricks log'
      *>     END-EVALUATE.
      *>
      *> Each constant is also delivered under its IBM-DB2 alias
      *> (DB2-SUCCESS, DB2-NOTFOUND, DB2-DUP-KEY, DB2-DEADLOCK,
      *> DB2-FOREIGN-KEY, DB2-UNDEF-TABLE, DB2-DUPLICATE) so
      *> programs ported from real DB2 / mainframe CICS keep
      *> compiling without renames.
      *>
      *> The SQLSTATE values are PIC X(5) -- compare directly:
      *>     IF SQLSTATE = SQLSTATE-DUP-KEY THEN ...
      *>
      *> ── SQLCODE summary table ──────────────────────────────
      *>    0    SQL-OK             success
      *>  100    SQL-NODATA         no row matched
      *>   -1    SQL-NOCONFIG       SQL not configured in bricks.cnf
      *>   -2    SQL-DDLREJECTED    CREATE/DROP/ALTER DATABASE etc.
      *> -104    SQL-SYNTAX         malformed SQL
      *> -203    SQL-AMBIG-COL      column reference is ambiguous
      *> -204    SQL-UNDEF-TBL      table/view not found
      *> -206    SQL-UNDEF-COL      column not found
      *> -407    SQL-NOTNULL        null into NOT NULL column
      *> -433    SQL-STRTRUNC       value too long for destination
      *> -530    SQL-FKVIOL         foreign-key violation
      *> -545    SQL-CHKVIOL        check-constraint violation
      *> -551    SQL-INSUF-PRIV     operator not authorised
      *> -802    SQL-NUMOVERFLOW    numeric value out of range
      *> -803    SQL-DUPKEY         unique / primary-key violation
      *> -811    SQL-MULTIPLEROWS   SELECT INTO returned >1 row
      *> -911    SQL-DEADLOCK       deadlock / serialisation rollback
      *> -924    SQL-CONNLOST       PG connection failure
      *> -952    SQL-TIMEOUT        statement cancelled (timeout)
      *> -100    SQL-GENERIC        catch-all; SQLSTATE has the real
      *>                            PG state, SQLERRMC the message

      *> ── SQLCODE constants ──────────────────────────────────
       01 SQL-OK             PIC S9(8) VALUE 0.
       01 DB2-SUCCESS        PIC S9(8) VALUE 0.
       01 SQL-NODATA         PIC S9(8) VALUE 100.
       01 SQL-NOTFND         PIC S9(8) VALUE 100.
       01 DB2-NOTFOUND       PIC S9(8) VALUE 100.

      *> bricks-specific: -1 = SQL not configured in bricks.cnf
      *> (no db_host line). Surfaced so a program can degrade
      *> gracefully on an SQL-less bricks install.
       01 SQL-NOCONFIG       PIC S9(8) VALUE -1.

      *> bricks-specific: -2 = DDL rejected. CREATE / DROP / ALTER
      *> on DATABASE / USER / ROLE / TABLESPACE go through CEDA
      *> DATABASE; programs cannot run them via EXEC SQL.
       01 SQL-DDLREJECTED    PIC S9(8) VALUE -2.

      *> -100 = generic PG-side error. SQLSTATE carries the
      *> precise 5-char code; SQLERRMC has the human-readable
      *> message (and the full text is also written to the bricks
      *> console / log so terminal screens stay friendly).
       01 SQL-GENERIC        PIC S9(8) VALUE -100.

      *> ── DB2-shape SQLCODEs the executor emits when the
      *> underlying Postgres SQLSTATE is recognised. Programs can
      *> branch on these specific codes instead of stuffing every
      *> failure into SQL-GENERIC. The PG SQLSTATE is still
      *> available in SQLSTATE for any case the catalog misses.

      *> -104 = SQL syntax error (PG 42601).
       01 SQL-SYNTAX         PIC S9(8) VALUE -104.

      *> -203 = ambiguous column reference (PG 42702).
       01 SQL-AMBIG-COL      PIC S9(8) VALUE -203.

      *> -204 = table or view not found (PG 42P01).
       01 SQL-UNDEF-TBL      PIC S9(8) VALUE -204.
       01 DB2-UNDEF-TABLE    PIC S9(8) VALUE -204.

      *> -206 = column not found (PG 42703).
       01 SQL-UNDEF-COL      PIC S9(8) VALUE -206.

      *> -407 = null assigned to NOT NULL column (PG 23502).
       01 SQL-NOTNULL        PIC S9(8) VALUE -407.

      *> -433 = string truncation (PG 22001).
       01 SQL-STRTRUNC       PIC S9(8) VALUE -433.

      *> -530 = foreign-key constraint violation (PG 23503).
       01 SQL-FKVIOL         PIC S9(8) VALUE -530.
       01 DB2-FOREIGN-KEY    PIC S9(8) VALUE -530.

      *> -545 = check-constraint violation (PG 23514).
       01 SQL-CHKVIOL        PIC S9(8) VALUE -545.

      *> -551 = operator not authorised (PG 42501).
       01 SQL-INSUF-PRIV     PIC S9(8) VALUE -551.

      *> -802 = numeric value out of range (PG 22003).
       01 SQL-NUMOVERFLOW    PIC S9(8) VALUE -802.

      *> -803 = duplicate-key violation on a UNIQUE or PRIMARY
      *> KEY constraint (PG 23505). Same code DB2 emits.
       01 SQL-DUPKEY         PIC S9(8) VALUE -803.
       01 DB2-DUP-KEY        PIC S9(8) VALUE -803.

      *> -811 = SELECT INTO returned more than one row. Matches
      *> DB2's classic code so porters see familiar values.
       01 SQL-MULTIPLEROWS   PIC S9(8) VALUE -811.
       01 DB2-DUPLICATE      PIC S9(8) VALUE -811.

      *> -911 = transaction rolled back by the server. PG raises
      *> this for serialization failures (40001) and deadlocks
      *> (40P01). Programs can retry after backing off.
       01 SQL-DEADLOCK       PIC S9(8) VALUE -911.
       01 DB2-DEADLOCK       PIC S9(8) VALUE -911.

      *> -924 = connection failure (PG class 08). The PG pool will
      *> generally re-open on the next statement; programs can
      *> abend or retry.
       01 SQL-CONNLOST       PIC S9(8) VALUE -924.

      *> -952 = statement cancelled (PG 57014). Bricks fires this
      *> when a statement timeout is configured and trips, or
      *> when an admin cancels the backend.
       01 SQL-TIMEOUT        PIC S9(8) VALUE -952.

      *> ── SQLSTATE constants (PIC X(5)) ──────────────────────
       01 SQLSTATE-OK        PIC X(5) VALUE '00000'.
       01 SQLSTATE-NODATA    PIC X(5) VALUE '02000'.
       01 SQLSTATE-WARNING   PIC X(5) VALUE '01000'.
      *> Constraint violations (Postgres class 23).
       01 SQLSTATE-NOT-NULL  PIC X(5) VALUE '23502'.
       01 SQLSTATE-FK-VIOL   PIC X(5)  VALUE '23503'.
       01 SQLSTATE-UQ-VIOL   PIC X(5) VALUE '23505'.
       01 SQLSTATE-DUP-KEY   PIC X(5) VALUE '23505'.
       01 SQLSTATE-CHK-VIOL  PIC X(5) VALUE '23514'.
      *> Connection / auth (class 08, 28).
       01 SQLSTATE-CONN-FAIL PIC X(5) VALUE '08001'.
       01 SQLSTATE-CONN-LOST PIC X(5)   VALUE '08006'.
       01 SQLSTATE-INV-AUTH  PIC X(5) VALUE '28000'.
       01 SQLSTATE-INV-PWD   PIC X(5) VALUE '28P01'.
      *> Syntax / catalog (class 42).
       01 SQLSTATE-SYNTAX    PIC X(5) VALUE '42601'.
       01 SQLSTATE-UNDEF-TBL PIC X(5) VALUE '42P01'.
       01 SQLSTATE-UNDEF-COL PIC X(5)    VALUE '42703'.
       01 SQLSTATE-UNDEF-FN  PIC X(5) VALUE '42883'.
       01 SQLSTATE-AMBIG-COL PIC X(5) VALUE '42702'.
      *> Permission (class 42 sub-set / 0L).
       01 SQLSTATE-INSUF-PRIV PIC X(5) VALUE '42501'.
      *> String-data exceptions (class 22).
       01 SQLSTATE-STRTRUNC  PIC X(5) VALUE '22001'.
       01 SQLSTATE-NUMOVF    PIC X(5) VALUE '22003'.
      *> Transaction rollback (class 40) -- bricks maps both to
      *> SQL-DEADLOCK / SQLCODE -911; SQLSTATE preserves which.
       01 SQLSTATE-SERIAL    PIC X(5) VALUE '40001'.
       01 SQLSTATE-DEADLOCK  PIC X(5) VALUE '40P01'.
      *> Statement timeout / cancel (class 57).
       01 SQLSTATE-TIMEOUT   PIC X(5) VALUE '57014'.

      *> ── Extended SQLCA fields (auto-injected by bricks) ─────
      *>
      *> Beyond SQLCODE, SQLSTATE, and SQLERRMC, every COBOL EXEC
      *> SQL program also has the DB2-shape extended fields
      *> available without declaring them. Bricks resets them on
      *> every statement so a stale value from the previous call
      *> can't bleed forward.
      *>
      *>   SQLERRP            PIC X(8)
      *>       Product/function tag. Bricks fills 'BRICKS  '.
      *>
      *>   SQLERRD1..SQLERRD6 PIC S9(9) COMP
      *>       Six-int diagnostic array. The operationally-
      *>       important slot is SQLERRD3 = rows affected after
      *>       INSERT / UPDATE / DELETE / FETCH. Others stay 0
      *>       (the slots exist for porting compatibility).
      *>
      *>       Typical use:
      *>         EXEC SQL DELETE FROM customers
      *>                  WHERE inactive = 'Y' END-EXEC.
      *>         IF SQLCODE = SQL-OK THEN
      *>             DISPLAY 'Removed ' SQLERRD3 ' rows.'.
      *>
      *>   SQLWARN0..SQLWARN9, SQLWARNA  PIC X (11 single-char
      *>       flags). 'W' means "warning fired"; ' ' is the
      *>       default. Bricks rarely sets these because PG
      *>       errors rather than warns, but the slots exist so
      *>       ported programs that test them compile.
