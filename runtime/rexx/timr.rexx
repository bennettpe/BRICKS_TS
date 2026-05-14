/* TIMR -- timed-reminder demo, REXX twin of TIMC (COBOL).            */
/* Exercises EXEC CICS START / RETRIEVE.                              */
/*                                                                    */
/* Two code paths in one program:                                     */
/*   1. Cold-start (no pending payload): RETRIEVE returns RESP=29     */
/*      (ENDDATA). Render the TIM1 input map, read the operator's    */
/*      delay + message, then START('TIMR') INTERVAL(hhmmss)          */
/*      FROM(message). The transaction ends; the terminal returns to  */
/*      the blank prompt; the bricks scheduler fires TIMR again after */
/*      the delay.                                                    */
/*   2. Scheduled re-entry (payload present): RETRIEVE returns        */
/*      RESP=0 with the message in BUF. Render TIM2 with the message  */
/*      as a reminder; ENTER dismisses.                               */
/*                                                                    */
/* PF3 from the input form cancels (no START issued).                 */

ADDRESS CICS

EXEC CICS ASSIGN TERMID(TRM) END-EXEC

BUF = ''
EXEC CICS RETRIEVE INTO(BUF) END-EXEC
IF EIBRESP = 0 THEN DO
  /* Scheduled-entry path: a prior TIMR queued this run with the     */
  /* message in FROM(...). Display it and exit on ENTER.             */
  SCR. = ''
  SCR.TERMID = TRM
  SCR.MSG    = BUF
  SCR.FIRED  = '(scheduled fire -- ENTER to dismiss)'
  EXEC CICS SEND MAP('TIM2') FROM(SCR.) ERASE END-EXEC
  EXEC CICS RECEIVE MAP('TIM2') INTO(SCR.) END-EXEC
  EXEC CICS RETURN END-EXEC
END

/* Cold-start path: prompt the operator for delay + message.         */
SCR. = ''
SCR.TERMID = TRM
SCR.INFO   = 'Schedule a reminder against this terminal.'
EXEC CICS SEND MAP('TIM1') FROM(SCR.) ERASE END-EXEC
EXEC CICS RECEIVE MAP('TIM1') INTO(SCR.) END-EXEC

/* PF3 cancels the schedule.                                          */
IF C2X(EIBAID) = 'F3' THEN DO
  EXEC CICS RETURN END-EXEC
END

/* Validate seconds. Default to 30 if blank or non-numeric.          */
SECS = STRIP(SCR.SECS)
IF SECS = '' THEN SECS = 30
IF \DATATYPE(SECS, 'W') THEN SECS = 30
IF SECS < 0 THEN SECS = 0
IF SECS > 86399 THEN SECS = 86399    /* clamp to <24h */

/* Format seconds as HHMMSS for INTERVAL(...).                        */
HH = SECS % 3600
MM = (SECS // 3600) % 60
SS = SECS // 60
HHMMSS = RIGHT(HH, 2, '0') || RIGHT(MM, 2, '0') || RIGHT(SS, 2, '0')

MSG = STRIP(SCR.MSG)
IF MSG = '' THEN MSG = '(blank reminder)'

EXEC CICS START TRANSID('TIMR') INTERVAL(HHMMSS) FROM(MSG) END-EXEC

EXEC CICS RETURN END-EXEC
EXIT
