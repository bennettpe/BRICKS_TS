      *> SQLD -- embedded-SQL demo (COBOL). Operator types a customer
      *>   id; SQLD runs a SELECT INTO against customers_sql and renders
      *> the result + SQLCA on the SQLD1 screen. SQLR is the REXX
      *> twin -- same demo, same map.
      *> Copyright 2026 by moshix 
      *> SQL syntx  shown here:
      *>   - EXEC SQL WHENEVER       -- declarative error-handling
      *>                                directive (see the comment
      *>                                at WHENEVER below).
      *>   - a null indicator on the SELECT INTO ( :NM :NMIND ).
      *>   - EVALUATE over the expanded SQLCODE catalogue, including
      *>     SQL-TIMEOUT / SQL-DEADLOCK / SQL-CONNLOST / SQL-UNDEF-TBL.
      *>   - the SQLCA copybook constants 
      *>    Use the SQLCA copybook (COPY SQLCA)!!
      *>
      *> Expected schema (run once via sql_bricks_statements.sql):
      *>
      *>     CREATE TABLE customers_sql (
      *>         id   text PRIMARY KEY,
      *>         name text NOT NULL
      *>     );
      *>     INSERT INTO customers_sql VALUES
      *>         ('K001', 'Alice'),
      *>         ('K002', 'Bob'),
      *>         ('K003', 'Carol');
      *>
      *> SQLCODE values an operator should expect from this program:
      *>     0    NORMAL -- name comes back
      *>   +100   no row with that id
      *>    -1   bricks.cnf has no db_* lines (SQL not configured)
      *>  -204   customers_sql table not found
      *>  -811   id matched more than one row (shouldn't, id is a PK)
      *>  -911   deadlock / serialization -- retry
      *>  -924   Postgres connection lost
      *>  -952   query exceeded db_stmt_timeout
      *>  other  PG-side error -- SQLSTATE carries the precise code,
      *>         and bricks logs the full text to console + log.
       IDENTIFICATION DIVISION.
       PROGRAM-ID. SQLD.

       DATA DIVISION.
       WORKING-STORAGE SECTION.
       COPY DFHAID.
       COPY DFHRESP.
       COPY SQLCA.

       01 TRM PIC X(8).

      *> Null indicator for the name column. The SELECT INTO below
      *> writes 0 here when the column had a value, -1 when it was
      *> SQL NULL. customers_sql.name is declared NOT NULL, so NMIND
      *> is always 0 in practice -- the :NM :NMIND syntax and the
      *> IF NMIND = -1 branch are kept to show how a program flags a
      *> NULL when the column DOES permit one.
       01 NMIND PIC S9(8).

      *> SQLD1 IO group. CUSTID is the operator input; NM holds the
      *> name fetched by the SELECT INTO. SQLCD / SQLST / SQLERR
      *> mirror the SQLCA into display-shaped fields so the operator
      *> sees the actual SQLCODE / SQLSTATE plus a friendly message.
       01 SCR.
          05 TERMID PIC X(8).
          05 CUSTID PIC X(10).
          05 NM     PIC X(30).
          05 SQLCD  PIC X(8).
          05 SQLST  PIC X(5).
          05 SQLERR PIC X(60).

       PROCEDURE DIVISION.
       MAIN.
           EXEC CICS ASSIGN TERMID(TRM) END-EXEC.
           MOVE SPACES TO SCR.
           MOVE TRM TO TERMID.

      *> Initial prompt: blank fields, cursor on CUSTID.
           EXEC CICS CONVERSE MAP('SQLD1') FROM(SCR) INTO(SCR)
                              ERASE END-EXEC.

      *> PF3 exits cleanly.
           IF EIBAID = PF03 THEN
               EXEC CICS RETURN END-EXEC
               STOP RUN
           END-IF.

      *> WHENEVER SQLERROR CONTINUE states explicitly that this
      *> program inspects SQLCODE itself -- via the EVALUATE below --
      *> rather than branching to an error paragraph. CONTINUE is the
      *> default for every condition, so this line documents intent.
      *> To use the declarative style instead, swap it for:
      *>     EXEC SQL WHENEVER SQLERROR GO TO SQL-ERROR END-EXEC.
      *> and control jumps to the SQL-ERROR paragraph after any
      *> statement whose SQLCODE is negative.
           EXEC SQL WHENEVER SQLERROR CONTINUE END-EXEC.

      *> SELECT INTO with a null indicator. :NM receives the name;
      *> :NMIND receives 0 (value present) or -1 (column was NULL).
      *> The auto-injected SQLCODE / SQLSTATE carry the verdict.
      *> SQLERRMC holds the raw PG error for programmers who want it,
      *> but bricks ALSO writes the full text to the console / log,
      *> so this sample shows only short, operator-friendly messages.
           EXEC SQL
               SELECT name INTO :NM :NMIND
               FROM customers_sql
               WHERE id = :CUSTID
           END-EXEC.

      *> Mirror the raw SQLCODE / SQLSTATE onto the screen, then map
      *> SQLCODE to a short friendly note keyed off the SQLCA
      *> copybook constants. Branching on the named constants keeps
      *> the program readable and survives any future renumbering.
           MOVE SQLCODE  TO SQLCD.
           MOVE SQLSTATE TO SQLST.

           EVALUATE SQLCODE
               WHEN SQL-OK
                   IF NMIND = -1 THEN
                       MOVE 'Row found, but name is NULL.' TO SQLERR
                       MOVE SPACES TO NM
                   ELSE
                       MOVE 'OK' TO SQLERR
                   END-IF
               WHEN SQL-NODATA
                   MOVE 'No customer with that id.' TO SQLERR
                   MOVE SPACES TO NM
               WHEN SQL-NOCONFIG
                   MOVE 'SQL not configured in bricks.cnf.' TO SQLERR
                   MOVE SPACES TO NM
               WHEN SQL-MULTIPLEROWS
                   MOVE 'Multiple rows -- query must be unique.' TO SQLERR
                   MOVE SPACES TO NM
               WHEN SQL-UNDEF-TBL
                   MOVE 'customers_sql table not found.' TO SQLERR
                   MOVE SPACES TO NM
               WHEN SQL-TIMEOUT
                   MOVE 'Query timed out (db_stmt_timeout).' TO SQLERR
                   MOVE SPACES TO NM
               WHEN SQL-DEADLOCK
                   MOVE 'Deadlock -- retry the transaction.' TO SQLERR
                   MOVE SPACES TO NM
               WHEN SQL-CONNLOST
                   MOVE 'Lost the Postgres connection.' TO SQLERR
                   MOVE SPACES TO NM
               WHEN OTHER
                   MOVE 'SQL error -- see bricks console log.' TO SQLERR
                   MOVE SPACES TO NM
           END-EVALUATE.

      *> Show the result. ENTER returns to the prompt for another
      *> lookup; PF3 exits.
           EXEC CICS CONVERSE MAP('SQLD1') FROM(SCR) INTO(SCR)
                              ERASE END-EXEC.

           EXEC CICS RETURN END-EXEC.
           STOP RUN.
