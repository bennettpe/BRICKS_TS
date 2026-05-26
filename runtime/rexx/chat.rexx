/* CHAT -- conversational real-time multi-user chat.
 *
 * Two invocation paths share this one program file:
 *
 *  (1) Background TICK -- the scheduler-fired self-restart. The
 *      preceding invocation issued
 *        EXEC CICS START TRANSID('CHAT') INTERVAL(000002) FROM('TICK')
 *      and we see that payload now via RETRIEVE. We paint the chat
 *      history rows (and clock) via SEND MAP DATAONLY (partial,
 *      no-block, doesn't disturb the operator's typing on the input
 *      field), schedule the next tick, and RETURN. This invocation
 *      runs inline in the scheduler timer goroutine (see
 *      cics/start.go wake + txn/runBackground) while the main
 *      conversational task on the same terminal stays blocked in
 *      its SEND MAP. The TS-queue 'CHATACT'||TRM gates this -- when
 *      the user F3-exits the main task we DELETEQ the flag and the
 *      next tick sees QIDERR and silently returns without
 *      re-scheduling.
 *
 *  (2) Main conversational loop -- the normal entry when the
 *      operator types 'CHAT' at the blank prompt. DO FOREVER.
 *      Each iteration loads the latest history from CHATLOG,
 *      paints the full screen, blocks on RECEIVE MAP, then
 *      processes the AID:
 *          F3      -> DELETEQ flag, RETURN (exit chat)
 *          ENTER   -> EXEC CICS WRITE FILE('CHATLOG') with the
 *                     operator's typed line, loop back to repaint.
 *          other   -> just loop back to repaint.
 *      This is the cust.rexx idiom verbatim minus the action menu.
 *
 * Messages live in a KSDS file CHATLOG; the file is auto-created
 * by the bricks store on first WRITE. Key shape (23 bytes,
 * lexicographic = chronological):
 *      YYYYMMDDHHMMSS-NNNN-TTTT
 *  - 14-byte timestamp from DATE('S') + TIME() without colons,
 *  - 4-digit NNNN sequence bumped on DUPREC so same-second-same-
 *    terminal collisions still get distinct keys,
 *  - 4-byte TERMID suffix so two terminals writing in the same
 *    second always get distinct keys.
 * Record shape (80 bytes fixed): USERID(8) + MESSAGE(72).
 */

ADDRESS CICS

EXEC CICS ASSIGN USERID(USR) TERMID(TRM) SCREENHT(H) END-EXEC
USR = LEFT(STRIP(USR), 8)
IF STRIP(USR) = '' THEN USR = 'ANONYM'
TRM = LEFT(STRIP(TRM), 4)
IF H >= 43 THEN DO
  MAPNAME = 'CHATM4'
  NLINES  = 35
END
ELSE DO
  MAPNAME = 'CHATM2'
  NLINES  = 16
END
ACTQ = 'CHATACT' || TRM

/* === Path 1: scheduler-fired TICK ============================== */
BUF = ''
EXEC CICS RETRIEVE INTO(BUF) END-EXEC
IF EIBRESP = 0 & LEFT(STRIP(BUF), 4) = 'TICK' THEN DO
  /* Is chat still active on this terminal? If not, the user has
   * F3'd out earlier; die quietly and don't re-schedule. */
  _DUMMY = ''
  EXEC CICS READQ TS QUEUE(ACTQ) INTO(_DUMMY) END-EXEC
  IF EIBRESP \= 0 THEN DO
    EXEC CICS RETURN END-EXEC
    EXIT
  END
  CALL LOAD_HISTORY
  /* Partial paint: only CLOCK + ROWxx populated, so RenderPartial
   * sends just those. The input field on the operator's terminal
   * is preserved because we never set SCR.INPUT. */
  SCR. = ''
  SCR.CLOCK = TIME()
  CALL POPULATE_ROWS
  EXEC CICS SEND MAP(MAPNAME) FROM(SCR.) DATAONLY END-EXEC
  /* Schedule the next tick. */
  EXEC CICS START TRANSID('CHAT') INTERVAL(000002) FROM('TICK') END-EXEC
  EXEC CICS RETURN END-EXEC
  EXIT
END

/* === Path 2: main conversational loop ========================== */
EXEC CICS WRITEQ TS QUEUE(ACTQ) FROM('Y') END-EXEC
/* Schedule the FIRST tick. Each subsequent tick re-schedules
 * itself from Path 1 above. */
EXEC CICS START TRANSID('CHAT') INTERVAL(000002) FROM('TICK') END-EXEC

DO FOREVER
  CALL LOAD_HISTORY
  /* Full ERASE paint: TITLE/TOPIC/FOOTER + history rows. Leave
   * SCR.INPUT empty so the operator's typed-but-not-yet-sent
   * buffer from the previous iteration doesn't echo back. */
  SCR. = ''
  SCR.TITLE  = 'BRICKS CHAT'
  SCR.CLOCK  = TIME()
  SCR.TOPIC  = 'User:' USR 'Term:' TRM
  SCR.FOOTER = 'F3=exit  Enter=send'
  SCR.STATUS = ''
  CALL POPULATE_ROWS

  EXEC CICS SEND MAP(MAPNAME) FROM(SCR.) ERASE END-EXEC
  EXEC CICS RECEIVE MAP(MAPNAME) END-EXEC

  AID = C2X(EIBAID)
  IF AID = 'F3' THEN DO
    EXEC CICS DELETEQ TS QUEUE(ACTQ) END-EXEC
    EXEC CICS RETURN END-EXEC
    EXIT
  END

  /* Any non-F3 AID: post the typed line if non-blank. ENTER is
   * the common case; stray PF-keys also fall through here -- we
   * just re-paint, which is the right "no-op" for an unexpected
   * key. */
  LINE = STRIP(MAP.INPUT)
  IF LINE \= '' THEN DO
    TS = DATE('S') || SPACE(TRANSLATE(TIME(), '   ', ':'), 0)
    SEQ = 1
    WDONE = 0
    DO WHILE WDONE = 0 & SEQ < 9999
      KEY = TS || '-' || RIGHT(SEQ, 4, '0') || '-' || LEFT(TRM, 4)
      REC = LEFT(USR, 8) || LEFT(LINE, 72)
      EXEC CICS WRITE FILE('CHATLOG') FROM(REC) RIDFLD(KEY) END-EXEC
      IF EIBRESP = 0 THEN WDONE = 1
      ELSE IF EIBRESP = 14 THEN SEQ = SEQ + 1   /* DUPREC -- bump */
      ELSE WDONE = 1                            /* surface via STATUS next iter */
    END
  END
END

EXIT


/* ------------------------------------------------------------------
 * Helpers (PROCEDURE EXPOSE because bricks REXX CALL only resolves
 * named PROCEDURE labels -- bare labels error out with "unknown
 * function").
 * ------------------------------------------------------------------ */

LOAD_HISTORY: PROCEDURE EXPOSE NLINES HIST.
  HIST. = ''
  HIST.0 = 0
  HIGHKEY = COPIES('Z', 23)
  EXEC CICS STARTBR FILE('CHATLOG') RIDFLD(HIGHKEY) GTEQ END-EXEC
  IF EIBRESP \= 0 THEN RETURN
  HI = 0
  DONE = 0
  DO WHILE HI < NLINES & DONE = 0
    EXEC CICS READPREV FILE('CHATLOG') INTO(REC) RIDFLD(KEY) END-EXEC
    IF EIBRESP \= 0 THEN DONE = 1
    ELSE DO
      HI = HI + 1
      HIST.HI = REC
    END
  END
  HIST.0 = HI
  EXEC CICS ENDBR FILE('CHATLOG') END-EXEC
  RETURN


POPULATE_ROWS: PROCEDURE EXPOSE NLINES HIST. SCR.
  /* Chronological order with newest at the BOTTOM, oldest at the
   * TOP. HIST.1 is the most recent record (READPREV walked
   * newest-first), so we render it on the lowest occupied row;
   * older records fill rows upward. Empty rows at the top mean
   * "no chat yet that far back".
   *
   * Mapping for NLINES=16, HIST.0=6:
   *   ROW16 = HIST.1 (newest)
   *   ROW15 = HIST.2
   *   ...
   *   ROW11 = HIST.6 (oldest)
   *   ROW10..ROW01 = empty
   */
  DO J = 1 TO NLINES
    ROWNAME = 'SCR.ROW' || RIGHT(J, 2, '0')
    HISTIDX = NLINES - J + 1
    IF HISTIDX > 0 & HISTIDX <= HIST.0 THEN DO
      REC = HIST.HISTIDX
      USER = LEFT(SUBSTR(REC, 1, 8), 8)
      MSG  = STRIP(SUBSTR(REC, 9, 72), 'T')
      LINE = LEFT(USER, 8) ' ' MSG
      CALL VALUE ROWNAME, LEFT(LINE, 76)
    END
    ELSE CALL VALUE ROWNAME, ''
  END
  RETURN
