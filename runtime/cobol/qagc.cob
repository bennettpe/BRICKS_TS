      *> QAGC -- query age, self-contained COBOL twin of qage+qagr.rexx.
      *> Conversational (single-task) flow: SEND the input map, RECEIVE
      *> the typed values, validate, compute age in years and approximate
      *> days alive, SEND the result map, RETURN.
      *>
      *> Validation failures loop back to redisplay QAGE1 with an error
      *> in MSG until the operator types good values or presses PF3 to
      *> cancel. The REXX twin (qagr.rexx) splits this across QAGE+QAGR
      *> for the pseudo-conversational pattern; the COBOL port keeps it
      *> in one program because the user can invoke QAGC directly without
      *> a prior SEND from a sibling transaction.
      *>
      *> bricks COBOL conveniences used here:
      *>   - COPY DFHAID delivers PF03 (and the DFHPF3 alias) so the
      *>     PF3-cancel branch reads `IF EIBAID = PF03` instead of a
      *>     raw hex literal.
      *>   - EXEC CICS ASSIGN TODAYYR / TODAYMO / TODAYDY return today's
      *>     year / month / day separately so this program needs no
      *>     reference modification or STRING verb.
      *>   - The age-in-days figure is an approximation
      *>     (years * 365 + MMDD delta); exact Gregorian-day arithmetic
      *>     is Phase 7.
       IDENTIFICATION DIVISION.
       PROGRAM-ID. QAGC.

       DATA DIVISION.
       WORKING-STORAGE SECTION.
       COPY DFHAID.
       01 TRM      PIC X(8).

      *> SCR is the shared map IO group. QAGE1 has TERMID/YEAR/MONTH/DAY/MSG;
      *> QAGR1 has TERMID/BIRTH/AGE/DAYS. Field names are unique across the
      *> two maps so a single group services both directions.
       01 SCR.
          05 TERMID PIC X(8).
          05 YEAR   PIC X(4).
          05 MONTH  PIC X(2).
          05 DAY    PIC X(2).
          05 MSG    PIC X(70).
          05 BIRTH  PIC X(12).
          05 AGE    PIC X(16).
          05 DAYS   PIC X(12).

       01 BY        PIC 9(4).
       01 BM        PIC 9(2).
       01 BD        PIC 9(2).

       01 TY        PIC 9(4).
       01 TM        PIC 9(2).
       01 TD        PIC 9(2).

       01 NDAYS     PIC S9(8).
       01 YRS       PIC S9(4).

       01 TODAY-MMDD PIC 9(4).
       01 BIRTH-MMDD PIC 9(4).

       01 ERR       PIC X(70).

       01 INPUT-OK PIC X(1) VALUE 'N'.
       01 EXIT-FLAG PIC X(1) VALUE 'N'.

       PROCEDURE DIVISION.
       MAIN.
           EXEC CICS ASSIGN TERMID(TRM) END-EXEC.
           MOVE TRM TO TERMID.
           MOVE SPACES TO MSG.

      *> Input loop: prompt, validate, repeat until the date parses
      *> cleanly or the operator presses PF3 to cancel.
           PERFORM PROMPT-AND-VALIDATE
               UNTIL INPUT-OK = 'Y' OR EXIT-FLAG = 'Y'.

           IF EXIT-FLAG = 'Y' THEN
               EXEC CICS RETURN END-EXEC
           END-IF.

      *> Today's date components — pulled out of the bricks-specific
      *> ASSIGN options so we don't need reference modification.
           EXEC CICS ASSIGN TODAYYR(TY) TODAYMO(TM) TODAYDY(TD) END-EXEC.

           COMPUTE YRS = TY - BY.
           COMPUTE TODAY-MMDD = TM * 100 + TD.
           COMPUTE BIRTH-MMDD = BM * 100 + BD.
           IF TODAY-MMDD < BIRTH-MMDD THEN
               COMPUTE YRS = YRS - 1
           END-IF.

           COMPUTE NDAYS = (TY - BY) * 365 + (TODAY-MMDD - BIRTH-MMDD).

      *> Format the result map. BIRTH stays as YYYYMMDD (no STRING verb
      *> to insert dashes); AGE is the year count, DAYS the approximate
      *> day count.
           MOVE SPACES TO BIRTH.
           MOVE YEAR TO BIRTH.
           MOVE YRS  TO AGE.
           MOVE NDAYS TO DAYS.

           EXEC CICS SEND MAP('QAGR1') FROM(SCR) ERASE END-EXEC.
           EXEC CICS RECEIVE MAP('QAGR1') INTO(SCR) END-EXEC.
           EXEC CICS RETURN END-EXEC.
           STOP RUN.

       PROMPT-AND-VALIDATE.
           EXEC CICS SEND MAP('QAGE1') FROM(SCR) ERASE END-EXEC.
           EXEC CICS RECEIVE MAP('QAGE1') INTO(SCR) END-EXEC.

           IF EIBAID = PF03 THEN
               MOVE 'Y' TO EXIT-FLAG
           END-IF.
           IF EXIT-FLAG = 'Y' THEN
               EXIT
           END-IF.

           MOVE SPACES TO ERR.

           IF YEAR = SPACES THEN
               MOVE 'Year, month, and day are all required.' TO ERR
           END-IF.
           IF MONTH = SPACES THEN
               MOVE 'Year, month, and day are all required.' TO ERR
           END-IF.
           IF DAY = SPACES THEN
               MOVE 'Year, month, and day are all required.' TO ERR
           END-IF.

           IF ERR = SPACES THEN
               MOVE YEAR  TO BY
               MOVE MONTH TO BM
               MOVE DAY   TO BD
               IF BY < 1880 THEN
                   MOVE 'Year out of range (1880 - 2200).' TO ERR
               END-IF
               IF BY > 2200 THEN
                   MOVE 'Year out of range (1880 - 2200).' TO ERR
               END-IF
               IF BM < 1 THEN
                   MOVE 'Month must be 1 - 12.' TO ERR
               END-IF
               IF BM > 12 THEN
                   MOVE 'Month must be 1 - 12.' TO ERR
               END-IF
               IF BD < 1 THEN
                   MOVE 'Day must be 1 - 31.' TO ERR
               END-IF
               IF BD > 31 THEN
                   MOVE 'Day must be 1 - 31.' TO ERR
               END-IF
           END-IF.

           IF ERR = SPACES THEN
               MOVE 'Y' TO INPUT-OK
               MOVE SPACES TO MSG
           END-IF.
           IF ERR NOT = SPACES THEN
               MOVE ERR TO MSG
           END-IF.
