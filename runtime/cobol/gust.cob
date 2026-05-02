       *> copyright 2026 by moshix
       IDENTIFICATION DIVISION.
       PROGRAM-ID. GUST.

       DATA DIVISION.
       WORKING-STORAGE SECTION.
       01 USR PIC X(8).
       01 TRM PIC X(4).

       01 SCR.
          05 INFOLINE PIC X(78).
          05 ACTION   PIC X(1).
          05 CUSTNO   PIC X(8).
          05 SEARCH   PIC X(30).
          05 MSG      PIC X(60).

       01 DET.
          05 DINFOLINE PIC X(78).
          05 DCUSTNO   PIC X(8).
          05 DNAME     PIC X(32).
          05 DADDRESS  PIC X(32).
          05 DCITY     PIC X(20).
          05 DPHONE    PIC X(16).
          05 DMODE     PIC X(60).
          05 DMSG      PIC X(60).

       01 KEY-IN PIC X(8).
       01 SRCH   PIC X(30).
       01 REC    PIC X(120).

      *> Local copies (REXX uses NM/AD/CY/PH; the unique-name rule
      *> means the COBOL versions get a Q prefix.)
       01 QNAME    PIC X(32).
       01 QADDR    PIC X(32).
       01 QCITY    PIC X(20).
       01 QPHONE   PIC X(16).

       01 EXIT-FLAG    PIC X(1) VALUE 'N'.
       01 VALID-ACTION PIC X(1) VALUE 'N'.
       01 CMSG         PIC X(30).
       01 RESP-STR     PIC X(8).

       PROCEDURE DIVISION.
       MAIN.
           EXEC CICS ASSIGN USERID(USR) TERMID(TRM) END-EXEC.

      *> Initialise the menu group ONCE outside the loop. SCR.MSG is set
      *> by each action and carries through to the next iteration's SEND
      *> so the operator sees the prior result. Resetting at loop top
      *> would erase the message before it could be painted.
           MOVE SPACES TO SCR.
      *> Match the REXX cust.rexx INFOLINE layout: "User: USR" then a
      *> 28-space gutter then "Term: TRM" so the second column lines up
      *> in the same screen position the REXX twin produces.
           STRING 'User: ' DELIMITED BY SIZE
                  USR DELIMITED BY SIZE
                  '                            Term: ' DELIMITED BY SIZE
                  TRM DELIMITED BY SIZE
               INTO INFOLINE
           END-STRING.

           PERFORM MENU-LOOP UNTIL EXIT-FLAG = 'Y'.

           EXEC CICS RETURN END-EXEC.
           STOP RUN.

       MENU-LOOP.
           EXEC CICS SEND MAP('CUST1') FROM(SCR) ERASE END-EXEC.
           EXEC CICS RECEIVE MAP('CUST1') INTO(SCR) END-EXEC.

      *> PF12 from the menu screen exits the transaction immediately --
      *> matching cust.rexx's `IF C2X(EIBAID) = '7C'`.
           IF EIBAID = X'7C' THEN
               MOVE 'Y' TO EXIT-FLAG
           END-IF.

           IF EXIT-FLAG NOT = 'Y' THEN
               MOVE FUNCTION UPPER-CASE(ACTION) TO ACTION
               MOVE FUNCTION UPPER-CASE(CUSTNO) TO KEY-IN
               MOVE SEARCH TO SRCH
               PERFORM DISPATCH
           END-IF.

       DISPATCH.
      *> CRITICAL: clear MSG at dispatch entry. SCR.MSG persists across
      *> iterations on purpose (it carries the prior result through to
      *> the next SEND CUST1 so the operator sees what just happened),
      *> which means using "IF MSG = SPACES" as a dispatch guard would
      *> skip every action after the first. REXX cust.rexx avoids this
      *> by structuring validation as IF/ELSE IF/ELSE so exactly one
      *> path runs per iteration; we mirror that by clearing MSG here
      *> and using the VALID-ACTION flag to skip dispatch only on the
      *> validation-error paths within this iteration.
           MOVE SPACES TO MSG.
           MOVE 'Y' TO VALID-ACTION.

      *> REXX-style validation: empty action, unknown action, missing
      *> customer# for non-L/S actions. Set MSG and clear VALID-ACTION
      *> so the LINK GUSV + EVALUATE further down skips on this turn.
           IF ACTION = SPACES THEN
               MOVE 'Action required (A/Q/U/D/L/S, F12=exit).' TO MSG
               MOVE 'N' TO VALID-ACTION
           END-IF.
           IF VALID-ACTION = 'Y' THEN
               IF ACTION NOT = 'A' AND ACTION NOT = 'Q'
                  AND ACTION NOT = 'U' AND ACTION NOT = 'D'
                  AND ACTION NOT = 'L' AND ACTION NOT = 'S' THEN
                   STRING 'Unknown action: ' DELIMITED BY SIZE
                          ACTION DELIMITED BY SIZE
                       INTO MSG
                   END-STRING
                   MOVE 'N' TO VALID-ACTION
               END-IF
           END-IF.
           IF VALID-ACTION = 'Y' THEN
               IF ACTION NOT = 'L' AND ACTION NOT = 'S' THEN
                   IF KEY-IN = SPACES THEN
                       MOVE 'Customer # required.' TO MSG
                       MOVE 'N' TO VALID-ACTION
                   END-IF
               END-IF
           END-IF.

           IF VALID-ACTION = 'Y' THEN
      *> Validate / normalise the customer number via LINK to GUSV
      *> (skipped for L and S which do not need a key).
               IF ACTION NOT = 'L' AND ACTION NOT = 'S' THEN
                   EXEC CICS LINK PROGRAM('GUSV') COMMAREA(KEY-IN) END-EXEC
               END-IF
               EVALUATE ACTION
                   WHEN 'A'
                       PERFORM ACT-ADD
                   WHEN 'Q'
                       PERFORM ACT-QUERY
                   WHEN 'U'
                       PERFORM ACT-UPDATE
                   WHEN 'D'
                       PERFORM ACT-DELETE
                   WHEN 'L'
                       PERFORM ACT-LIST
                   WHEN 'S'
                       PERFORM ACT-SEARCH
                   WHEN OTHER
                       MOVE 'Internal error: action fell through.' TO MSG
               END-EVALUATE
           END-IF.

       ACT-ADD.
           MOVE SPACES TO DET.
           MOVE KEY-IN TO DCUSTNO.
           MOVE 'Mode: ADD -- fill in fields and press ENTER.' TO DMODE.
           EXEC CICS SEND MAP('CUST2') FROM(DET) ERASE END-EXEC.
           EXEC CICS RECEIVE MAP('CUST2') INTO(DET) END-EXEC.

           STRING DNAME DELIMITED BY SIZE
                  '|' DELIMITED BY SIZE
                  DADDRESS DELIMITED BY SIZE
                  '|' DELIMITED BY SIZE
                  DCITY DELIMITED BY SIZE
                  '|' DELIMITED BY SIZE
                  DPHONE DELIMITED BY SIZE
               INTO REC
           END-STRING.

           EXEC CICS WRITE FILE('customers') FROM(REC) RIDFLD(KEY-IN) END-EXEC.

           IF EIBRESP = 14 THEN
               STRING 'Customer ' DELIMITED BY SIZE
                      KEY-IN DELIMITED BY SIZE
                      ' already exists.' DELIMITED BY SIZE
                   INTO MSG
               END-STRING
           END-IF.
           IF EIBRESP = 0 THEN
               STRING 'Customer ' DELIMITED BY SIZE
                      KEY-IN DELIMITED BY SIZE
                      ' added.' DELIMITED BY SIZE
                   INTO MSG
               END-STRING
           END-IF.
           IF EIBRESP NOT = 0 AND EIBRESP NOT = 14 THEN
               MOVE EIBRESP TO RESP-STR
               STRING 'WRITE failed RESP=' DELIMITED BY SIZE
                      RESP-STR DELIMITED BY SIZE
                   INTO MSG
               END-STRING
           END-IF.

       ACT-QUERY.
           EXEC CICS READ FILE('customers') INTO(REC) RIDFLD(KEY-IN) END-EXEC.
           IF EIBRESP = 13 THEN
               STRING 'Customer ' DELIMITED BY SIZE
                      KEY-IN DELIMITED BY SIZE
                      ' not found.' DELIMITED BY SIZE
                   INTO MSG
               END-STRING
           END-IF.
           IF EIBRESP NOT = 0 AND EIBRESP NOT = 13 THEN
               MOVE EIBRESP TO RESP-STR
               STRING 'READ failed RESP=' DELIMITED BY SIZE
                      RESP-STR DELIMITED BY SIZE
                   INTO MSG
               END-STRING
           END-IF.
           IF EIBRESP = 0 THEN
               PERFORM SHOW-DETAIL-FROM-REC
               MOVE 'Mode: QUERY -- press ENTER to return to the menu.' TO DMODE
               EXEC CICS SEND MAP('CUST2') FROM(DET) ERASE END-EXEC
               EXEC CICS RECEIVE MAP('CUST2') INTO(DET) END-EXEC
               STRING 'Query of ' DELIMITED BY SIZE
                      KEY-IN DELIMITED BY SIZE
                      ' complete.' DELIMITED BY SIZE
                   INTO MSG
               END-STRING
           END-IF.

       ACT-UPDATE.
           EXEC CICS READ FILE('customers') INTO(REC) RIDFLD(KEY-IN)
                         UPDATE END-EXEC.
           IF EIBRESP = 13 THEN
               STRING 'Customer ' DELIMITED BY SIZE
                      KEY-IN DELIMITED BY SIZE
                      ' not found.' DELIMITED BY SIZE
                   INTO MSG
               END-STRING
           END-IF.
           IF EIBRESP NOT = 0 AND EIBRESP NOT = 13 THEN
               MOVE EIBRESP TO RESP-STR
               STRING 'READ UPDATE failed RESP=' DELIMITED BY SIZE
                      RESP-STR DELIMITED BY SIZE
                   INTO MSG
               END-STRING
           END-IF.
           IF EIBRESP = 0 THEN
               PERFORM SHOW-DETAIL-FROM-REC
               MOVE 'Mode: UPDATE -- modify and press ENTER.' TO DMODE
               EXEC CICS SEND MAP('CUST2') FROM(DET) ERASE END-EXEC
               EXEC CICS RECEIVE MAP('CUST2') INTO(DET) END-EXEC

               STRING DNAME DELIMITED BY SIZE
                      '|' DELIMITED BY SIZE
                      DADDRESS DELIMITED BY SIZE
                      '|' DELIMITED BY SIZE
                      DCITY DELIMITED BY SIZE
                      '|' DELIMITED BY SIZE
                      DPHONE DELIMITED BY SIZE
                   INTO REC
               END-STRING

               EXEC CICS REWRITE FILE('customers') FROM(REC) END-EXEC
               IF EIBRESP NOT = 0 THEN
                   MOVE EIBRESP TO RESP-STR
                   STRING 'REWRITE failed RESP=' DELIMITED BY SIZE
                          RESP-STR DELIMITED BY SIZE
                       INTO MSG
                   END-STRING
               END-IF
               IF EIBRESP = 0 THEN
                   STRING 'Customer ' DELIMITED BY SIZE
                          KEY-IN DELIMITED BY SIZE
                          ' updated.' DELIMITED BY SIZE
                       INTO MSG
                   END-STRING
               END-IF
           END-IF.

       ACT-DELETE.
           EXEC CICS DELETE FILE('customers') RIDFLD(KEY-IN) END-EXEC.
           IF EIBRESP = 13 THEN
               STRING 'Customer ' DELIMITED BY SIZE
                      KEY-IN DELIMITED BY SIZE
                      ' not found.' DELIMITED BY SIZE
                   INTO MSG
               END-STRING
           END-IF.
           IF EIBRESP = 0 THEN
               STRING 'Customer ' DELIMITED BY SIZE
                      KEY-IN DELIMITED BY SIZE
                      ' deleted.' DELIMITED BY SIZE
                   INTO MSG
               END-STRING
           END-IF.
           IF EIBRESP NOT = 0 AND EIBRESP NOT = 13 THEN
               MOVE EIBRESP TO RESP-STR
               STRING 'DELETE failed RESP=' DELIMITED BY SIZE
                      RESP-STR DELIMITED BY SIZE
                   INTO MSG
               END-STRING
           END-IF.

       ACT-LIST.
      *> Empty filter: GUSL writes the row count back into DFHCOMMAREA.
      *> An empty list yields '0' in CMSG; otherwise CMSG is a count
      *> like '15' or '250'.
           MOVE SPACES TO CMSG.
           EXEC CICS LINK PROGRAM('GUSL') COMMAREA(CMSG) END-EXEC.
           IF CMSG = '0' THEN
               MOVE 'No customers in file.' TO MSG
           END-IF.
           IF CMSG NOT = '0' THEN
               STRING 'List complete (' DELIMITED BY SIZE
                      CMSG DELIMITED BY SIZE
                      ' records).' DELIMITED BY SIZE
                   INTO MSG
               END-STRING
           END-IF.

       ACT-SEARCH.
      *> SRCH passes the operator's filter via DFHCOMMAREA on the way
      *> in; GUSL writes the match count back into the same field on
      *> RETURN. Empty SRCH degrades to ACT-LIST behaviour (matches
      *> REXX). Substring filtering on the GUSL side needs INSPECT /
      *> POS which the COBOL subset does not have yet, so a non-empty
      *> SRCH is honoured by REXX's CUSL but ignored by COBOL's GUSL --
      *> the operator sees the full list and a message that says so.
           IF SRCH = SPACES THEN
               MOVE SPACES TO CMSG
               EXEC CICS LINK PROGRAM('GUSL') COMMAREA(CMSG) END-EXEC
               IF CMSG = '0' THEN
                   MOVE 'No customers in file.' TO MSG
               END-IF
               IF CMSG NOT = '0' THEN
                   STRING 'List complete (' DELIMITED BY SIZE
                          CMSG DELIMITED BY SIZE
                          ' records).' DELIMITED BY SIZE
                       INTO MSG
                   END-STRING
               END-IF
           END-IF.
           IF SRCH NOT = SPACES THEN
               STRING 'Search filter (' DELIMITED BY SIZE
                      SRCH DELIMITED BY SIZE
                      ') is REXX-only -- use CUST.' DELIMITED BY SIZE
                   INTO MSG
               END-STRING
           END-IF.

       SHOW-DETAIL-FROM-REC.
      *> Split REC on '|' into the four detail fields, then write into
      *> the DET group children expected by SEND MAP('CUST2') FROM(DET).
           MOVE SPACES TO QNAME.
           MOVE SPACES TO QADDR.
           MOVE SPACES TO QCITY.
           MOVE SPACES TO QPHONE.
           UNSTRING REC DELIMITED BY '|'
               INTO QNAME QADDR QCITY QPHONE
           END-UNSTRING.
           MOVE SPACES TO DET.
           MOVE KEY-IN TO DCUSTNO.
           MOVE QNAME  TO DNAME.
           MOVE QADDR  TO DADDRESS.
           MOVE QCITY  TO DCITY.
           MOVE QPHONE TO DPHONE.
