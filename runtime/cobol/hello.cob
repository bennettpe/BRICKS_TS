      *> HELC -- COBOL twin of the REXX HELO transaction. Greets the
      *> signed-on user using the helo1 map. Demonstrates the bricks
      *> COBOL subset: WORKING-STORAGE group items routed to map fields,
      *> EXEC CICS ASSIGN populating WORKING-STORAGE, MOVE, STRING-style
      *> concatenation via successive MOVE into a group item, and the
      *> mandatory EXEC CICS RETURN to give the task back to bricks.
       IDENTIFICATION DIVISION.
       PROGRAM-ID. HELC.

       DATA DIVISION.
       WORKING-STORAGE SECTION.
       01 USR     PIC X(8).
       01 TRM     PIC X(4).

       01 SCR.
          05 INFOLINE PIC X(78).
          05 GREETING PIC X(20).
          05 FOOTER   PIC X(60).

       PROCEDURE DIVISION.
       MAIN.
           EXEC CICS ASSIGN USERID(USR) TERMID(TRM) END-EXEC.

           MOVE SPACES TO INFOLINE.
           MOVE SPACES TO GREETING.
           MOVE SPACES TO FOOTER.

           MOVE 'HELLO from COBOL!'    TO GREETING.
           MOVE 'COBOL transaction running under bricks' TO INFOLINE.
           MOVE 'ENTER=Continue'       TO FOOTER.

           EXEC CICS SEND MAP('HELO1') FROM(SCR) ERASE END-EXEC.

           EXEC CICS RETURN END-EXEC.
           STOP RUN.
