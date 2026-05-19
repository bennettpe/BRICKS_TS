      *> BANK -- pseudo-conversational retail-banking demo.
      *> copyright 2026 by moshix all rights reserved
      *>
      *> Each task: RECEIVE MAP (the operator's input from the prior
      *> task's SEND, captured in Sess.LastResponse) -> process ->
      *> SEND MAP (the next screen, which blockks for the next ENTER) ->
      *> RETURN TRANSID('BANK') COMMAREA(STATE). The bricks dispatcher
      *> re-invokses BANK on the next AID with the COMMAREA flowed back
      *> through DFHCOMMAREA + EIBCALEN. (QAGE/QAGR is the refrence
      *> idiom -- same shape, two roles, one program here instead of
      *> two.)
      *>
      *>   COLD START          (EIBCALEN = 0)
      *>     no input to RECEIVE yet; jump straight to PAINT.
      *>
      *>   WARM (EIBCALEN > 0)
      *>     HANDLE the screen named in STATE.ST-SCREEN (RECEIVE +
      *>     process) -> set STATE.ST-SCREEN to whatever screen comes
      *>     next -> PAINT that next screen (SEND blocks until the
      *>     operator hits an AID) -> RETURN.
      *>
      *>   STATE.ST-SCREEN     'S' search    -> BANK1
      *>                       'D' detail    -> BANK2 with scroll
      *>                       'A' address   -> BANK3
      *>                       'O' open      -> BANK4
      *>                       'K' close     -> BANK5
      *>                       'X' exit  (drop COMMAREA, leave the
      *>                                 transaction)
      *>
      *> The search-context fields ST-LAST/FIRST/ADDR carryes across
      *> tasks so the operator can pick a SEL row on a later ENTER:
      *> the hit list itself is regnerated by re-running the same
      *> SELECT before each PAINT.

       IDENTIFICATION DIVISION.
       PROGRAM-ID. BANK.

       DATA DIVISION.
       WORKING-STORAGE SECTION.
       COPY DFHAID.
       COPY DFHRESP.
       COPY SQLCA.

      *> ---- pseudo-conversational state (rides in COMMAREA) ----------
      *> ST-MAGIC is a 4-byte signature that lets BANK detect a
      *> COMMAREA left behind by some other transaction. Bricks
      *> doesn't auto-clear sess.Commarea between TRANSIDs, so a
      *> prior BANK run that exitd via PF3 leaves bytes that the
      *> NEXT non-BANK task (e.g. SQLD) doesn't touch, which would
      *> then make THIS BANK invocation see EIBCALEN > 0 and try
      *> to RECEIVE MAP('BANK1') agaist the wrong LastMapName.
      *> If ST-MAGIC doesn't match 'BANK', we treat the invocation
      *> as a cold start.
       01 STATE.
          05 ST-MAGIC  PIC X(4)  VALUE 'BANK'.
          05 ST-SCREEN PIC X(1)  VALUE 'S'.
          05 ST-ACCT   PIC X(23) VALUE SPACES.
          05 ST-OFF    PIC X(6)  VALUE '000000'.
          05 ST-MSG    PIC X(60) VALUE SPACES.
          05 ST-LAST   PIC X(40) VALUE SPACES.
          05 ST-FIRST  PIC X(40) VALUE SPACES.
          05 ST-ADDR   PIC X(40) VALUE SPACES.
          05 ST-FILL   PIC X(46) VALUE SPACES.
       01 WARM-FLAG    PIC X(1)  VALUE 'N'.

      *> ---- numeric scratch ------------------------------------------
       01 N-OFF       PIC 9(6)    VALUE 0.
       01 N-NEXT      PIC 9(6)    VALUE 0.
       01 N-COUNT     PIC 9(4)    VALUE 0.
       01 N-HITS      PIC 9(2)    VALUE 0.
       01 N-PICK      PIC 9(2)    VALUE 0.

      *> ---- search-screen IO group (BANK1) ---------------------------
       01 SCR1.
          05 S1LAST    PIC X(40).
          05 S1FIRST   PIC X(40).
          05 S1ADDR    PIC X(40).
          05 S1ACCT    PIC X(23).
          05 S1SEL     PIC X(2).
          05 S1ROW1    PIC X(76).
          05 S1ROW2    PIC X(76).
          05 S1ROW3    PIC X(76).
          05 S1ROW4    PIC X(76).
          05 S1ROW5    PIC X(76).
          05 S1ROW6    PIC X(76).
          05 S1ROW7    PIC X(76).
          05 S1ROW8    PIC X(76).
          05 S1MSG     PIC X(76).

      *> ---- detail-screen IO group (BANK2) ---------------------------
       01 SCR2.
          05 S2ACCT    PIC X(23).
          05 S2STATUS  PIC X(10).
          05 S2OPENED  PIC X(10).
          05 S2NAME    PIC X(66).
          05 S2STREET  PIC X(60).
          05 S2CITYLN  PIC X(56).
          05 S2PHONE   PIC X(15).
          05 S2EMAIL   PIC X(38).
          05 S2BALANCE PIC X(18).
          05 S2ROW1    PIC X(78).
          05 S2ROW2    PIC X(78).
          05 S2ROW3    PIC X(78).
          05 S2ROW4    PIC X(78).
          05 S2ROW5    PIC X(78).
          05 S2ROW6    PIC X(78).
          05 S2ROW7    PIC X(78).
          05 S2ROW8    PIC X(78).
          05 S2ROW9    PIC X(78).
          05 S2ROW10   PIC X(78).
          05 S2ROW11   PIC X(78).
          05 S2ROW12   PIC X(78).
          05 S2ROW13   PIC X(78).
          05 S2MSG     PIC X(76).

      *> ---- address-change IO group (BANK3) --------------------------
       01 SCR3.
          05 S3ACCT    PIC X(23).
          05 S3NAME    PIC X(66).
          05 S3STREET  PIC X(60).
          05 S3CITY    PIC X(40).
          05 S3STATE   PIC X(2).
          05 S3ZIP     PIC X(10).
          05 S3MSG     PIC X(76).

      *> ---- open-account IO group (BANK4) ----------------------------
       01 SCR4.
          05 S4FIRST   PIC X(40).
          05 S4LAST    PIC X(40).
          05 S4MI      PIC X(1).
          05 S4STREET  PIC X(60).
          05 S4CITY    PIC X(40).
          05 S4STATE   PIC X(2).
          05 S4ZIP     PIC X(10).
          05 S4EMAIL   PIC X(60).
          05 S4PHONE   PIC X(15).
          05 S4DEPOSIT PIC X(12).
          05 S4NEWACCT PIC X(23).
          05 S4MSG     PIC X(76).

      *> ---- close-account IO group (BANK5) ---------------------------
       01 SCR5.
          05 S5ACCT    PIC X(23).
          05 S5NAME    PIC X(66).
          05 S5BALANCE PIC X(18).
          05 S5CONFIRM PIC X(8).
          05 S5MSG     PIC X(76).

      *> ---- DB result holders ----------------------------------------
       01 DB-ACCT      PIC X(23).
       01 DB-LAST      PIC X(40).
       01 DB-FIRST     PIC X(40).
       01 DB-MI        PIC X(1).
       01 DB-STREET    PIC X(60).
       01 DB-CITY      PIC X(40).
       01 DB-STATE     PIC X(2).
       01 DB-ZIP       PIC X(10).
       01 DB-EMAIL     PIC X(60).
       01 DB-PHONE     PIC X(15).
       01 DB-BAL-TXT   PIC X(20).
       01 DB-STATUS    PIC X(1).
       01 DB-OPENED    PIC X(10).

      *> Per-row host vars are sizd to the EXACT column widths the
      *> BANK2 layout expects. The SQL cursor right-pads/left-pads
      *> each field to its full width so STRING ... DELIMITED BY
      *> SIZE concatenates clean fiksed-width slots with no bleeding.
      *> Total per row: 16 + 2 + 4 + 2 + 14 + 1 + 14 + 3 + 21 = 77.
      *> 77 (not 78) because the row field is declared LEN 78 with
      *> a 1-byte 3270 attribute prefix at col 2, leaving 77 usable
      *> data columns; a 78-char row would wrap into the next line.
       01 TX-TS        PIC X(16).
       01 TX-TYPE      PIC X(4).
       01 TX-AMT-TXT   PIC X(14).
       01 TX-DESC      PIC X(21).
       01 TX-BAL-TXT   PIC X(14).

      *> ---- input scratch for SQL host vars --------------------------
      *> The three PAT-* default to '%' so the unused branches of the
      *> shared C1 cursor's WHERE clause still bind valid LIKE patterns
      *> -- SRCH-MODE gates which branch is meaningful.
       01 PAT-LAST     PIC X(50) VALUE '%'.
       01 PAT-FIRST    PIC X(50) VALUE '%'.
       01 PAT-ADDR     PIC X(60) VALUE '%'.
       01 DEP-TXT      PIC X(20) VALUE SPACES.

      *> ---- hit-list scratch -----------------------------------------
       01 HITS.
          05 HIT-ACCT  OCCURS 8 TIMES PIC X(23).
          05 HIT-LINE  OCCURS 8 TIMES PIC X(76).

      *> ---- formatting / misc ----------------------------------------
      *> bricks COBOL PIC supports only X / A / 9 / V9 / S -- no
      *> edited-output PICs (Z, comma, period). Numeric formatting is
      *> therefore done in Postgres via to_char(); COBOL just copies
      *> the pre-formatted text into the IO field.
       01 LINE-OUT     PIC X(78) VALUE SPACES.
       01 NEW-ACCT     PIC X(23) VALUE SPACES.
      *> Fixed-width name / city columns make the hit list readable.
       01 FMT-FIRST    PIC X(14) VALUE SPACES.
       01 FMT-LAST     PIC X(16) VALUE SPACES.
       01 FMT-CITY     PIC X(16) VALUE SPACES.

       PROCEDURE DIVISION.

      *> MAIN -- the two-phase pseudo-conversational dispatcher.
      *>   1. HANDLE: read the operator's input from the prior task's
      *>      SEND (skipped on cold start) and let the handler decide
      *>      which screen comes next.
      *>   2. PAINT:  SEND that next screen (blocks until the operator
      *>      hits an AID). The block-then-RETURN gives the dispatcher
      *>      time to chain another BANK task on the next ENTER.
       MAIN.
           MOVE 'N' TO WARM-FLAG.
           IF EIBCALEN > 0 THEN
               MOVE DFHCOMMAREA TO STATE
               IF ST-MAGIC = 'BANK' THEN
                   MOVE 'Y' TO WARM-FLAG
               END-IF
           END-IF.

      *> Cold-start (or stale COMMAREA from another transaction) ->
      *> reinitialise STATE so the rest of the program sees a clean,
      *> magic-tagged snapshot.
           IF WARM-FLAG = 'N' THEN
               MOVE 'BANK'   TO ST-MAGIC
               MOVE 'S'      TO ST-SCREEN
               MOVE SPACES   TO ST-ACCT
               MOVE '000000' TO ST-OFF
               MOVE SPACES   TO ST-MSG
               MOVE SPACES   TO ST-LAST
               MOVE SPACES   TO ST-FIRST
               MOVE SPACES   TO ST-ADDR
           END-IF.

           EXEC SQL WHENEVER SQLERROR CONTINUE END-EXEC.

      *> Phase 1: handle the prior screen's input. Only valid when
      *> WARM-FLAG = 'Y' -- otherwise the previous SEND was either
      *> never made or was made by some other transaction's map, and
      *> RECEIVE MAP('BANKx') would MAPFAIL.
           IF WARM-FLAG = 'Y' THEN
               EVALUATE ST-SCREEN
                   WHEN 'S' PERFORM HANDLE-SEARCH
                   WHEN 'D' PERFORM HANDLE-DETAIL
                   WHEN 'A' PERFORM HANDLE-ADDRESS
                   WHEN 'O' PERFORM HANDLE-OPEN
                   WHEN 'K' PERFORM HANDLE-CLOSE
                   WHEN OTHER MOVE 'S' TO ST-SCREEN
               END-EVALUATE
           END-IF.

      *> Phase 2: paint the next screen. 'X' = operator chose to exit.
           EVALUATE ST-SCREEN
               WHEN 'S' PERFORM PAINT-SEARCH
               WHEN 'D' PERFORM PAINT-DETAIL
               WHEN 'A' PERFORM PAINT-ADDRESS
               WHEN 'O' PERFORM PAINT-OPEN
               WHEN 'K' PERFORM PAINT-CLOSE
               WHEN 'X'
      *> Clear DFHCOMMAREA so the next un-related transaction
      *> (e.g. SQLD) doesn't inherit BANK's state bytes -- the
      *> bricks dispatcher rstrips DFHCOMMAREA into sess.Commarea
      *> on the way out, so spaces collapse to length 0.
                   MOVE SPACES TO DFHCOMMAREA
                   EXEC CICS RETURN END-EXEC
                   STOP RUN
               WHEN OTHER PERFORM PAINT-SEARCH
           END-EVALUATE.

           MOVE STATE TO DFHCOMMAREA.
           EXEC CICS RETURN TRANSID('BANK')
                            COMMAREA(STATE) END-EXEC.
           STOP RUN.

      *> ===============================================================
      *> Search screen (BANK1)
      *> ===============================================================

       HANDLE-SEARCH.
           EXEC CICS RECEIVE MAP('BANK1') INTO(SCR1) END-EXEC.

           IF EIBAID = PF03 THEN
               MOVE 'X' TO ST-SCREEN
           END-IF.

           IF ST-SCREEN = 'S' THEN
               PERFORM PROCESS-SEARCH-INPUT
           END-IF.

       PROCESS-SEARCH-INPUT.
           MOVE SPACES TO ST-MSG.

      *> Account number always wins -- and short-circuits everything.
      *> The lpad in the WHERE clause lets the operator type a short
      *> number too (e.g. "61") and still match the zero-padded row.
           IF S1ACCT NOT = SPACES THEN
               PERFORM DO-LOOKUP-ACCT
               MOVE SPACES TO ST-LAST
               MOVE SPACES TO ST-FIRST
               MOVE SPACES TO ST-ADDR
           ELSE
               IF S1LAST NOT = SPACES THEN
                   MOVE S1LAST TO ST-LAST
                   MOVE SPACES TO ST-FIRST
                   MOVE SPACES TO ST-ADDR
               END-IF
               IF S1LAST = SPACES AND S1FIRST NOT = SPACES THEN
                   MOVE SPACES TO ST-LAST
                   MOVE S1FIRST TO ST-FIRST
                   MOVE SPACES TO ST-ADDR
               END-IF
               IF S1LAST = SPACES AND S1FIRST = SPACES
                  AND S1ADDR NOT = SPACES THEN
                   MOVE SPACES TO ST-LAST
                   MOVE SPACES TO ST-FIRST
                   MOVE S1ADDR TO ST-ADDR
               END-IF
      *> Re-run whichever search is active so RESOLVE-SEL has fresh
      *> HIT-ACCT to index into.
               PERFORM REBUILD-HITS
               IF N-HITS > 0 AND S1SEL NOT = SPACES THEN
                   PERFORM RESOLVE-SEL
               END-IF
      *> One "No matches." check per active criterion -- parens
      *> around a sub-OR aren't allowed by the bricks parser, so a
      *> trio of IFs replaces the single grouped form.
               IF N-HITS = 0 AND ST-LAST NOT = SPACES THEN
                   MOVE 'No matches.' TO ST-MSG
               END-IF
               IF N-HITS = 0 AND ST-FIRST NOT = SPACES THEN
                   MOVE 'No matches.' TO ST-MSG
               END-IF
               IF N-HITS = 0 AND ST-ADDR NOT = SPACES THEN
                   MOVE 'No matches.' TO ST-MSG
               END-IF
           END-IF.

       DO-LOOKUP-ACCT.
           EXEC SQL
               SELECT account_number INTO :DB-ACCT
                 FROM accounts
                WHERE account_number = lpad(:S1ACCT, 23, '0')
           END-EXEC.
           EVALUATE SQLCODE
               WHEN SQL-OK
                   MOVE DB-ACCT TO ST-ACCT
                   MOVE '000000' TO ST-OFF
                   MOVE 'D' TO ST-SCREEN
               WHEN SQL-NODATA
                   MOVE 'No account with that number.' TO ST-MSG
               WHEN SQL-NOCONFIG
                   MOVE 'SQL not configured -- check bricks.cnf.'
                       TO ST-MSG
               WHEN SQL-UNDEF-TBL
                   MOVE 'BANK schema missing -- run bank_schema.bash.'
                       TO ST-MSG
               WHEN SQL-CONNLOST
                   MOVE 'Lost the Postgres connection.' TO ST-MSG
               WHEN OTHER
                   MOVE 'SQL error -- see bricks log.' TO ST-MSG
           END-EVALUATE.

       REBUILD-HITS.
           MOVE 0 TO N-HITS.
           IF ST-LAST NOT = SPACES THEN
               PERFORM DO-SEARCH-LAST
           END-IF.
           IF ST-LAST = SPACES AND ST-FIRST NOT = SPACES THEN
               PERFORM DO-SEARCH-FIRST
           END-IF.
           IF ST-LAST = SPACES AND ST-FIRST = SPACES
              AND ST-ADDR NOT = SPACES THEN
               PERFORM DO-SEARCH-ADDR
           END-IF.

      *> Three distinct cursors -- one per search axis. Each owns its
      *> own host-variable so the bound :PAT-* only ever drives the
      *> ILIKE it was built for (no duplicate-binding ambiguity).

       DO-SEARCH-LAST.
           MOVE SPACES TO PAT-LAST.
           STRING FUNCTION TRIM(ST-LAST) DELIMITED BY SIZE
                  '%'                    DELIMITED BY SIZE
               INTO PAT-LAST
           END-STRING.
           EXEC SQL DECLARE C1L CURSOR FOR
               SELECT account_number, first_name, last_name, city
                 FROM accounts
                WHERE status = 'O' AND last_name ILIKE :PAT-LAST
                ORDER BY last_name, first_name
                LIMIT 8
           END-EXEC.
           EXEC SQL OPEN C1L END-EXEC.
           PERFORM FETCH-LAST UNTIL SQLCODE = 100 OR N-HITS >= 8.
           EXEC SQL CLOSE C1L END-EXEC.

       FETCH-LAST.
           EXEC SQL FETCH C1L INTO :DB-ACCT, :DB-FIRST,
                                   :DB-LAST, :DB-CITY END-EXEC.
           IF SQLCODE = 0 THEN PERFORM ADD-HIT-ROW END-IF.

       DO-SEARCH-FIRST.
           MOVE SPACES TO PAT-FIRST.
           STRING FUNCTION TRIM(ST-FIRST) DELIMITED BY SIZE
                  '%'                     DELIMITED BY SIZE
               INTO PAT-FIRST
           END-STRING.
           EXEC SQL DECLARE C1F CURSOR FOR
               SELECT account_number, first_name, last_name, city
                 FROM accounts
                WHERE status = 'O' AND first_name ILIKE :PAT-FIRST
                ORDER BY first_name, last_name
                LIMIT 8
           END-EXEC.
           EXEC SQL OPEN C1F END-EXEC.
           PERFORM FETCH-FIRST UNTIL SQLCODE = 100 OR N-HITS >= 8.
           EXEC SQL CLOSE C1F END-EXEC.

       FETCH-FIRST.
           EXEC SQL FETCH C1F INTO :DB-ACCT, :DB-FIRST,
                                   :DB-LAST, :DB-CITY END-EXEC.
           IF SQLCODE = 0 THEN PERFORM ADD-HIT-ROW END-IF.

       DO-SEARCH-ADDR.
           MOVE SPACES TO PAT-ADDR.
           STRING '%'                    DELIMITED BY SIZE
                  FUNCTION TRIM(ST-ADDR) DELIMITED BY SIZE
                  '%'                    DELIMITED BY SIZE
               INTO PAT-ADDR
           END-STRING.
           EXEC SQL DECLARE C1A CURSOR FOR
               SELECT account_number, first_name, last_name, city
                 FROM accounts
                WHERE status = 'O'
                  AND (street ILIKE :PAT-ADDR OR city ILIKE :PAT-ADDR)
                ORDER BY city, last_name
                LIMIT 8
           END-EXEC.
           EXEC SQL OPEN C1A END-EXEC.
           PERFORM FETCH-ADDR UNTIL SQLCODE = 100 OR N-HITS >= 8.
           EXEC SQL CLOSE C1A END-EXEC.

       FETCH-ADDR.
           EXEC SQL FETCH C1A INTO :DB-ACCT, :DB-FIRST,
                                   :DB-LAST, :DB-CITY END-EXEC.
           IF SQLCODE = 0 THEN PERFORM ADD-HIT-ROW END-IF.

       ADD-HIT-ROW.
           ADD 1 TO N-HITS.
           MOVE DB-ACCT TO HIT-ACCT(N-HITS).
           MOVE DB-FIRST TO FMT-FIRST.
           MOVE DB-LAST  TO FMT-LAST.
           MOVE DB-CITY  TO FMT-CITY.
           MOVE SPACES TO LINE-OUT.
           STRING N-HITS    DELIMITED BY SIZE
                  ' '       DELIMITED BY SIZE
                  DB-ACCT   DELIMITED BY SIZE
                  ' '       DELIMITED BY SIZE
                  FMT-FIRST DELIMITED BY SIZE
                  ' '       DELIMITED BY SIZE
                  FMT-LAST  DELIMITED BY SIZE
                  ' '       DELIMITED BY SIZE
                  FMT-CITY  DELIMITED BY SIZE
               INTO LINE-OUT
           END-STRING.
           MOVE LINE-OUT TO HIT-LINE(N-HITS).

       RESOLVE-SEL.
           MOVE FUNCTION NUMVAL(S1SEL) TO N-PICK.
           IF N-PICK >= 1 AND N-PICK <= N-HITS THEN
               MOVE HIT-ACCT(N-PICK) TO ST-ACCT
               MOVE '000000' TO ST-OFF
               MOVE SPACES TO ST-LAST
               MOVE SPACES TO ST-FIRST
               MOVE SPACES TO ST-ADDR
               MOVE SPACES TO ST-MSG
               MOVE 'D' TO ST-SCREEN
           ELSE
               MOVE 'Pick number is out of range.' TO ST-MSG
           END-IF.

       PAINT-SEARCH.
           MOVE SPACES TO SCR1.
           MOVE ST-LAST  TO S1LAST.
           MOVE ST-FIRST TO S1FIRST.
           MOVE ST-ADDR  TO S1ADDR.

      *> Repopulate the hit list from the persistent search context
      *> so the operator sees the same rows they were picking from.
           MOVE 0 TO N-HITS.
           IF ST-LAST NOT = SPACES OR ST-FIRST NOT = SPACES
              OR ST-ADDR NOT = SPACES THEN
               PERFORM REBUILD-HITS
           END-IF.
           PERFORM PAINT-HITLIST.

           IF ST-MSG = SPACES AND N-HITS > 0 THEN
               STRING 'Found '              DELIMITED BY SIZE
                      N-HITS                DELIMITED BY SIZE
                      ' matches. Type row number then ENTER.'
                          DELIMITED BY SIZE
                   INTO ST-MSG
               END-STRING
           END-IF.
           MOVE ST-MSG TO S1MSG.

           EXEC CICS SEND MAP('BANK1') FROM(SCR1) ERASE END-EXEC.

       PAINT-HITLIST.
           MOVE SPACES TO S1ROW1 S1ROW2 S1ROW3 S1ROW4.
           MOVE SPACES TO S1ROW5 S1ROW6 S1ROW7 S1ROW8.
           IF N-HITS >= 1 MOVE HIT-LINE(1) TO S1ROW1 END-IF.
           IF N-HITS >= 2 MOVE HIT-LINE(2) TO S1ROW2 END-IF.
           IF N-HITS >= 3 MOVE HIT-LINE(3) TO S1ROW3 END-IF.
           IF N-HITS >= 4 MOVE HIT-LINE(4) TO S1ROW4 END-IF.
           IF N-HITS >= 5 MOVE HIT-LINE(5) TO S1ROW5 END-IF.
           IF N-HITS >= 6 MOVE HIT-LINE(6) TO S1ROW6 END-IF.
           IF N-HITS >= 7 MOVE HIT-LINE(7) TO S1ROW7 END-IF.
           IF N-HITS >= 8 MOVE HIT-LINE(8) TO S1ROW8 END-IF.

      *> ===============================================================
      *> Detail screen (BANK2)
      *> ===============================================================

       HANDLE-DETAIL.
           EXEC CICS RECEIVE MAP('BANK2') INTO(SCR2) END-EXEC.
           MOVE SPACES TO ST-MSG.
           IF EIBAID = PF03 THEN MOVE 'S' TO ST-SCREEN END-IF.
           IF EIBAID = PF04 THEN MOVE 'A' TO ST-SCREEN END-IF.
           IF EIBAID = PF05 THEN MOVE 'K' TO ST-SCREEN END-IF.
           IF EIBAID = PF06 THEN MOVE 'O' TO ST-SCREEN END-IF.
           IF EIBAID = PF07 THEN
               MOVE FUNCTION NUMVAL(ST-OFF) TO N-OFF
               IF N-OFF >= 13 THEN
                   SUBTRACT 13 FROM N-OFF
               ELSE
                   MOVE 0 TO N-OFF
               END-IF
               MOVE N-OFF TO N-NEXT
               MOVE N-NEXT TO ST-OFF
           END-IF.
           IF EIBAID = PF08 THEN
               MOVE FUNCTION NUMVAL(ST-OFF) TO N-OFF
               ADD 13 TO N-OFF
               MOVE N-OFF TO N-NEXT
               MOVE N-NEXT TO ST-OFF
           END-IF.

       PAINT-DETAIL.
           MOVE SPACES TO SCR2.
           PERFORM LOAD-ACCOUNT.
           IF ST-SCREEN = 'D' THEN
               PERFORM LOAD-TRANSACTIONS
               MOVE ST-MSG TO S2MSG
               EXEC CICS SEND MAP('BANK2') FROM(SCR2) ERASE END-EXEC
           ELSE
      *> LOAD-ACCOUNT bounced us back to search; let MAIN's PAINT
      *> phase pick up the new screen on the next dispatch.
               PERFORM PAINT-SEARCH
           END-IF.

       LOAD-ACCOUNT.
           EXEC SQL
               SELECT last_name, first_name, middle_init,
                      street, city, state, zip, email, phone,
                      to_char(balance, 'FM999,999,999,990.00'),
                      status,
                      to_char(opened_date, 'YYYY-MM-DD')
                 INTO :DB-LAST, :DB-FIRST, :DB-MI,
                      :DB-STREET, :DB-CITY, :DB-STATE, :DB-ZIP,
                      :DB-EMAIL, :DB-PHONE,
                      :DB-BAL-TXT, :DB-STATUS, :DB-OPENED
                 FROM accounts
                WHERE account_number = :ST-ACCT
           END-EXEC.
           EVALUATE SQLCODE
               WHEN SQL-OK
                   MOVE ST-ACCT TO S2ACCT
                   STRING FUNCTION TRIM(DB-FIRST) DELIMITED BY SIZE
                          ' '   DELIMITED BY SIZE
                          DB-MI DELIMITED BY SIZE
                          ' '   DELIMITED BY SIZE
                          FUNCTION TRIM(DB-LAST)  DELIMITED BY SIZE
                       INTO S2NAME
                   END-STRING
                   MOVE DB-STREET TO S2STREET
                   STRING FUNCTION TRIM(DB-CITY)  DELIMITED BY SIZE
                          ', '  DELIMITED BY SIZE
                          DB-STATE DELIMITED BY SIZE
                          '  '  DELIMITED BY SIZE
                          DB-ZIP DELIMITED BY SIZE
                       INTO S2CITYLN
                   END-STRING
                   MOVE DB-PHONE TO S2PHONE
                   MOVE DB-EMAIL TO S2EMAIL
                   MOVE DB-BAL-TXT TO S2BALANCE
                   IF DB-STATUS = 'O' THEN
                       MOVE 'OPEN'   TO S2STATUS
                   ELSE
                       MOVE 'CLOSED' TO S2STATUS
                   END-IF
                   MOVE DB-OPENED TO S2OPENED
               WHEN SQL-NODATA
                   MOVE 'Account not found -- back to search.'
                       TO ST-MSG
                   MOVE 'S' TO ST-SCREEN
               WHEN OTHER
                   MOVE 'SQL error loading account.' TO ST-MSG
                   MOVE 'S' TO ST-SCREEN
           END-EVALUATE.

       LOAD-TRANSACTIONS.
           MOVE FUNCTION NUMVAL(ST-OFF) TO N-OFF.
           MOVE 0 TO N-COUNT.
           MOVE SPACES TO S2ROW1 S2ROW2 S2ROW3 S2ROW4 S2ROW5.
           MOVE SPACES TO S2ROW6 S2ROW7 S2ROW8 S2ROW9 S2ROW10.
           MOVE SPACES TO S2ROW11 S2ROW12 S2ROW13.

      *> Pre-pad numeric columns in SQL to exact fixed widths so the
      *> COBOL STRING with DELIMITED BY SIZE gives clean alignment.
      *>   tx_ts        16 chars (YYYY-MM-DD HH24:MI)
      *>   tx_type       4 chars (stored width)
      *>   amount       14 chars, right-justified
      *>   description  21 chars, left-justified (truncated)
      *>   balance      14 chars, right-justified
      *>
      *> The inner subquery picks the LATEST 13 transactions for
      *> this OFFSET page (newest-first in the DB), then the OUTER
      *> ORDER BY flips THIS PAGE to oldest-first so reading
      *> top-to-bottom on screen follows time order: a CRE row
      *> visibly shows a HIGHER balance than the row above it, a
      *> DEB row a lower one. PF7/PF8 still page through older /
      *> newer slices the same way (PF8 = older = OFFSET +=).
           EXEC SQL DECLARE C2T CURSOR FOR
               SELECT ts, tx_type, amt_txt, desc_txt, bal_txt
                 FROM (SELECT to_char(tx_ts,
                                'YYYY-MM-DD HH24:MI') AS ts,
                              tx_type,
                              lpad(to_char(abs(amount),
                                'FM999,999,990.00'), 14) AS amt_txt,
                              rpad(substr(description, 1, 21),
                                21) AS desc_txt,
                              lpad(to_char(balance_after,
                                'FM999,999,990.00'), 14) AS bal_txt,
                              tx_ts, tx_id
                         FROM transactions
                        WHERE account_number = :ST-ACCT
                        ORDER BY tx_ts DESC, tx_id DESC
                        OFFSET :N-OFF
                        LIMIT 13) sub
                ORDER BY sub.tx_ts ASC, sub.tx_id ASC
           END-EXEC.

           EXEC SQL OPEN C2T END-EXEC.
           PERFORM FETCH-TX UNTIL SQLCODE = 100 OR N-COUNT >= 13.
           EXEC SQL CLOSE C2T END-EXEC.

           IF N-COUNT = 0 AND N-OFF > 0 THEN
               MOVE 'No more transactions in that direction.'
                   TO ST-MSG
           END-IF.

       FETCH-TX.
      *> Fetch order MUST match the cursor's column order:
      *>   ts, type, amount, description, balance.
           EXEC SQL FETCH C2T INTO :TX-TS, :TX-TYPE, :TX-AMT-TXT,
                                   :TX-DESC, :TX-BAL-TXT END-EXEC.
           IF SQLCODE = 0 THEN
               ADD 1 TO N-COUNT
      *> Row layout: timestamp | TYPE | AMOUNT | NEW BALANCE |
      *> description.  AMOUNT is unsigned -- TYPE already says
      *> whether the balance went DOWN (DEB) or UP (CRE).  Every
      *> source field is exact-width (PIC matches SQL pad), so
      *> two-space separators produce a clean grid.
      *> Separator widths: 2 / 2 / 1 / 3 between cells. The 1-vs-3
      *> shift moves the NEW BALANCE value one column to the left
      *> so its right edge lines up with the header label, while
      *> keeping DESCRIPTION anchored at column 56.
               MOVE SPACES TO LINE-OUT
               STRING TX-TS        DELIMITED BY SIZE
                      '  '         DELIMITED BY SIZE
                      TX-TYPE      DELIMITED BY SIZE
                      '  '         DELIMITED BY SIZE
                      TX-AMT-TXT   DELIMITED BY SIZE
                      ' '          DELIMITED BY SIZE
                      TX-BAL-TXT   DELIMITED BY SIZE
                      '   '        DELIMITED BY SIZE
                      TX-DESC      DELIMITED BY SIZE
                   INTO LINE-OUT
               END-STRING
               EVALUATE N-COUNT
                   WHEN 1  MOVE LINE-OUT TO S2ROW1
                   WHEN 2  MOVE LINE-OUT TO S2ROW2
                   WHEN 3  MOVE LINE-OUT TO S2ROW3
                   WHEN 4  MOVE LINE-OUT TO S2ROW4
                   WHEN 5  MOVE LINE-OUT TO S2ROW5
                   WHEN 6  MOVE LINE-OUT TO S2ROW6
                   WHEN 7  MOVE LINE-OUT TO S2ROW7
                   WHEN 8  MOVE LINE-OUT TO S2ROW8
                   WHEN 9  MOVE LINE-OUT TO S2ROW9
                   WHEN 10 MOVE LINE-OUT TO S2ROW10
                   WHEN 11 MOVE LINE-OUT TO S2ROW11
                   WHEN 12 MOVE LINE-OUT TO S2ROW12
                   WHEN 13 MOVE LINE-OUT TO S2ROW13
               END-EVALUATE
           END-IF.

      *> ===============================================================
      *> Address change (BANK3)
      *> ===============================================================

       HANDLE-ADDRESS.
           EXEC CICS RECEIVE MAP('BANK3') INTO(SCR3) END-EXEC.
           MOVE SPACES TO ST-MSG.
           IF EIBAID = PF03 THEN
               MOVE 'D' TO ST-SCREEN
           ELSE
               EXEC SQL
                   UPDATE accounts
                      SET street = :S3STREET,
                          city   = :S3CITY,
                          state  = :S3STATE,
                          zip    = :S3ZIP
                    WHERE account_number = :ST-ACCT
               END-EXEC
               IF SQLCODE = 0 THEN
                   EXEC SQL COMMIT END-EXEC
                   MOVE 'Address updated.' TO ST-MSG
                   MOVE 'D' TO ST-SCREEN
               ELSE
                   MOVE 'Update failed -- see bricks log.' TO ST-MSG
               END-IF
           END-IF.

       PAINT-ADDRESS.
           MOVE SPACES TO SCR3.
           EXEC SQL
               SELECT last_name, first_name, middle_init,
                      street, city, state, zip
                 INTO :DB-LAST, :DB-FIRST, :DB-MI,
                      :DB-STREET, :DB-CITY, :DB-STATE, :DB-ZIP
                 FROM accounts
                WHERE account_number = :ST-ACCT
           END-EXEC.
           IF SQLCODE NOT = 0 THEN
               MOVE 'Account vanished.' TO ST-MSG
               MOVE 'S' TO ST-SCREEN
               PERFORM PAINT-SEARCH
           ELSE
               MOVE ST-ACCT TO S3ACCT
               STRING FUNCTION TRIM(DB-FIRST) DELIMITED BY SIZE
                      ' ' DELIMITED BY SIZE
                      DB-MI DELIMITED BY SIZE
                      ' ' DELIMITED BY SIZE
                      FUNCTION TRIM(DB-LAST) DELIMITED BY SIZE
                   INTO S3NAME
               END-STRING
               MOVE DB-STREET TO S3STREET
               MOVE DB-CITY   TO S3CITY
               MOVE DB-STATE  TO S3STATE
               MOVE DB-ZIP    TO S3ZIP
               MOVE ST-MSG    TO S3MSG
               EXEC CICS SEND MAP('BANK3') FROM(SCR3) ERASE END-EXEC
           END-IF.

      *> ===============================================================
      *> Open new account (BANK4)
      *> ===============================================================

       HANDLE-OPEN.
           EXEC CICS RECEIVE MAP('BANK4') INTO(SCR4) END-EXEC.
           MOVE SPACES TO ST-MSG.
           IF EIBAID = PF03 THEN
               MOVE 'S' TO ST-SCREEN
           ELSE
               PERFORM DO-CREATE-ACCOUNT
           END-IF.

       DO-CREATE-ACCOUNT.
           IF S4FIRST = SPACES OR S4LAST = SPACES
              OR S4STREET = SPACES OR S4CITY = SPACES
              OR S4STATE = SPACES OR S4ZIP = SPACES THEN
               MOVE 'First, Last, Street, City, State, ZIP required.'
                   TO ST-MSG
           ELSE
               PERFORM DO-MINT-ACCOUNT
           END-IF.

       DO-MINT-ACCOUNT.
           EXEC SQL
               SELECT to_char(10000000000000000000000
                            + nextval('bank_acct_seq'),
                              'FM00000000000000000000000')
                 INTO :NEW-ACCT
           END-EXEC.
           IF SQLCODE NOT = 0 THEN
               MOVE 'Could not allocate account number.' TO ST-MSG
           ELSE
               PERFORM DO-INSERT-ACCOUNT
           END-IF.

       DO-INSERT-ACCOUNT.
           MOVE S4DEPOSIT TO DEP-TXT.
           IF FUNCTION TRIM(DEP-TXT) = SPACES THEN
               MOVE '0' TO DEP-TXT
           END-IF.

           EXEC SQL
               INSERT INTO accounts (account_number, last_name,
                                     first_name, middle_init,
                                     street, city, state, zip,
                                     email, phone, balance, status)
               VALUES (:NEW-ACCT, :S4LAST, :S4FIRST, :S4MI,
                       :S4STREET, :S4CITY, :S4STATE, :S4ZIP,
                       :S4EMAIL, :S4PHONE,
                       CAST(:DEP-TXT AS numeric), 'O')
           END-EXEC.
           IF SQLCODE NOT = 0 THEN
               EXEC SQL ROLLBACK END-EXEC
               MOVE 'INSERT failed -- check fields.' TO ST-MSG
           ELSE
               PERFORM DO-OPENING-DEPOSIT
           END-IF.

       DO-OPENING-DEPOSIT.
           IF FUNCTION TRIM(DEP-TXT) NOT = '0' THEN
               EXEC SQL
                   INSERT INTO transactions
                       (account_number, tx_type, amount,
                        description, counterparty, balance_after)
                   VALUES (:NEW-ACCT, 'CR  ',
                           CAST(:DEP-TXT AS numeric),
                           'Opening deposit',
                           'Branch counter',
                           CAST(:DEP-TXT AS numeric))
               END-EXEC
               IF SQLCODE NOT = 0 THEN
                   EXEC SQL ROLLBACK END-EXEC
                   MOVE 'Deposit record failed.' TO ST-MSG
                   MOVE STATE TO DFHCOMMAREA
                   EXEC CICS RETURN TRANSID('BANK')
                                    COMMAREA(STATE) END-EXEC
               END-IF
           END-IF.
           EXEC SQL COMMIT END-EXEC.
           STRING 'Opened account ' DELIMITED BY SIZE
                  NEW-ACCT          DELIMITED BY SIZE
               INTO ST-MSG
           END-STRING.
           MOVE NEW-ACCT TO ST-ACCT.
           MOVE '000000' TO ST-OFF.
           MOVE 'D' TO ST-SCREEN.

       PAINT-OPEN.
           MOVE SPACES TO SCR4.
           MOVE ST-MSG TO S4MSG.
           EXEC CICS SEND MAP('BANK4') FROM(SCR4) ERASE END-EXEC.

      *> ===============================================================
      *> Close account (BANK5)
      *> ===============================================================

       HANDLE-CLOSE.
           EXEC CICS RECEIVE MAP('BANK5') INTO(SCR5) END-EXEC.
           MOVE SPACES TO ST-MSG.
           IF EIBAID = PF03 THEN
               MOVE 'D' TO ST-SCREEN
           ELSE
               PERFORM DO-CONFIRM-CLOSE
           END-IF.

       DO-CONFIRM-CLOSE.
           IF FUNCTION UPPER-CASE(S5CONFIRM) NOT = 'CLOSE   ' THEN
               MOVE 'Type CLOSE exactly to confirm.' TO ST-MSG
           ELSE
               PERFORM DO-EXECUTE-CLOSE
           END-IF.

       DO-EXECUTE-CLOSE.
           EXEC SQL
               INSERT INTO transactions
                   (account_number, tx_type, amount, description,
                    counterparty, balance_after)
               SELECT account_number, 'CR  ', -balance,
                      'Account closed -- balance zeroed',
                      'Branch counter', 0
                 FROM accounts
                WHERE account_number = :ST-ACCT
           END-EXEC.
           IF SQLCODE NOT = 0 THEN
               EXEC SQL ROLLBACK END-EXEC
               MOVE 'Closing transaction failed.' TO ST-MSG
           ELSE
               PERFORM DO-MARK-CLOSED
           END-IF.

       DO-MARK-CLOSED.
           EXEC SQL
               UPDATE accounts
                  SET balance = 0,
                      status  = 'C',
                      closed_date = CURRENT_DATE
                WHERE account_number = :ST-ACCT
           END-EXEC.
           IF SQLCODE NOT = 0 THEN
               EXEC SQL ROLLBACK END-EXEC
               MOVE 'Close failed -- rolled back.' TO ST-MSG
           ELSE
               EXEC SQL COMMIT END-EXEC
               MOVE 'Account closed.' TO ST-MSG
               MOVE 'S' TO ST-SCREEN
           END-IF.

       PAINT-CLOSE.
           MOVE SPACES TO SCR5.
           EXEC SQL
               SELECT last_name, first_name, middle_init,
                      to_char(balance, 'FM999,999,999,990.00')
                 INTO :DB-LAST, :DB-FIRST, :DB-MI, :DB-BAL-TXT
                 FROM accounts
                WHERE account_number = :ST-ACCT
           END-EXEC.
           IF SQLCODE NOT = 0 THEN
               MOVE 'Account vanished.' TO ST-MSG
               MOVE 'S' TO ST-SCREEN
               PERFORM PAINT-SEARCH
           ELSE
               MOVE ST-ACCT TO S5ACCT
               STRING FUNCTION TRIM(DB-FIRST) DELIMITED BY SIZE
                      ' ' DELIMITED BY SIZE
                      DB-MI DELIMITED BY SIZE
                      ' ' DELIMITED BY SIZE
                      FUNCTION TRIM(DB-LAST) DELIMITED BY SIZE
                   INTO S5NAME
               END-STRING
               MOVE DB-BAL-TXT TO S5BALANCE
               MOVE ST-MSG TO S5MSG
               EXEC CICS SEND MAP('BANK5') FROM(SCR5) ERASE END-EXEC
           END-IF.
