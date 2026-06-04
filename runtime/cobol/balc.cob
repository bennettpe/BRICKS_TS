      *> BALC -- runtime per-field colour override demo.
      *> Branches on a hard-coded balance, paints STATUS in GREEN when
      *> in funds and RED when overdrawn, waits for ENTER, then flips
      *> STATUS to RED on the second SEND. Demonstrates the
      *> IBM-canonical NAME-C convention: the map field STATUS reads
      *> its colour from STATUS-C at SEND MAP time, overriding the
      *> map's COLOR= default.

       IDENTIFICATION DIVISION.
       PROGRAM-ID. BALC.

       DATA DIVISION.
       WORKING-STORAGE SECTION.
       COPY DFHAID.
       COPY DFHCOLOR.

       01 BALANCE   PIC S9(7)V99 COMP-3 VALUE +1500.00.

       01 SCR.
          05 BALOUT   PIC X(12).
          05 STATUS   PIC X(10).
          05 STATUS-C PIC X(9) VALUE SPACES.

       PROCEDURE DIVISION.

       MAIN.
           MOVE 'BAL  1500.00' TO BALOUT.
           IF BALANCE > 1000 THEN
               MOVE 'IN-FUNDS' TO STATUS
               MOVE DFHGREEN   TO STATUS-C
           ELSE
               MOVE 'OVERDRAWN' TO STATUS
               MOVE DFHRED     TO STATUS-C
           END-IF.
           EXEC CICS SEND MAP('BALC') FROM(SCR) ERASE END-EXEC.
           EXEC CICS RECEIVE MAP('BALC') INTO(SCR) END-EXEC.
           IF EIBAID = PF03 THEN
               EXEC CICS RETURN END-EXEC
           END-IF.
           MOVE DFHRED TO STATUS-C.
           EXEC CICS SEND MAP('BALC') FROM(SCR) END-EXEC.
           EXEC CICS RETURN END-EXEC.
