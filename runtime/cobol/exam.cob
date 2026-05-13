      *> EXAM -- COBOL example showing how to read the command-line
      *> arguments the operator typed after the transid.
      *>
      *> When the user types "EXAM 1 2 3" at the blank prompt, the
      *> dispatcher stashes the unedited line on the TCB and the
      *> following EXEC CICS RECEIVE INTO(buf) LENGTH(len) returns the
      *> whole buffer including the transid prefix. The program then
      *> strips the transid with UNSTRING (whose first piece is the
      *> transid itself) and surfaces A / B / C on the EXAM1 map.
      *>
      *> This is the IBM-canonical surface: real CICS programs read the
      *> first-dispatch terminal input the same way. A second RECEIVE
      *> in this same task, or any RECEIVE in a chained RETURN TRANSID
      *> task, returns EOC (RESP=6).
       IDENTIFICATION DIVISION.
       PROGRAM-ID. EXAM.

       DATA DIVISION.
       WORKING-STORAGE SECTION.
       01 WS-INPUT  PIC X(60).
       01 WS-LEN    PIC 9(4).

      *> UNSTRING peels the buffer into TRANSID + three positional
      *> args. TRANSID catches "EXAM" so it doesn't bleed into A.
       01 TRANSID   PIC X(8).

      *> SCR is the EXAM1 map IO group. RAW echoes the buffer the
      *> program received; BUFLEN echoes the actual length so the
      *> operator can sanity-check what RECEIVE INTO returned.
       01 SCR.
          05 RAW    PIC X(60).
          05 BUFLEN PIC X(5).
          05 A      PIC X(16).
          05 B      PIC X(16).
          05 C      PIC X(16).

       PROCEDURE DIVISION.
       MAIN.
           MOVE SPACES TO WS-INPUT.
           MOVE SPACES TO TRANSID.
           MOVE SPACES TO A.
           MOVE SPACES TO B.
           MOVE SPACES TO C.

      *> RECEIVE the unedited buffer the operator typed at the blank
      *> prompt. EIBRESP=6 (EOC) means there's nothing to read --
      *> happens when EXAM is invoked through a chained RETURN TRANSID
      *> rather than typed fresh.
           EXEC CICS RECEIVE INTO(WS-INPUT) LENGTH(WS-LEN) END-EXEC.

           MOVE WS-INPUT TO RAW.
           MOVE WS-LEN   TO BUFLEN.

      *> Split on a single space. First piece = transid, then the
      *> three positional args. Extra trailing tokens are silently
      *> dropped; missing ones leave their target as SPACES.
           UNSTRING WS-INPUT DELIMITED BY ' '
               INTO TRANSID A B C
           END-UNSTRING.

           EXEC CICS SEND MAP('EXAM1') FROM(SCR) ERASE END-EXEC.
           EXEC CICS RETURN END-EXEC.
           STOP RUN.
