/* PROD -- producer demo: writes a payload onto a TS queue and       */
/* shows how many items the queue now holds.                         */
/*                                                                   */
/* Conversational. The map asks the operator for QNAME and PAYLOAD;  */
/* on ENTER we WRITEQ TS QUEUE(QNAME) FROM(PAYLOAD), then re-paint   */
/* the same map with a status line. PF3 returns to the bare prompt.  */
/*                                                                   */
/* Bricksload's prod flow drives this transaction in a tight loop to */
/* stress the TS queue path; the same code works interactively.      */

ADDRESS CICS

EXEC CICS ASSIGN TERMID(TRM) END-EXEC

DO FOREVER
  SCR. = ''
  SCR.TERMID = TRM
  IF \DATATYPE(NWRT,'W') THEN NWRT = 0

  SCR.MSG = 'Type queue + payload, ENTER to write. PF3 exits.'
  IF NWRT > 0 THEN DO
    SCR.MSG = 'Wrote item' ITEMNO 'on' QNM '. Total written this session:' NWRT
  END

  EXEC CICS SEND MAP('PROD1') FROM(SCR.) ERASE END-EXEC
  EXEC CICS RECEIVE MAP('PROD1') END-EXEC

  IF C2X(EIBAID) = 'F3' THEN DO
    EXEC CICS RETURN END-EXEC
  END

  QNM = STRIP(MAP.QNAME)
  PAY = STRIP(MAP.PAYLOAD)

  IF QNM = '' THEN DO
    SCR.MSG = 'Queue name required.'
    ITERATE
  END
  IF PAY = '' THEN PAY = 'payload-' || TIME('S')

  EXEC CICS WRITEQ TS QUEUE(QNM) FROM(PAY) ITEM(ITEMNO) END-EXEC
  IF EIBRESP \= 0 THEN DO
    SCR.MSG = 'WRITEQ failed RESP=' || EIBRESP
    ITERATE
  END

  NWRT = NWRT + 1
END

EXIT
