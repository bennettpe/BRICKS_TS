/* CONS -- consumer demo: reads one item per ENTER from a TS queue   */
/* using the implicit cursor. Each cursor-less READQ TS returns the  */
/* next item; when the queue is exhausted the screen shows ITEMERR   */
/* and the operator can either DELETE the queue (PF4), restart from  */
/* item 1 (PF5), or PF3 to leave.                                    */
/*                                                                   */
/* The cursor lives on the running task — closing the transaction    */
/* (PF3 / RETURN) releases it via Store.ClearTaskState in the        */
/* dispatcher, so the next CONS invocation starts fresh at item 1.   */
/*                                                                   */
/* Variable naming: REXX compound-symbol tail substitution turns     */
/* SCR.LASTITEM into SCR.<value-of-LASTITEM> if a local variable     */
/* named LASTITEM exists — silently writing to the wrong tail and    */
/* leaving the map field empty. Same trap cust.rexx and qagr.rexx    */
/* warn about. So local names are deliberately distinct from the     */
/* CONS1 map fields (LASTITEM/LASTPAY/NREAD/QNAME/MSG):              */
/*   LITM   <-> LASTITEM   field                                     */
/*   LPAY   <-> LASTPAY    field                                     */
/*   NRD    <-> NREAD      field                                     */
/*   QNM    <-> QNAME      field (no clash since names differ)       */
/* Don't introduce locals whose uppercase names collide with map     */
/* field names without renaming.                                     */

ADDRESS CICS

EXEC CICS ASSIGN TERMID(TRM) END-EXEC

DO FOREVER
  IF \DATATYPE(NRD,'W') THEN NRD = 0
  IF QNM = 'QNM' THEN QNM = ''         /* unset → NOVALUE returns 'QNM' */
  IF LITM = 'LITM' THEN LITM = ''
  IF LPAY = 'LPAY' THEN LPAY = ''

  SCR. = ''
  SCR.TERMID   = TRM
  SCR.QNAME    = QNM
  SCR.LASTITEM = LITM
  SCR.LASTPAY  = LPAY
  SCR.NREAD    = NRD
  IF QNM = '' THEN
    SCR.MSG = 'Type a queue name and press ENTER. PF3 exits.'
  ELSE
    SCR.MSG = 'ENTER reads next.  PF4 deletes queue.  PF5 rewind.  PF3 exit.'

  EXEC CICS SEND MAP('CONS1') FROM(SCR.) ERASE END-EXEC
  EXEC CICS RECEIVE MAP('CONS1') END-EXEC

  AID = C2X(EIBAID)
  IF AID = 'F3' THEN DO
    EXEC CICS RETURN END-EXEC
  END

  /* Pick up any edited queue name. */
  TYPED = STRIP(MAP.QNAME)
  IF TYPED \= '' THEN QNM = TYPED

  IF QNM = '' THEN ITERATE

  IF AID = 'F4' THEN DO
    EXEC CICS DELETEQ TS QUEUE(QNM) END-EXEC
    IF EIBRESP = 0 THEN DO
      LITM = ''
      LPAY = ''
      NRD  = 0
    END
    ITERATE
  END

  IF AID = 'F5' THEN DO
    /* Rewind: chain back to ourselves so the dispatcher's task-end  */
    /* hook clears our cursor; the next dispatch starts at item 1.  */
    EXEC CICS RETURN TRANSID('CONS') END-EXEC
  END

  /* Default ENTER: consume the next item via the implicit cursor.    */
  /*                                                                  */
  /* DROP GOTI first so its value resolves to the literal "GOTI" via  */
  /* REXX NOVALUE — the handler then treats ITEM(GOTI) as a cursor-   */
  /* less READ and writes the item number actually read back into     */
  /* GOTI on success. Without DROP, GOTI keeps the prior iteration's  */
  /* value (e.g. "1") and the handler reads item 1 again forever.     */
  DROP GOTI
  EXEC CICS READQ TS QUEUE(QNM) INTO(REC) ITEM(GOTI) END-EXEC
  SELECT
    WHEN EIBRESP = 0 THEN DO
      LITM = GOTI
      LPAY = LEFT(REC, 60)
      NRD  = NRD + 1
    END
    WHEN EIBRESP = 26 THEN DO        /* ITEMERR -- queue exhausted */
      LITM = '(end)'
      LPAY = ''
    END
    WHEN EIBRESP = 44 THEN DO        /* QIDERR -- queue absent     */
      LITM = '(qiderr)'
      LPAY = ''
    END
    OTHERWISE NOP
  END
END

EXIT
