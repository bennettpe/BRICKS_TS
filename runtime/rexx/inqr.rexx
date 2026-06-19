/* INQR -- EXEC CICS INQUIRE demo (REXX). Shows both access shapes:    */
/*   1. DIRECT  INQUIRE TASK(id)  -- read this task's own attributes.   */
/*   2. BROWSE  STARTBROWSE FILE / INQUIRE FILE(fn) NEXT / ENDBROWSE    */
/*              -- walk every defined FILE, printing one row each.      */
/*                                                                      */
/* Type INQR at the prompt. It paints a TASK summary then a FILE list. */
/* INQUIRE status fields (RUNSTATUS, OPENSTATUS, ENABLESTATUS) are the  */
/* IBM happy-path defaults in bricks; record/key sizes are real.       */

ADDRESS CICS

/* ---- 1. DIRECT inquiry: this task ---------------------------------- */
/* EIBTASKN is the numeric task id this program runs under; INQUIRE     */
/* TASK(id) accepts that same numeric form.                            */
EXEC CICS ASSIGN EIBTASKN(MYTASK) END-EXEC

RS = '?'
TR = '?'
EXEC CICS INQUIRE TASK(MYTASK) RUNSTATUS(RS) TRANSACTION(TR) RESP(RC) END-EXEC
IF RC \= 0 THEN DO
  TR = '(inquire task failed; EIBRESP=' || RC || ')'
  RS = ''
END

/* SEND TEXT tiles the flat buffer into screen-width (80-col) rows, and  */
/* go3270 reserves column 1 of each row for the field attribute byte, so */
/* every logical line must be padded to the FULL 80 columns (not 79) or  */
/* the rows slip one column further left on each line. Keep the visible  */
/* content within the first 79 columns; the 80th is absorbed padding.    */
TXT = LEFT('INQR -- INQUIRE TASK / FILE demo', 80)
TXT = TXT || LEFT('', 80)
TXT = TXT || LEFT('TASK ' || MYTASK || '  TRAN=' || TR || '  STATUS=' || RS, 80)
TXT = TXT || LEFT('', 80)
TXT = TXT || LEFT('FILE             OPEN     ENABLE   RECSZ  KEYLN', 80)

/* ---- 2. BROWSE inquiry: every FILE --------------------------------- */
/* STARTBROWSE freezes the file-name snapshot; each INQUIRE FILE NEXT   */
/* reads the current name into FN and its attrs into the host vars,     */
/* advancing the cursor. RESP becomes non-zero (END) at exhaustion.     */
EXEC CICS STARTBROWSE FILE RESP(RC) END-EXEC

NFILE = 0
DO WHILE RC = 0 & NFILE < 50
  FN = ''
  OS = ''
  ES = ''
  RZ = ''
  KL = ''
  EXEC CICS INQUIRE FILE(FN) NEXT OPENSTATUS(OS) ENABLESTATUS(ES) RECORDSIZE(RZ) KEYLENGTH(KL) RESP(RC) END-EXEC
  IF RC = 0 THEN DO
    NFILE = NFILE + 1
    ROW = LEFT(FN,16) || LEFT(OS,9) || LEFT(ES,9) || LEFT(RZ,7) || LEFT(KL,5)
    TXT = TXT || LEFT(ROW, 80)
  END
END

EXEC CICS ENDBROWSE FILE END-EXEC

TXT = TXT || LEFT('', 80)
TXT = TXT || LEFT(NFILE || ' file(s) browsed. Press CLEAR to exit.', 80)

EXEC CICS SEND TEXT FROM(TXT) ERASE END-EXEC
EXEC CICS RETURN END-EXEC
EXIT
