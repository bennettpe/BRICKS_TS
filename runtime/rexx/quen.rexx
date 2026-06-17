/* --------------------------------------------------------------------
 * QUEN -- conversational N-Queens solution counter.
 *
 * Usage:  QUEN n        (n = number of queens / board size, 5 to 13)
 *
 * The program counts how many distinct ways n non-attacking queens fit
 * on an n x n chessboard and reports ONLY that combination total --
 * the individual boards are counted, never painted.
 *
 * Input is retrieved from the UNFORMATTED screen with the reverse of
 * SEND TEXT: EXEC CICS RECEIVE INTO(BUF). bricks hands the operator's
 * typed command line (transid + args) to the first RECEIVE of the task;
 * a chained dispatch with nothing to read returns EOC (EIBRESP=6). No
 * BMS map is used -- prompt and result are painted with SEND TEXT, the
 * reply is collected with RECEIVE.
 *
 * Out-of-range or non-numeric input is refused with a SEND TEXT prompt
 * telling the operator the valid range; they re-drive the conversation
 * by typing  QUEN n  again.
 * --------------------------------------------------------------------
 */
ADDRESS CICS

LO = 5
HI = 12

/* Reverse of SEND TEXT: pull the operator's unformatted input line.   */
EXEC CICS RECEIVE INTO(BUF) END-EXEC
IF EIBRESP = 6 THEN DO
  EXEC CICS SEND TEXT FROM('QUEN: nothing to read (chained dispatch).') ERASE END-EXEC
  EXEC CICS RETURN END-EXEC
END

/* First token is the transid (QUEN); the second is the queen count.   */
PARSE VAR BUF TID NRAW .
NRAW = STRIP(NRAW)

/* Validate into a single error message; empty ERRMSG means "good".    */
ERRMSG = ''
IF NRAW = '' THEN
  ERRMSG = 'No queen count supplied.'
ELSE IF \DATATYPE(NRAW, 'W') THEN
  ERRMSG = '"' || NRAW || '" is not a whole number.'
ELSE DO
  N = NRAW + 0
  IF N < LO THEN
    ERRMSG = 'Too few:' N 'is below the minimum of' LO || '.'
  ELSE IF N > HI THEN
    ERRMSG = 'Too many:' N 'is above the maximum of' HI || '.'
END

IF ERRMSG \= '' THEN DO
  TXT = LEFT('BRICKS N-QUEENS', 80)
  TXT = TXT || LEFT('', 80)
  TXT = TXT || LEFT(ERRMSG, 80)
  TXT = TXT || LEFT('', 80)
  TXT = TXT || LEFT('Type:  QUEN n   where n is a whole number from' LO 'to' HI || '.', 80)
  EXEC CICS SEND TEXT FROM(TXT) ERASE END-EXEC
  EXEC CICS RETURN END-EXEC
END

/* Count the solutions -- no boards are ever painted. Time the run     */
/* with ASKTIME ABSTIME (IBM milliseconds since 1900); the difference  */
/* is the elapsed calculation time.                                    */
EXEC CICS ASKTIME ABSTIME(START_TIME) END-EXEC
COUNT = QUEEN(N)
EXEC CICS ASKTIME ABSTIME(END_TIME) END-EXEC
ELAPSED = END_TIME - START_TIME
SECS = ELAPSED / 1000

TXT = LEFT('BRICKS N-QUEENS', 80)
TXT = TXT || LEFT('', 80)
TXT = TXT || LEFT(N'-Queens on a' N'x'N 'chessboard:', 80)
TXT = TXT || LEFT(COUNT 'distinct solutions.', 80)
TXT = TXT || LEFT('Calculated in' SECS 'seconds (' || ELAPSED 'ms).', 80)
TXT = TXT || LEFT('', 80)
TXT = TXT || LEFT('Press ENTER to continue.', 80)
EXEC CICS SEND TEXT FROM(TXT) ERASE END-EXEC
EXEC CICS RETURN END-EXEC
EXIT
/* --------------------------------------------------------------------
 * QUEEN -- iterative back-tracking solver. Returns the count of
 * distinct placements of N queens on an N x N board. Boards are
 * counted (COUNT), never displayed.
 *
 * The old PLACE routine re-scanned every earlier row to test a square
 * (O(row) per placement). This version carries the bitboard idea --
 * three occupancy sets -- but as REXX stem arrays rather than packed
 * integers, because bricks' BITAND/BITOR are byte-string ops and there
 * is no integer shift, whereas stem access and integer + - = all sit
 * on the interpreter's fast path:
 *
 *   USEDCOL.c        column c already holds a queen
 *   USEDAD.(r+c)     the / anti-diagonal through (r,c) is taken
 *   USEDMD.(r-c+N)   the \ main  diagonal through (r,c) is taken
 *
 * Each test and update is O(1), so a placement check never walks the
 * earlier rows. Stem defaults seed every tail to 0 (free).
 * --------------------------------------------------------------------
 */
QUEEN: PROCEDURE EXPOSE COUNT
 PARSE ARG N
 COUNT = 0
 USEDCOL. = 0
 USEDAD.  = 0
 USEDMD.  = 0
 K = 1
 A.K = 0
 DO WHILE K > 0
    /* Resume scanning row K just past the column last tried there.      */
    C = A.K + 1
    FOUND = 0
    DO WHILE C <= N & FOUND = 0
       AD = K + C
       MD = K - C + N
       IF USEDCOL.C = 0 & USEDAD.AD = 0 & USEDMD.MD = 0 THEN
          FOUND = 1                /* AD / MD now hold this column's keys */
       ELSE
          C = C + 1
    END
    IF FOUND = 0 THEN DO
       /* Row K is exhausted: drop back and free the parent's queen so   */
       /* its next column can be tried on the following pass.            */
       K = K - 1
       IF K > 0 THEN DO
          PC = A.K
          USEDCOL.PC = 0
          AD = K + PC      ; USEDAD.AD = 0
          MD = K - PC + N  ; USEDMD.MD = 0
       END
    END
    ELSE DO
       A.K = C
       IF K = N THEN
          /* Last row filled: a complete board -- count it and keep      */
          /* scanning row N for further final-column choices (no marks). */
          COUNT = COUNT + 1
       ELSE DO
          /* Fix this queen (reusing AD / MD from the scan) and descend. */
          USEDCOL.C = 1
          USEDAD.AD = 1
          USEDMD.MD = 1
          K = K + 1
          A.K = 0
       END
    END
 END
 RETURN COUNT
