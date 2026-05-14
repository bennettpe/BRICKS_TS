      *> TIMC -- timed-reminder demo, COBOL twin of TIMR (REXX).
      *> Exercises three new EXEC CICS verbs in one program:
      *>
      *>   START    -- queue this same transaction to fire again
      *>               after a delay, with the operator's message
      *>               carried in FROM(MSG).
      *>   RETRIEVE -- on scheduled re-entry, pull the message back
      *>               from the bricks scheduler. RESP = RESP-NORMAL
      *>               on the scheduled run, RESP-ENDDATA on cold
      *>               entry (operator typed TIMC at the prompt).
      *>   CONVERSE -- single-verb SEND+RECEIVE used on the input
      *>               form, replacing the SEND MAP / RECEIVE MAP
      *>               pair every other COBOL sample writes by hand.
      *>
      *> Maps TIM1 (input form) and TIM2 (reminder display) are
      *> shared with the REXX twin TIMR; both programs render
      *> against the same field names.
      *>
      *> COPY DFHAID provides PF03 for the PF3-cancel branch and
      *> ENTER for the dismiss test; COPY DFHRESP provides
      *> RESP-NORMAL / RESP-ENDDATA for the RETRIEVE result test.
       IDENTIFICATION DIVISION.
       PROGRAM-ID. TIMC.

       DATA DIVISION.
       WORKING-STORAGE SECTION.
       COPY DFHAID.
       COPY DFHRESP.

       01 TRM      PIC X(8).
       01 BUF      PIC X(50).
       01 BUFLEN   PIC 9(4).

      *> SCR is the shared map IO group. TIM1 uses TERMID/SECS/MSG/INFO;
      *> TIM2 uses TERMID/MSG/FIRED. Field names are unique across the
      *> two maps so one group services both directions.
       01 SCR.
          05 TERMID PIC X(8).
          05 SECS   PIC X(4).
          05 MSG    PIC X(50).
          05 INFO   PIC X(70).
          05 FIRED  PIC X(30).

       01 SECS-N    PIC 9(5).
       01 HH        PIC 9(2).
       01 MM        PIC 9(2).
       01 SS        PIC 9(2).
       01 HHMMSS    PIC X(6).

       PROCEDURE DIVISION.
       MAIN.
           EXEC CICS ASSIGN TERMID(TRM) END-EXEC.
           MOVE SPACES TO BUF.
           MOVE ZERO   TO BUFLEN.

      *> First thing: see if this is a scheduled re-entry. RETRIEVE
      *> drains any payload the originating START left for us; on
      *> a cold dispatch (operator typed TIMC) RESP-ENDDATA fires.
           EXEC CICS RETRIEVE INTO(BUF) LENGTH(BUFLEN) END-EXEC.

           IF EIBRESP = RESP-NORMAL THEN
               PERFORM SHOW-REMINDER
               EXEC CICS RETURN END-EXEC
               STOP RUN
           END-IF.

      *> Cold entry: prompt the operator. CONVERSE = SEND MAP +
      *> RECEIVE MAP rolled into one verb. The map TIM1 lives in
      *> runtime/map/tim1.map, shared with TIMR.
           MOVE SPACES TO SCR.
           MOVE TRM TO TERMID.
           MOVE 'Schedule a reminder against this terminal.' TO INFO.
           EXEC CICS CONVERSE MAP('TIM1') FROM(SCR) INTO(SCR)
                              ERASE END-EXEC.

      *> PF3 cancels the schedule without issuing the START.
           IF EIBAID = PF03 THEN
               EXEC CICS RETURN END-EXEC
               STOP RUN
           END-IF.

      *> Validate seconds. Empty / non-numeric falls back to 30;
      *> clamp to <24h so a fat-fingered 9999999 doesn't overflow
      *> the HHMMSS slot.
           IF SECS = SPACES THEN
               MOVE 30 TO SECS-N
           ELSE
               MOVE SECS TO SECS-N
           END-IF.
           IF SECS-N > 86399 THEN
               MOVE 86399 TO SECS-N
           END-IF.

      *> Decompose SECS-N into HHMMSS for EXEC CICS START INTERVAL.
           COMPUTE HH = SECS-N / 3600.
           COMPUTE MM = (SECS-N - HH * 3600) / 60.
           COMPUTE SS = SECS-N - HH * 3600 - MM * 60.
           MOVE SPACES TO HHMMSS.
           STRING HH DELIMITED BY SIZE
                  MM DELIMITED BY SIZE
                  SS DELIMITED BY SIZE
               INTO HHMMSS
           END-STRING.

      *> Queue TIMC to fire again, carrying the operator's message.
      *> The bricks scheduler holds the payload until INTERVAL
      *> elapses, then the prompt-loop drain in main.go dispatches
      *> TIMC again with EIBRESP=RESP-NORMAL on RETRIEVE.
           IF MSG = SPACES THEN
               MOVE '(blank reminder)' TO MSG
           END-IF.
           EXEC CICS START TRANSID('TIMC') INTERVAL(HHMMSS)
                           FROM(MSG) END-EXEC.

           EXEC CICS RETURN END-EXEC.
           STOP RUN.

       SHOW-REMINDER.
      *> Scheduled-fire branch: paint TIM2 with the saved message
      *> and wait for ENTER to dismiss. CONVERSE again for symmetry.
           MOVE SPACES TO SCR.
           MOVE TRM TO TERMID.
           MOVE BUF TO MSG.
           MOVE '(scheduled fire -- ENTER to dismiss)' TO FIRED.
           EXEC CICS CONVERSE MAP('TIM2') FROM(SCR) INTO(SCR)
                              ERASE END-EXEC.
