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
          
       PROCEDURE DIVISION.
       MAIN.
           EXEC CICS ASSIGN USERID(USR) TERMID(TRM) END-EXEC.
           EXEC CICS SEND MAP('CUST1') FROM(SCR) ERASE END-EXEC.
           EXEC CICS RECEIVE MAP('CUST1') INTO(SCR) END-EXEC.           
           EXEC CICS RETURN END-EXEC.
           STOP RUN.           
        
