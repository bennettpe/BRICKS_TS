/* SQLR -- embedded-SQL demo (REXX). REXX twin of SQLD: same demo, */
/* same SQLD1 map. Operator types a customer id; SQLR runs a       */
/* SELECT INTO against customers_sql and renders the result.       */
/*                                                                  */
/*     EXEC SQL SELECT name INTO :CUSTNM :CUSTNMIND                 */
/*              FROM customers_sql WHERE id = :CUSTID END-EXEC      */
/*                                                                  */
/* SQL stynax  shown here:                                  */
/*   - EXEC SQL WHENEVER       declarative error-handling directive */
/*   - a null indicator on the SELECT INTO ( :CUSTNM :CUSTNMIND )   */
/*   - a SELECT/WHEN over the expanded SQLCODE catalog, including   */
/*     -952 timeout / -911 deadlock / -924 conn-lost / -204 no-tbl  */
/*                                                                  */
/* Why CUSTNM and not just NM? In REXX, `SCR.NM` resolves the tail  */
/* through the value of symbol `NM`, so if NM were also a simple    */
/* var its value would become the tail. We dodge that classic REXX */
/* gotcha by using host-var names (CUSTNM, CUSTNMIND) that are not  */
/* also tails of the SCR. map stem.                                 */
/*                                                            */
/* Expected schema (run once via sql_bricks_statements.sql):        */
/*                                                                  */
/*     CREATE TABLE customers_sql (                                 */
/*         id   text PRIMARY KEY,                                   */
/*         name text NOT NULL                                       */
/*     );                                                           */
/*     INSERT INTO customers_sql VALUES                             */
/*         ('K001', 'Alice'),                                       */
/*         ('K002', 'Bob'),                                         */
/*         ('K003', 'Carol');                                       */

ADDRESS CICS

EXEC CICS ASSIGN TERMID(TRM) END-EXEC

SCR. = ''
SCR.TERMID = TRM
SCR.NM = ''
SCR.SQLCD = ''
SCR.SQLST = ''
SCR.SQLERR = ''

EXEC CICS SEND MAP('SQLD1') FROM(SCR.) ERASE END-EXEC
EXEC CICS RECEIVE MAP('SQLD1') INTO(SCR.) END-EXEC

/* PF3 exits. */
IF C2X(EIBAID) = 'F3' THEN DO
    EXEC CICS RETURN END-EXEC
END

CUSTID = STRIP(SCR.CUSTID)
CUSTNM = ''
CUSTNMIND = ''

/* WHENEVER SQLERROR CONTINUE states explicitly that this program  */
/* inspects SQLCODE itself -- via the SELECT/WHEN below -- rather  */
/* than SIGNALing to a label. CONTINUE is the default, and  this     */
/* documents intent. To use the declarative style instead, swap    */
/* it for `WHENEVER SQLERROR GOTO SQLERR` and control jumps to the */
/* SQLERR: label after any statement whose SQLCODE is negative.    */
EXEC SQL WHENEVER SQLERROR CONTINUE END-EXEC

/* SELECT INTO with a null indicator: :CUSTNM receives the name,   */
/* :CUSTNMIND receives 0 (value present) or -1 (column was NULL).  */
/* customers_sql.name is NOT NULL, so CUSTNMIND is 0 in practice;  */
/* the syntax and the IF CUSTNMIND = -1 branch show how a program  */
/* flags a NULL when the column DOES permit one.                   */
EXEC SQL
    SELECT name INTO :CUSTNM :CUSTNMIND
    FROM customers_sql
    WHERE id = :CUSTID
END-EXEC

/* SQLERRMC holds the raw PG error and is available for programs   */
/* that want it; bricks also logs the full text to console + log   */
/* on every error path. This sample keeps the screen friendly by   */
/* mapping SQLCODE to a short message instead of dumping the raw   */
/* PG diagnostic (which would expose host:port / wrapper detail).  */
SCR.NM = CUSTNM
SCR.SQLCD = SQLCODE
SCR.SQLST = SQLSTATE

SELECT
    WHEN SQLCODE = 0 THEN DO
        IF CUSTNMIND = -1 THEN DO
            SCR.SQLERR = 'Row found, but name is NULL.'
            SCR.NM = ''
        END
        ELSE
            SCR.SQLERR = 'OK'
    END
    WHEN SQLCODE = 100 THEN DO
        SCR.SQLERR = 'No customer with that id.'
        SCR.NM = ''
    END
    WHEN SQLCODE = -1 THEN DO
        SCR.SQLERR = 'SQL not configured in bricks.cnf.'
        SCR.NM = ''
    END
    WHEN SQLCODE = -204 THEN DO
        SCR.SQLERR = 'customers_sql table not found.'
        SCR.NM = ''
    END
    WHEN SQLCODE = -811 THEN DO
        SCR.SQLERR = 'Multiple rows -- query must be unique.'
        SCR.NM = ''
    END
    WHEN SQLCODE = -911 THEN DO
        SCR.SQLERR = 'Deadlock -- retry the transaction.'
        SCR.NM = ''
    END
    WHEN SQLCODE = -924 THEN DO
        SCR.SQLERR = 'Lost the Postgres connection.'
        SCR.NM = ''
    END
    WHEN SQLCODE = -952 THEN DO
        SCR.SQLERR = 'Query timed out (db_stmt_timeout).'
        SCR.NM = ''
    END
    OTHERWISE DO
        SCR.SQLERR = 'SQL error -- see bricks console log.'
        SCR.NM = ''
    END
END

EXEC CICS SEND MAP('SQLD1') FROM(SCR.) ERASE END-EXEC
EXEC CICS RECEIVE MAP('SQLD1') INTO(SCR.) END-EXEC

EXEC CICS RETURN END-EXEC
EXIT
