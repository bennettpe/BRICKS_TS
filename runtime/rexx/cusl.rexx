/* CUSL -- list / search the customers file, paged via PF7/PF8.  */
/* Invoked via EXEC CICS LINK PROGRAM('CUSL') from CUST.   */
/*   */
/* The customers file is a KSDS (key-sequenced data set) backed by a  */
/* B+tree, so STARTBR + READNEXT walk records in key order in O(log n)*/
/* per seek and O(1) per step. Empty filter walks every key; a non-empty */
/* filter does an in-program substring match against key+record so the*/
/* search hits any field (name, address, city, phone, custno).  */
/*   */
/* If you want a prefix-only scan (faster, but only matches the key  */
/* prefix), the same handler accepts:  */
/*   EXEC CICS STARTBR FILE('customers')  */
/*                     RIDFLD(FILTER) GENERIC  */
/*                     KEYLENGTH(LENGTH(FILTER)) END-EXEC  */
/* and READNEXT then returns ENDFILE as soon as the prefix breaks.  */

/* COMMAREA protocol: caller passes the search filter on the way in. */
/* CUSL writes the match count back into DFHCOMMAREA on return so CUST*/
/* can render an empty-result message ("No matching records found")   */
/* without an extra round-trip. A zero count short-circuits the list  */
/* screen entirely.  */

ADDRESS CICS

FILTER = UPPER(STRIP(DFHCOMMAREA))

/* Adapt to terminal model: 35 rows per page on mod 4 (43-row screen),*/
/* 15 on mod 2. Suffix the list-map name (CUSTL  CUSTLL) the same way.  */
EXEC CICS ASSIGN SCREENHT(SCRH) END-EXEC
ROWS_PER_PAGE = 15
LISTMAP = 'CUSTL'
IF SCRH >= 43 THEN DO
  ROWS_PER_PAGE = 35
  LISTMAP = 'CUSTLL'
END

/* --- Load matching keys + records via STARTBR / READNEXT / ENDBR. ----- */
KEYS.0 = 0
EXEC CICS STARTBR FILE('customers') END-EXEC
DONE = 0
DO WHILE DONE = 0
  EXEC CICS READNEXT FILE('customers') INTO(REC) RIDFLD(KEY) END-EXEC
  IF EIBRESP \= 0 THEN DONE = 1
  ELSE DO
    HAY = UPPER(KEY || ' ' || REC)
    IF FILTER = '' | POS(FILTER, HAY) > 0 THEN DO
      N = KEYS.0 + 1
      KEYS.0 = N
      KEYS.N = KEY
      RECS.N = REC
    END
  END
END
EXEC CICS ENDBR FILE('customers') END-EXEC

TOTAL  = KEYS.0
PAGE   = 1
NPAGES = (TOTAL + ROWS_PER_PAGE - 1) % ROWS_PER_PAGE
IF NPAGES = 0 THEN NPAGES = 1

/* Empty result set: skip the list screen entirely and let CUST render*/
/* the appropriate message. DFHCOMMAREA carries '0' back to the caller.  */
IF TOTAL = 0 THEN DO
  DFHCOMMAREA = '0'
  EXEC CICS RETURN END-EXEC
END

EXIT_LIST = 0
DO WHILE EXIT_LIST = 0
  SCR. = ''
  IF FILTER = '' THEN DO
    SCR.INFOLINE = 'CUSL -- customer list   page' PAGE 'of' NPAGES,
                   '   total:' TOTAL
  END
  ELSE DO
    SCR.INFOLINE = 'CUSL -- search:' FILTER '  page' PAGE 'of' NPAGES,
                   '   matched:' TOTAL
  END
  START = (PAGE - 1) * ROWS_PER_PAGE + 1
  /* Always assign all 15 row slots so stale page-N values do not bleed   */
  /* into a shorter page. SCR. = '' only sets the stem default; it does  */
  /* not clear previously-assigned tails.  */
  DO J = 1 TO ROWS_PER_PAGE
    IDX = START + J - 1
    LINE = ''
    IF IDX <= TOTAL THEN DO
      K = KEYS.IDX
      R = RECS.IDX

      PARSE VAR R NM '|' AD '|' CY '|' PH
      LINE = LEFT(K,8) LEFT(NM,28) LEFT(CY,18) LEFT(PH,14)
    END
    CALL VALUE 'SCR.ROW' || J, LINE
  END


  EXEC CICS SEND MAP(LISTMAP) FROM(SCR.) ERASE END-EXEC
  IF EIBRESP = 36 THEN DO
    /* Sized variant absent  fall back to the 24x80 list. */
    LISTMAP = 'CUSTL'
    ROWS_PER_PAGE = 15
    NPAGES = (TOTAL + ROWS_PER_PAGE - 1) % ROWS_PER_PAGE
    IF NPAGES = 0 THEN NPAGES = 1
    IF PAGE > NPAGES THEN PAGE = NPAGES
    EXEC CICS SEND MAP(LISTMAP) FROM(SCR.) ERASE END-EXEC
  END
  EXEC CICS RECEIVE MAP(LISTMAP) END-EXEC

  AID = C2X(EIBAID)
  SELECT
    WHEN AID = 'F3' THEN EXIT_LIST = 1
    WHEN AID = 'F7' THEN DO
      IF PAGE > 1 THEN PAGE = PAGE - 1
    END
    WHEN AID = 'F8' THEN DO
      IF PAGE < NPAGES THEN PAGE = PAGE + 1
    END
    OTHERWISE NOP
  END
END

/* Hand the match count back to the caller via DFHCOMMAREA. CUST reads*/
/* this to compose its post-list status message.  */
DFHCOMMAREA = TOTAL
EXEC CICS RETURN END-EXEC
EXIT
