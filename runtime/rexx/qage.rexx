/* QAGE -- query age, prompt half. Pseudo-conversational: paint the    */

ADDRESS CICS

EXEC CICS ASSIGN TERMID(TRM) END-EXEC

SCR. = ''
SCR.TERMID = TRM
SCR.MSG    = 'Type your birth date and press ENTER. PF3 cancels.'
EXEC CICS SEND MAP('QAGE1') FROM(SCR.) ERASE END-EXEC

/* PF3 = no chain, drop back to the bare TRANSID prompt. Hex 'F3' is  */
/* the AID byte the dispatcher records into EIBAID after SEND MAP.    */
IF C2X(EIBAID) = 'F3' THEN DO
  EXEC CICS RETURN END-EXEC
END

EXEC CICS RETURN TRANSID('QAGR') END-EXEC
EXIT
