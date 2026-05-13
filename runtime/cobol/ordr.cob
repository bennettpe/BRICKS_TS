      *> ORDR -- import orders from a sandboxed sequential file into the
      *> ORDERS VSAM database, keyed on customer id.
      *>
      *> Conversational flow:
      *>   Screen 1 (ORDR1) -- confirmation prompt. Operator presses
      *>                       ENTER to run, PF3 to cancel.
      *>   On ENTER         -- loop READQ TD QUEUE('orders.sample.txt')
      *>                       until EIBRESP = RESP-QZERO; for each
      *>                       line UNSTRING on '|' into customer /
      *>                       product / qty / price, then WRITE
      *>                       FILE('ORDERS') RIDFLD(CUST-ID).
      *>                       RESP-DUPREC increments DUPCNT and
      *>                       continues.
      *>   Screen 2 (ORDR2) -- summary: records read / records written /
      *>                       duplicates skipped. ENTER ends the task.
      *>
      *> Encoding contract (enforced by the bricks tmp_dir backend, not
      *> this program): the sample file is ASCII, LF-terminated, no CRs.
      *> READQ TD strips the trailing LF on the way in; UNSTRING fills
      *> CUST-ID / PRODUCT / QTY / PRICE space-padded on the right.
       IDENTIFICATION DIVISION.
       PROGRAM-ID. ORDR.

       DATA DIVISION.
       WORKING-STORAGE SECTION.
       COPY DFHAID.
       COPY DFHRESP.
       01 USR PIC X(8).
       01 TRM PIC X(4).

       01 SCR.
          05 INFOLINE PIC X(78).
          05 MSG      PIC X(76).

       01 SUM-SCR.
          05 SINFO    PIC X(78).
          05 RDCNT    PIC X(6).
          05 WRCNT    PIC X(6).
          05 DUPCNT   PIC X(6).
          05 SMSG     PIC X(76).

       01 REC      PIC X(120).
       01 CUST-ID  PIC X(8).
       01 PRODUCT  PIC X(20).
       01 QTY      PIC X(8).
       01 PRICE    PIC X(12).
       01 OREC     PIC X(80).

       01 N-READ   PIC 9(6) VALUE 0.
       01 N-WRITE  PIC 9(6) VALUE 0.
       01 N-DUP    PIC 9(6) VALUE 0.

       01 DONE-FLAG  PIC X(1) VALUE 'N'.

       PROCEDURE DIVISION.
       MAIN.
           EXEC CICS ASSIGN USERID(USR) TERMID(TRM) END-EXEC.

           MOVE SPACES TO SCR.
           STRING 'User: ' DELIMITED BY SIZE
                  USR DELIMITED BY SIZE
                  '                            Term: ' DELIMITED BY SIZE
                  TRM DELIMITED BY SIZE
               INTO INFOLINE
           END-STRING.
           MOVE SPACES TO MSG.

      *> Confirmation screen.
           EXEC CICS SEND MAP('ORDR1') FROM(SCR) ERASE END-EXEC.
           EXEC CICS RECEIVE MAP('ORDR1') INTO(SCR) END-EXEC.

      *> PF3 cancels the import without touching the file.
           IF EIBAID = PF03 THEN
               EXEC CICS RETURN END-EXEC
               STOP RUN
           END-IF.

      *> Import loop. READQ TD auto-opens the file on first call; bricks
      *> closes the handle at task end so we don't need an explicit
      *> DELETEQ / close here.
           PERFORM IMPORT-ONE UNTIL DONE-FLAG = 'Y'.

      *> Build summary screen.
           MOVE SPACES TO SUM-SCR.
           STRING 'User: ' DELIMITED BY SIZE
                  USR DELIMITED BY SIZE
                  '                            Term: ' DELIMITED BY SIZE
                  TRM DELIMITED BY SIZE
               INTO SINFO
           END-STRING.
           MOVE N-READ  TO RDCNT.
           MOVE N-WRITE TO WRCNT.
           MOVE N-DUP   TO DUPCNT.
           IF N-WRITE = 0 THEN
               MOVE 'No records imported.' TO SMSG
           ELSE
               MOVE 'Import complete -- press ENTER to exit.' TO SMSG
           END-IF.

           EXEC CICS SEND MAP('ORDR2') FROM(SUM-SCR) ERASE END-EXEC.
           EXEC CICS RECEIVE MAP('ORDR2') INTO(SUM-SCR) END-EXEC.

           EXEC CICS RETURN END-EXEC.
           STOP RUN.

       IMPORT-ONE.
      *> Reset REC so a short last line doesn't drag stale bytes into
      *> the UNSTRING below.
           MOVE SPACES TO REC.
           EXEC CICS READQ TD QUEUE('orders.sample.txt') INTO(REC) END-EXEC.
           IF EIBRESP = RESP-QZERO THEN
               MOVE 'Y' TO DONE-FLAG
           END-IF.
           IF EIBRESP = RESP-NORMAL THEN
               COMPUTE N-READ = N-READ + 1
               MOVE SPACES TO CUST-ID
               MOVE SPACES TO PRODUCT
               MOVE SPACES TO QTY
               MOVE SPACES TO PRICE
               UNSTRING REC DELIMITED BY '|'
                   INTO CUST-ID PRODUCT QTY PRICE
               END-UNSTRING
               PERFORM WRITE-ORDER
           END-IF.
           IF EIBRESP NOT = RESP-NORMAL
              AND EIBRESP NOT = RESP-QZERO THEN
      *> IOERR or similar surfaces here. Stop the loop rather than spin.
               MOVE 'Y' TO DONE-FLAG
           END-IF.

       WRITE-ORDER.
      *> Rebuild a clean 'PRODUCT|QTY|PRICE' record so the on-disk row
      *> has the three trailing columns rtrimmed and pipe-separated --
      *> matches the GUST customer-file layout convention.
           MOVE SPACES TO OREC.
           STRING PRODUCT DELIMITED BY SIZE
                  '|' DELIMITED BY SIZE
                  QTY DELIMITED BY SIZE
                  '|' DELIMITED BY SIZE
                  PRICE DELIMITED BY SIZE
               INTO OREC
           END-STRING.
           EXEC CICS WRITE FILE('ORDERS') FROM(OREC) RIDFLD(CUST-ID) END-EXEC.
           IF EIBRESP = RESP-NORMAL THEN
               COMPUTE N-WRITE = N-WRITE + 1
           END-IF.
           IF EIBRESP = RESP-DUPREC THEN
               COMPUTE N-DUP = N-DUP + 1
           END-IF.
