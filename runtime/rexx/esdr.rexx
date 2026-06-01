/* ESDR -- ESDS-style browse demo (REXX twin of ESDC).            */
/*                                                                */
/* Walks runtime/tmp/audit.log forward with READNEXT and backward */
/* with READPREV, paginating across the shared ESDS map. The      */
/* program is the canonical sample for the bricks sequential-file */
/* surface documented in PROGRAMMING.md Chapter 8a.               */
/*                                                                */
/* EXEC verbs exercised:                                          */
/*   ASSIGN     -- detect terminal model (SCREENHT) for page size */
/*   WRITEQ TD  -- seed audit.log when the operator wiped it      */
/*   STARTBR    -- open browse at RBA 0 (decimal text, BOF)       */
/*   READNEXT   -- forward walk, RIDFLD writeback = decimal RBA   */
/*   READPREV   -- backward walk for PF7 paging                   */
/*   READ FILE  -- positional one-shot demo (after ENDBR, on F3)  */
/*   ENDBR      -- release the cursor                             */
/*   SEND MAP   -- paint the shared ESDS panel                    */
/*   RECEIVE    -- block on operator AID                          */
/*   RETURN     -- pseudo-conversational exit                     */
/*                                                                */
/* Bricks deviations highlighted:                                 */
/*   * RBA is decimal ASCII, not a 4-byte COMP fullword. We do    */
/*     plain string arithmetic on it (see Chapter 8a).            */
/*   * STARTBR without RIDFLD = BOF. We pass RIDFLD('0') anyway   */
/*     so the operator sees the IBM-canonical form.               */
/*   * LENGTH(LEN) on a sequential READNEXT is INPUT capacity +   */
/*     OUTPUT actual. We pre-set LEN = 64 so a record longer than */
/*     64 bytes raises LENGERR with the untruncated length        */
/*     written back -- demoed in PAINT_PAGE_FORWARD.              */
/*                                                                */
/* The brief asks for DFHRESP(NAME) form to match the IBM         */
/* canonical syntax memory. The bricks REXX dialect does not      */
/* expose the DFHRESP function (it is COBOL-only via the copybook */
/* COPY DFHRESP), so we compare EIBRESP against its numeric value */
/* and tag every comparison with the equivalent DFHRESP mnemonic  */
/* in a trailing comment. EIBAID is decoded via C2X(EIBAID) and   */
/* the documented hex code for each PF key, matching cusl.rexx,   */
/* chat.rexx, and every other shipped sample.                     */

ADDRESS CICS

FNAME = 'audit.log'

/* -- Detect terminal model. mod 2 = 15 rows, mod 4 = 32 rows. -- */
EXEC CICS ASSIGN SCREENHT(SH) END-EXEC
PAGESIZE = 15
IF SH >= 43 THEN PAGESIZE = 15   /* map only defines ROW1..ROW15  */
                                 /* so even on mod 4 we cap at 15 */
                                 /* to match the shared ESDS map. */

/* -- Open the browse. RIDFLD('0') is the BOF position; the       */
/* -- bricks deviation that allows STARTBR with no RIDFLD also    */
/* -- means BOF, but we pass '0' explicitly so the canonical form */
/* -- shows up in the sample.                                     */
EXEC CICS STARTBR FILE(FNAME) RIDFLD('0') END-EXEC
IF EIBRESP \= 0 THEN SIGNAL STARTBR_FAILED   /* not DFHRESP(NORMAL) */

/* -- First page: forward from BOF. ----------------------------- */
PAGE_TOP_RBA = '0'
ATEOF = 0
ATBOF = 1
INFO  = 'ESDR -- bottom of file? PF8. top of file? PF7. PF3=exit.'
CALL PAINT_PAGE_FORWARD

/* -- Interaction loop. ----------------------------------------- */
DONE = 0
DO WHILE DONE = 0
  EXEC CICS SEND MAP('ESDS') MAPSET('ESDS') FROM(SCR.) ERASE END-EXEC
  EXEC CICS RECEIVE MAP('ESDS') MAPSET('ESDS') INTO(MAP.) END-EXEC

  AID = C2X(EIBAID)
  SELECT
    WHEN AID = 'F3' THEN DONE = 1                  /* DFHPF3  */
    WHEN AID = 'F8' THEN DO                        /* DFHPF8  */
      IF ATEOF = 1 THEN DO
        INFO = 'END OF FILE -- PF7 to scroll back, PF3 to exit.'
      END
      ELSE CALL PAINT_PAGE_FORWARD
    END
    WHEN AID = 'F7' THEN DO                        /* DFHPF7  */
      IF ATBOF = 1 THEN DO
        INFO = 'TOP OF FILE -- PF8 to scroll forward, PF3 to exit.'
      END
      ELSE CALL PAINT_PAGE_BACKWARD
    END
    OTHERWISE NOP
  END
END

EXEC CICS ENDBR FILE(FNAME) END-EXEC
EXEC CICS RETURN END-EXEC
EXIT


/* ================================================================
 * PAINT_PAGE_FORWARD -- READNEXT up to PAGESIZE records, format
 *   each as <10-digit RBA><two spaces><record text>, populate
 *   SCR.ROW1..ROWn. Detect LENGERR on any oversize record and
 *   surface the count in INFO. Capture the RBA of the first record
 *   of the page so PF7 can repaginate the prior block.
 * ================================================================ */
PAINT_PAGE_FORWARD: PROCEDURE EXPOSE SCR. FNAME PAGESIZE PAGE_TOP_RBA
  SCR. = ''
  SCR.TYPE = 'REXX'
  FIRST_RBA = ''
  LAST_RBA  = ''
  OVERCNT  = 0
  I     = 0
  ATBOF = 0
  DO WHILE I < PAGESIZE
    REC = ''
    LEN = 64                          /* INPUT buffer capacity   */
    RBA = ''
    EXEC CICS READNEXT FILE(FNAME) INTO(REC) RIDFLD(RBA) LENGTH(LEN) END-EXEC
    SELECT
      WHEN EIBRESP = 0 THEN DO        /* DFHRESP(NORMAL)         */
        I = I + 1
        IF FIRST_RBA = '' THEN FIRST_RBA = RBA
        LAST_RBA = RBA
        CALL SET_ROW I, RBA, REC, 0
      END
      WHEN EIBRESP = 22 THEN DO       /* DFHRESP(LENGERR)        */
        I = I + 1
        OVERCNT = OVERCNT + 1
        IF FIRST_RBA = '' THEN FIRST_RBA = RBA
        LAST_RBA = RBA
        /* LEN now holds the *actual* (untruncated) record length */
        /* per Chapter 8a -- the program can tell how much was   */
        /* lost. REC carries the first 64 bytes only.            */
        CALL SET_ROW I, RBA, REC, LEN
      END
      WHEN EIBRESP = 20 THEN DO       /* DFHRESP(ENDFILE)        */
        ATEOF = 1
        LEAVE
      END
      OTHERWISE DO
        INFO = 'ESDR -- READNEXT failed EIBRESP=' || EIBRESP
        LEAVE
      END
    END
  END
  PAGE_TOP_RBA = FIRST_RBA
  IF ATEOF = 1 & I = 0 THEN DO
    INFO = 'END OF FILE -- PF7 to scroll back, PF3 to exit.'
  END
  ELSE IF ATEOF = 1 THEN DO
    INFO = 'END OF FILE on RBA' STRIP(LAST_RBA),
           '-- PF7 to scroll back.'
  END
  ELSE IF OVERCNT > 0 THEN DO
    INFO = 'LENGERR --' OVERCNT 'record(s) >64 bytes; shown truncated.'
  END
  ELSE DO
    INFO = 'ESDR -- page from RBA' STRIP(FIRST_RBA),
           'to' STRIP(LAST_RBA) '  PF7/PF8 to page, PF3 to exit.'
  END
  SCR.INFOLINE = INFO
RETURN


/* ================================================================
 * PAINT_PAGE_BACKWARD -- READPREV PAGESIZE times to walk back one
 *   page. READPREV returns ENDFILE at BOF (Chapter 8a: same RESP
 *   in both directions). We collect newest-to-oldest then reverse
 *   so the page renders oldest-at-top, matching forward-paint
 *   ordering.
 * ================================================================ */
PAINT_PAGE_BACKWARD: PROCEDURE EXPOSE SCR. FNAME PAGESIZE PAGE_TOP_RBA
  SCR. = ''
  SCR.TYPE = 'REXX'
  /* First step back from the current top so we don't repaint the */
  /* same page. If that single READPREV hits BOF we're already on */
  /* the top page; restore the cursor by re-STARTBRing from 0.    */
  REC = ''
  LEN = 64
  RBA = ''
  EXEC CICS READPREV FILE(FNAME) INTO(REC) RIDFLD(RBA) LENGTH(LEN) END-EXEC
  IF EIBRESP = 20 THEN DO              /* DFHRESP(ENDFILE) = BOF */
    EXEC CICS ENDBR FILE(FNAME) END-EXEC
    EXEC CICS STARTBR FILE(FNAME) RIDFLD('0') END-EXEC
    ATBOF = 1
    PAGE_TOP_RBA = '0'
    CALL PAINT_PAGE_FORWARD
    SCR.INFOLINE = 'TOP OF FILE -- PF8 to scroll forward, PF3 to exit.'
    RETURN
  END
  IF EIBRESP \= 0 & EIBRESP \= 22 THEN DO
    SCR.INFOLINE = 'ESDR -- READPREV failed EIBRESP=' || EIBRESP
    RETURN
  END

  /* Stash that first prior record, then keep walking backward.   */
  REVRBA.1 = RBA
  REVREC.1 = REC
  REVLEN.1 = LEN
  REVERR.1 = (EIBRESP = 22)
  COUNT = 1
  HITBOF = 0
  DO WHILE COUNT < PAGESIZE & HITBOF = 0
    REC = ''
    LEN = 64
    RBA = ''
    EXEC CICS READPREV FILE(FNAME) INTO(REC) RIDFLD(RBA) LENGTH(LEN) END-EXEC
    SELECT
      WHEN EIBRESP = 0 THEN DO         /* DFHRESP(NORMAL)        */
        COUNT = COUNT + 1
        REVRBA.COUNT = RBA
        REVREC.COUNT = REC
        REVLEN.COUNT = LEN
        REVERR.COUNT = 0
      END
      WHEN EIBRESP = 22 THEN DO        /* DFHRESP(LENGERR)       */
        COUNT = COUNT + 1
        REVRBA.COUNT = RBA
        REVREC.COUNT = REC
        REVLEN.COUNT = LEN
        REVERR.COUNT = 1
      END
      WHEN EIBRESP = 20 THEN HITBOF = 1   /* DFHRESP(ENDFILE)    */
      OTHERWISE HITBOF = 1
    END
  END

  /* REVRBA.1 is newest of the prior page, REVRBA.COUNT is oldest.*/
  /* Reverse-render so row 1 = oldest, row COUNT = newest. After  */
  /* the reversal the browse cursor sits one step BEFORE the      */
  /* oldest record we painted, so a subsequent READNEXT would     */
  /* re-emit it. Re-position by stepping forward COUNT times so   */
  /* the cursor lands at the newest record of the prior page,     */
  /* leaving the next PF8 (PAINT_PAGE_FORWARD) to start at the    */
  /* page that originally followed.                               */
  OVERCNT = 0
  DO J = 1 TO COUNT
    SRCIDX = COUNT - J + 1
    R = REVREC.SRCIDX
    A = REVRBA.SRCIDX
    L = REVLEN.SRCIDX
    E = REVERR.SRCIDX
    IF E = 1 THEN DO
      OVERCNT = OVERCNT + 1
      CALL SET_ROW J, A, R, L
    END
    ELSE CALL SET_ROW J, A, R, 0
  END

  PAGE_TOP_RBA = REVRBA.COUNT
  /* Re-sync the cursor: walk forward COUNT records so the next   */
  /* READNEXT picks up after the page we just painted.            */
  DO J = 1 TO COUNT
    REC = ''
    LEN = 64
    RBA = ''
    EXEC CICS READNEXT FILE(FNAME) INTO(REC) RIDFLD(RBA) LENGTH(LEN) END-EXEC
    IF EIBRESP = 20 THEN LEAVE         /* DFHRESP(ENDFILE)       */
  END

  IF HITBOF = 1 THEN ATBOF = 1
  IF OVERCNT > 0 THEN DO
    SCR.INFOLINE = 'LENGERR --' OVERCNT,
        'record(s) >64 bytes; shown truncated.'
  END
  ELSE IF HITBOF = 1 THEN DO
    SCR.INFOLINE = 'TOP OF FILE -- PF8 to scroll forward, PF3 to exit.'
  END
  ELSE DO
    SCR.INFOLINE = 'ESDR -- page from RBA' STRIP(REVRBA.COUNT),
        || ' to' STRIP(REVRBA.1) '   PF7/PF8 to page, PF3 to exit.'
  END
RETURN


/* ================================================================
 * SET_ROW idx, rba, rec, actual_len
 *   Format one ROWn cell. When actual_len > 0 the record overflowed
 *   the 64-byte buffer; we tag the line with a "!" sentinel column
 *   and append the actual-length notice so the operator can see
 *   exactly which row triggered LENGERR. The map field colour stays
 *   green; the INFOLINE carries the red status (set by the caller).
 * ================================================================ */
SET_ROW: PROCEDURE EXPOSE SCR.
  PARSE ARG SIDX, SRBA, SREC, SLEN
  ROWNAME = 'SCR.ROW' || SIDX
  PAD = RIGHT(STRIP(SRBA), 10, '0')
  IF SLEN > 0 THEN DO
    LINE = PAD || '  ' || '!' || LEFT(SREC, 60),
        || ' [LEN=' || SLEN || ']'
  END
  ELSE DO
    LINE = PAD || '  ' || LEFT(SREC, 64)
  END
  CALL VALUE ROWNAME, LEFT(LINE, 76)
RETURN


/* ================================================================
 * STARTBR_FAILED -- the initial open failed. Render a one-screen
 *   error and exit. Common causes: filesystem permission, IOERR,
 *   or operator pointed FNAME at a non-existent file (NOTFND).
 * ================================================================ */
STARTBR_FAILED: PROCEDURE EXPOSE SCR. MAP.
  SCR. = ''
  SCR.TYPE = 'REXX'
  SELECT
    WHEN EIBRESP = 13 THEN              /* DFHRESP(NOTFND)        */
      SCR.INFOLINE = 'ESDR -- audit.log not found in tmp_dir.'
    WHEN EIBRESP = 16 THEN              /* DFHRESP(INVREQ)        */
      SCR.INFOLINE = 'ESDR -- STARTBR INVREQ; bad RIDFLD or name.'
    WHEN EIBRESP = 17 THEN              /* DFHRESP(IOERR)         */
      SCR.INFOLINE = 'ESDR -- STARTBR IOERR on audit.log.'
    OTHERWISE
      SCR.INFOLINE = 'ESDR -- STARTBR failed EIBRESP=' || EIBRESP
  END
  EXEC CICS SEND MAP('ESDS') MAPSET('ESDS') FROM(SCR.) ERASE END-EXEC
  EXEC CICS RECEIVE MAP('ESDS') MAPSET('ESDS') INTO(MAP.) END-EXEC
  EXEC CICS RETURN END-EXEC
EXIT
