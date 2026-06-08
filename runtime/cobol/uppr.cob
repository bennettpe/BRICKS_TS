      *> UPPR -- COBOL sample: fold a customer's text to upper case with
      *> the INSPECT ... CONVERTING verb, then show it on a simple map.
      *>
      *> The operator types free-form customer text (any case) into the
      *> CUSTIN field of the UPPR1 map and presses ENTER. INSPECT
      *> CONVERTING maps every lower-case letter to its upper-case
      *> partner through a 26-character translation table -- the
      *> canonical COBOL idiom for case folding. (REPLACING only swaps
      *> whole literal runs, so it cannot fold letter-by-letter.)
      *> Characters outside the from-set -- digits, spaces, punctuation
      *> -- pass through unchanged. The upper-cased copy is sent back in
      *> CUSTOUT. PF3 at the prompt exits.
       IDENTIFICATION DIVISION.
       PROGRAM-ID. UPPR.

       DATA DIVISION.
       WORKING-STORAGE SECTION.
       COPY DFHAID.

      *> SCR is the UPPR1 map IO group. CUSTIN is the unprotected field
      *> the operator types into; CUSTOUT echoes the upper-cased copy;
      *> MSG is the status line.
       01 SCR.
          05 CUSTIN  PIC X(40).
          05 CUSTOUT PIC X(40).
          05 MSG     PIC X(70).

       PROCEDURE DIVISION.
       MAIN.
           MOVE SPACES TO CUSTIN.
           MOVE SPACES TO CUSTOUT.
           MOVE 'Type customer text (any case), then press ENTER.'
               TO MSG.

      *> Paint the empty form and wait for the operator's input.
           EXEC CICS SEND MAP('UPPR1') FROM(SCR) ERASE END-EXEC.
           EXEC CICS RECEIVE MAP('UPPR1') INTO(SCR) END-EXEC.

      *> PF3 at the prompt leaves the transaction.
           IF EIBAID = PF03 THEN
               EXEC CICS RETURN END-EXEC
           END-IF.

      *> Copy the input, then fold a..z to A..Z in place. The from and
      *> to sets are equal length so every letter maps one-for-one.
           MOVE CUSTIN TO CUSTOUT.
           INSPECT CUSTOUT
               CONVERTING 'abcdefghijklmnopqrstuvwxyz'
                       TO 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'.

           MOVE 'Folded to upper case with INSPECT CONVERTING.'
               TO MSG.

      *> Show the result and end the task; the operator is returned to
      *> the prompt. Type UPPR again to convert another string.
           EXEC CICS SEND MAP('UPPR1') FROM(SCR) END-EXEC.
           EXEC CICS RETURN END-EXEC.
           STOP RUN.
