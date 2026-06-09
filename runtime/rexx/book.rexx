/* BOOK -- SABRE CRS, a fully pseudo-conversational, VSAM-backed
 * airline reservation transaction.
 *
 * ================================================================
 * PSEUDO-CONVERSATIONAL MODEL
 * ================================================================
 * BOOK is a command REPL (not a fixed wizard), so a single program
 * self-chains: every turn ends with
 *     EXEC CICS RETURN TRANSID('BOOK') COMMAREA(STATE) END-EXEC
 * and is re-dispatched on the next ENTER/PF key. The terminal is NOT
 * held between turns -- all dialogue state travels in the COMMAREA.
 *
 *   EIBCALEN = 0  -> COLD entry: init state, paint welcome, RETURN
 *                    TRANSID('BOOK') with the initial COMMAREA.
 *   EIBCALEN > 0  -> RE-ENTRY: STATE = DFHCOMMAREA, DESERIALIZE,
 *                    RECEIVE MAP, decode EIBAID, DISPATCH the typed
 *                    command, repaint, RETURN TRANSID('BOOK').
 *
 * Only the top level paints (one SEND MAP per turn). Handlers never
 * SEND -- they only APPEND transcript lines and touch the file.
 *
 * ================================================================
 * COMMAREA LAYOUT (transient dialogue state, opaque bytes, <~4KB)
 * ================================================================
 * Fixed 40-byte header, then two delimited regions:
 *   Off Len Field   Meaning
 *     1   1 VER     format version '1'
 *     2   8 AGENT   sign-in agent id ('01762   '), blank=not signed in
 *    10   1 AUTH    '1' signed in / '0' not
 *    11   6 CURPNR  current PNR 6-char locator ('      '=none)
 *    17   3 OFFS    scroll offset (lines above newest visible)
 *    20   2 NCAND   cached availability candidate count (00..15)
 *    22   6 QDATE   last availability date token ('18OCT ')
 *    28   7 QROUTE  'JFK/ZRH'
 *    35   6 -----   reserved/pad to 40
 *   CANDS region    flight tuples joined by '01'x (one per avail result)
 *   SCROLL region   last up to 60 transcript lines, each <=78 cols,
 *                   joined by '02'x
 * Header ends with '03'x ; CANDS region ends with '04'x ; then SCROLL.
 *
 * ================================================================
 * VSAM 'sabre' KSDS -- multiple record types, 9-byte keys
 * ================================================================
 * Uniform 9-byte key = 1-byte type tag + identifier, so every type
 * owns a contiguous prefix-browsable key band:
 *   Tag  Type                 Key (9 bytes)            Browse prefix
 *   'P'  PNR header           'P'+loc(6)+'00'          'P'   KEYLEN 1
 *   'S'  extra flight segment 'S'+loc(6)+seg(2)        'S'+loc KEYLEN 7
 *   'F'  frequent-flyer entry 'F'+loc(6)+seq(2)        'F'+loc KEYLEN 7
 *   'Q'  queue placement      'Q'+qno(1)+loc(6)+' '    'Q'+qno KEYLEN 2
 *
 * Records are FIXED-WIDTH columns (LEFT(f,n) pack / STRIP(SUBSTR(..),'T')
 * unpack) -- never pipe-delimited: '|' is a forbidden EBCDIC-037 glyph
 * and every record is echoed to a 3270 screen. No line-feed bytes.
 *
 * The 'sabre' file AUTO-CREATES on the first WRITE (same store
 * behaviour as CHATLOG in chat.rexx) -- no files.conf / DEFINE CLUSTER.
 *
 * Locators are minted from ASSIGN entropy + RANDOM (a bricks builtin),
 * A-Z0-9 only with confusable I,O,0,1 dropped, made collision-safe by
 * a DUPREC (EIBRESP=14) re-mint retry on WRITE -- never an in-memory
 * counter (state resets every turn).
 *
 * Lock rule: every READ UPDATE -> REWRITE pair runs inside one task
 * turn (input already in hand), never straddling a RECEIVE MAP. Every
 * STARTBR is closed with ENDBR before any update on the same file.
 */

ADDRESS CICS

EXEC CICS ASSIGN USERID(USR) TERMID(TRM) SCREENHT(SCRH) END-EXEC
USR = LEFT(STRIP(USR), 8)
IF STRIP(USR) = '' THEN USR = 'ANONYM'
TRM = LEFT(STRIP(TRM), 4)
IF SCRH >= 43 THEN DO
  MAPNAME = 'BOOKM4'
  NVIS    = 35
END
ELSE DO
  MAPNAME = 'BOOKM2'
  NVIS    = 18
END

/* Reference data (static tables) rebuilt every turn -- cheap, NOT
 * carried in the COMMAREA. */
CALL INIT_TABLES

/* ----- COLD ENTRY ------------------------------------------------ */
IF EIBCALEN = 0 THEN DO
  VER    = '1'
  AGENT  = ''
  AUTH   = '0'
  CURPNR = ''
  OFFS   = 0
  NCAND  = 0
  QDATE  = ''
  QROUTE = ''
  CAND.0 = 0
  HIST.0 = 0
  CALL APPEND 'SABRE CRS READY. SIGN IN WITH SIA*nnnnn  (HELP for cmds)'
  CALL SERIALIZE
  CALL PAINT 'ERASE'
  EXEC CICS RETURN TRANSID('BOOK') COMMAREA(STATE) END-EXEC
  EXIT
END

/* ----- RE-ENTRY -------------------------------------------------- */
STATE = DFHCOMMAREA
CALL DESERIALIZE

EXEC CICS RECEIVE MAP(MAPNAME) END-EXEC
RR  = EIBRESP                                 /* 0 NORMAL, 36 MAPFAIL */
AID = C2X(EIBAID)

/* PF3 -- bare RETURN, end the chain (drop to bare TRANSID prompt). */
IF AID = 'F3' THEN DO
  EXEC CICS RETURN END-EXEC
  EXIT
END

/* CLEAR -- repaint unchanged and keep the chain alive. */
IF AID = '6D' THEN DO
  CALL SERIALIZE
  CALL PAINT 'ERASE'
  EXEC CICS RETURN TRANSID('BOOK') COMMAREA(STATE) END-EXEC
  EXIT
END

/* EOC (EIBRESP=6, the first RECEIVE of a chained task) or MAPFAIL
 * (EIBRESP=36, nothing typed) -> treat the command field as empty.
 * Otherwise read the typed command from the CMD field. */
IF RR = 6 | RR = 36 THEN CMDIN = ''
ELSE CMDIN = STRIP(MAP.CMD)

/* PF7/PF8 page the transcript; ENTER (and any stray non-PF AID) runs
 * the typed command -- the chat.rexx idiom. NOTE: go3270's ENTER AID is
 * 0x7D, so we DON'T branch on a hard-coded ENTER hex; the OTHERWISE
 * fall-through processes ENTER regardless of 7D/7F. PF3 and CLEAR(6D)
 * were already handled above and never reach here. */
ENDFLAG = 0
SELECT
  WHEN AID = 'F7' THEN CALL SCROLL_UP
  WHEN AID = 'F8' THEN CALL SCROLL_DOWN
  OTHERWISE DO                                 /* ENTER (0x7D) and others */
    IF CMDIN \= '' THEN DO
      CALL APPEND '> ' || CMDIN
      CALL DISPATCH CMDIN
      OFFS = 0
    END
  END
END

/* SO* (or any handler) can request a bare RETURN to end the chain. */
IF ENDFLAG = 1 THEN DO
  CALL SERIALIZE
  CALL PAINT 'ERASE'
  EXEC CICS RETURN END-EXEC
  EXIT
END

CALL SERIALIZE
CALL PAINT 'ERASE'
EXEC CICS RETURN TRANSID('BOOK') COMMAREA(STATE) END-EXEC
EXIT


/* ================================================================ */
/* TOP-LEVEL SCROLL + PAINT                                          */
/* ================================================================ */

SCROLL_UP: PROCEDURE EXPOSE OFFS NVIS HIST.
  MAXOFF = HIST.0 - NVIS
  IF MAXOFF < 0 THEN MAXOFF = 0
  OFFS = OFFS + NVIS
  IF OFFS > MAXOFF THEN OFFS = MAXOFF
  RETURN

SCROLL_DOWN: PROCEDURE EXPOSE OFFS NVIS
  OFFS = OFFS - NVIS
  IF OFFS < 0 THEN OFFS = 0
  RETURN

/* Build the SCR. stem and SEND it. MODE is 'ERASE' (only mode used). */
PAINT: PROCEDURE EXPOSE MAPNAME NVIS OFFS HIST. AGENT AUTH SCRH
  PARSE ARG MODE
  SCR. = ''
  SCR.CLOCK  = TIME()
  IF AUTH = '1' THEN SCR.AGTID = STRIP(AGENT)
  ELSE SCR.AGTID = '(not signed in)'
  /* Mirror the newest '***' transcript line onto the red STATUS line so
   * errors stand out; otherwise leave STATUS blank. */
  SCR.STATUS = ''
  IF HIST.0 > 0 THEN DO
    LIDX = HIST.0
    LAST = HIST.LIDX
    IF LEFT(LAST, 3) = '***' THEN SCR.STATUS = LEFT(LAST, 78)
  END
  SCR.FOOTER = 'ENTER=cmd  PF7=up  PF8=down  PF3=exit  HELP=cmds'
  CALL POPULATE_ROWS
  EXEC CICS SEND MAP(MAPNAME) FROM(SCR.) ERASE END-EXEC
  /* Sized variant absent -> fall back to the 24x80 BOOKM2. */
  IF EIBRESP = 36 THEN DO
    MAPNAME = 'BOOKM2'
    NVIS    = 18
    SCR.ROW19 = ''
    SCR.ROW20 = ''
    SCR.ROW21 = ''
    SCR.ROW22 = ''
    SCR.ROW23 = ''
    SCR.ROW24 = ''
    SCR.ROW25 = ''
    SCR.ROW26 = ''
    SCR.ROW27 = ''
    SCR.ROW28 = ''
    SCR.ROW29 = ''
    SCR.ROW30 = ''
    SCR.ROW31 = ''
    SCR.ROW32 = ''
    SCR.ROW33 = ''
    SCR.ROW34 = ''
    SCR.ROW35 = ''
    CALL POPULATE_ROWS
    EXEC CICS SEND MAP(MAPNAME) FROM(SCR.) ERASE END-EXEC
  END
  RETURN

/* Newest line at the BOTTOM visible row, honoring OFFS (lines above
 * newest visible). The line at index HIST.0 is the most recent. Empty
 * rows at the top mean "no transcript that far back". */
POPULATE_ROWS: PROCEDURE EXPOSE NVIS OFFS HIST. SCR.
  /* Index of the line shown on the BOTTOM visible row. */
  BOTTOM = HIST.0 - OFFS
  IF BOTTOM < 0 THEN BOTTOM = 0
  DO J = 1 TO NVIS
    ROWNAME = 'SCR.ROW' || RIGHT(J, 2, '0')
    HISTIDX = BOTTOM - NVIS + J
    IF HISTIDX > 0 & HISTIDX <= HIST.0 THEN DO
      LINE = HIST.HISTIDX
      CALL VALUE ROWNAME, LEFT(LINE, 78)
    END
    ELSE CALL VALUE ROWNAME, ''
  END
  RETURN


/* ================================================================ */
/* COMMAREA SERIALIZE / DESERIALIZE                                 */
/* ================================================================ */

/* Pack header + CANDS + SCROLL into STATE. Cap SCROLL to the last 60
 * lines and the whole STATE to a safe bound by dropping oldest lines. */
SERIALIZE: PROCEDURE EXPOSE STATE VER AGENT AUTH CURPNR OFFS NCAND,
           QDATE QROUTE CAND. HIST.
  /* Fixed-width, DELIMITER-FREE layout. bricks REXX has no 'NN'X hex
   * literals, so binary separators (0x01..0x04) cannot be produced --
   * every region is therefore a run of fixed-width slots addressed by
   * SUBSTR on DESERIALIZE. Layout:
   *   header 38 bytes | NC candidates x 64 bytes | NH lines x 78 bytes
   * NC <= 15 (availability cap) and NH <= 60, so STATE stays < 6KB. */
  NC = CAND.0
  IF NC > 99 THEN NC = 99
  /* Keep only the last 60 transcript lines. */
  FIRST = HIST.0 - 60 + 1
  IF FIRST < 1 THEN FIRST = 1
  NH = HIST.0 - FIRST + 1
  IF NH < 0 THEN NH = 0
  HDR = LEFT(VER,1) || LEFT(AGENT,8) || LEFT(AUTH,1) || LEFT(CURPNR,6),
        || RIGHT(NC,3,'0') || RIGHT(NH,3,'0') || RIGHT(OFFS,3,'0'),
        || LEFT(QDATE,6) || LEFT(QROUTE,7)
  HDR = LEFT(HDR, 38)
  /* CANDS region: NC fixed 64-byte slots. */
  CB = ''
  DO I = 1 TO NC
    CB = CB || LEFT(CAND.I, 64)
  END
  /* SCROLL region: NH fixed 78-byte slots (POPULATE_ROWS re-pads). */
  SB = ''
  DO I = FIRST TO HIST.0
    SB = SB || LEFT(STRIP(HIST.I,'T'), 78)
  END
  STATE = HDR || CB || SB
  RETURN

/* Unpack STATE into the header vars + CAND. + HIST. stems. */
DESERIALIZE: PROCEDURE EXPOSE STATE VER AGENT AUTH CURPNR OFFS NCAND,
             QDATE QROUTE CAND. HIST.
  /* Fixed-offset header (38 bytes); see SERIALIZE for the layout. Each
   * numeric field is guarded with DATATYPE so a short/blank COMMAREA can
   * never feed an empty string into arithmetic ("not numeric"). */
  VER    = SUBSTR(STATE,1,1)
  AGENT  = STRIP(SUBSTR(STATE,2,8),'T')
  AUTH   = SUBSTR(STATE,10,1)
  CURPNR = STRIP(SUBSTR(STATE,11,6),'T')
  NCT    = STRIP(SUBSTR(STATE,17,3))
  IF \DATATYPE(NCT,'W') THEN NCT = 0
  NCAND  = NCT + 0
  NHT    = STRIP(SUBSTR(STATE,20,3))
  IF \DATATYPE(NHT,'W') THEN NHT = 0
  NH     = NHT + 0
  OFT    = STRIP(SUBSTR(STATE,23,3))
  IF \DATATYPE(OFT,'W') THEN OFT = 0
  OFFS   = OFT + 0
  QDATE  = STRIP(SUBSTR(STATE,26,6),'T')
  QROUTE = STRIP(SUBSTR(STATE,32,7),'T')
  IF AUTH = '' THEN AUTH = '0'
  /* CANDS region: NCAND fixed 64-byte slots after the 38-byte header. */
  CAND.0 = NCAND
  DO I = 1 TO NCAND
    CAND.I = STRIP(SUBSTR(STATE, 38 + (I-1)*64 + 1, 64), 'T')
  END
  /* SCROLL region: NH fixed 78-byte slots after the CANDS region. */
  SBASE = 38 + NCAND * 64
  HIST.0 = NH
  DO I = 1 TO NH
    HIST.I = STRIP(SUBSTR(STATE, SBASE + (I-1)*78 + 1, 78), 'T')
  END
  RETURN

/* Append one transcript line (split long text onto wrapped rows). */
APPEND: PROCEDURE EXPOSE HIST.
  /* ARG(1), not PARSE ARG -- PARSE collapses internal whitespace runs,
   * which would destroy the column alignment of seat-map / LIST rows.
   * ARG(1) returns the line verbatim. */
  TXT = ARG(1)
  /* Hard-wrap at 78 cols so nothing ever runs past the screen. */
  DO WHILE LENGTH(TXT) > 78
    N = HIST.0 + 1
    HIST.0 = N
    HIST.N = LEFT(TXT, 78)
    TXT = SUBSTR(TXT, 79)
  END
  N = HIST.0 + 1
  HIST.0 = N
  HIST.N = TXT
  /* Trim to last 60 lines so the COMMAREA stays bounded. */
  IF HIST.0 > 60 THEN DO
    DROPN = HIST.0 - 60
    DO I = 1 TO 60
      K = I + DROPN
      HIST.I = HIST.K
    END
    HIST.0 = 60
  END
  RETURN


/* ================================================================ */
/* DISPATCH -- ordered prefix cascade (mirrors sabre.rexx order)    */
/* ================================================================ */

DISPATCH: PROCEDURE EXPOSE AGENT AUTH CURPNR NCAND QDATE QROUTE,
          CAND. HIST. ENDFLAG USR TRM SCRH,
          airports. eqDesc. eqSeats. seatConfig. airlines.,
          flightNumRange. fareTypes. paxTypes.
  PARSE ARG RAW
  CMD = STRIP(TRANSLATE(RAW))                  /* uppercase + trim */
  IF CMD = '' THEN RETURN

  /* HELP */
  IF CMD = 'HELP' THEN DO
    CALL DO_HELP
    RETURN
  END

  /* SO* -- sign out, end the pseudo-conversational chain. */
  IF LEFT(CMD,3) = 'SO*' THEN DO
    CALL APPEND 'Agent sign out complete'
    AUTH    = '0'
    AGENT   = ''
    ENDFLAG = 1
    RETURN
  END

  /* SIA* -- sign in. */
  IF LEFT(CMD,4) = 'SIA*' THEN DO
    CALL DO_SIGNIN CMD
    RETURN
  END

  /* Sign-in gate: every functional command requires a signed-in agent. */
  IF AUTH \= '1' THEN DO
    CALL APPEND '*** SIGN IN FIRST (SIA*nnnnn)'
    RETURN
  END

  /* LEFT-prefix commands (longest / most specific first). */
  IF LEFT(CMD,2) = '4G' THEN DO
    CALL DO_4G CMD
    RETURN
  END
  IF LEFT(CMD,3) = 'WP/' THEN DO
    CALL DO_WP CMD
    RETURN
  END
  IF LEFT(CMD,2) = 'Q/' THEN DO
    CALL DO_QUEUE CMD
    RETURN
  END
  IF LEFT(CMD,2) = 'N/' THEN DO
    CALL DO_NAME CMD
    RETURN
  END
  IF LEFT(CMD,2) = 'FF' THEN DO
    CALL DO_FF CMD
    RETURN
  END
  IF LEFT(CMD,4) = 'W/EQ' THEN DO
    CALL DO_WEQ CMD
    RETURN
  END

  /* FIRST-token commands. */
  PARSE VAR CMD FIRST REST
  IF FIRST = 'PNR' THEN DO
    CALL DO_PNR REST
    RETURN
  END
  IF FIRST = 'SELL' THEN DO
    CALL DO_SELL REST
    RETURN
  END
  IF FIRST = 'BOOK' THEN DO
    CALL DO_SELL REST
    RETURN
  END
  IF FIRST = 'CANCEL' THEN DO
    CALL DO_CANCEL REST
    RETURN
  END
  IF FIRST = 'LIST' THEN DO
    CALL DO_LIST
    RETURN
  END

  /* OTHERWISE -- treat the whole line as an availability query. */
  CALL DO_AVAIL CMD
  RETURN


/* ================================================================ */
/* HANDLERS                                                         */
/* ================================================================ */

DO_HELP: PROCEDURE EXPOSE HIST.
  CALL APPEND 'QUERY FORMAT: 18OCT JFK ZRH (optional time: 9A)'
  CALL APPEND 'SELL <n> / BOOK <n>  Book candidate flight n'
  CALL APPEND 'PNR <loc>            Display booking details'
  CALL APPEND 'LIST                 List all PNRs on file'
  CALL APPEND 'CANCEL <loc>         Cancel a booking (soft)'
  CALL APPEND 'W/EQ*<code>          Filter flights by equipment'
  CALL APPEND 'FF<loc>              Display FF numbers for PNR'
  CALL APPEND 'FF<loc>/<num>        Add FF number to PNR'
  CALL APPEND 'FF<loc>/*            Delete FF numbers from PNR'
  CALL APPEND 'Q/C                  Display queue counts'
  CALL APPEND 'Q/P/<n>/<loc>        Place PNR in queue n'
  CALL APPEND 'WP/NI                Display alternate fare options'
  CALL APPEND 'WP/NCB <seg>         Price/book lowest fare for seg'
  CALL APPEND 'N/ADD-<seg> L/F TYP  Add passenger name to PNR'
  CALL APPEND 'N/CHG-<seg> L/F      Change passenger name'
  CALL APPEND '4G<n>*               Display seat map for segment n'
  CALL APPEND '4G<n>S<seat>         Assign a seat (e.g. 4G1S12A)'
  CALL APPEND 'SO*                  Sign out / exit'
  RETURN

DO_SIGNIN: PROCEDURE EXPOSE AGENT AUTH HIST.
  PARSE ARG CMD
  ID = STRIP(SUBSTR(CMD, 5))
  IF ID = '' THEN DO
    CALL APPEND '*** SIGN-IN REQUIRES AN ID (SIA*nnnnn)'
    RETURN
  END
  AGENT = LEFT(ID, 8)
  AUTH  = '1'
  CALL APPEND 'SIGN-IN ACCEPTED. AGENT ' || STRIP(AGENT)
  RETURN

/* --- Availability search: DATE FROM TO [TIME] ------------------- */
DO_AVAIL: PROCEDURE EXPOSE NCAND QDATE QROUTE CAND. HIST.,
          airports. eqDesc. eqSeats. airlines. flightNumRange.
  PARSE ARG CMD
  PARSE VAR CMD QDT QFR QTO QTM
  IF QDT = '' | QFR = '' | QTO = '' THEN DO
    CALL APPEND '*** Invalid query format. Use: DATE FROM TO and opt TIME'
    CALL APPEND '*** Example: 18OCT JFK ZRH 9A'
    RETURN
  END
  CALL ISVALIDAIRPORT QFR
  IF \RESULT THEN DO
    CALL APPEND '*** Invalid departure airport code: ' || QFR
    CALL APPEND '*** Use a valid 3-letter code (e.g. JFK, LHR, SIN)'
    RETURN
  END
  CALL ISVALIDAIRPORT QTO
  IF \RESULT THEN DO
    CALL APPEND '*** Invalid arrival airport code: ' || QTO
    CALL APPEND '*** Use a valid 3-letter code (e.g. JFK, LHR, SIN)'
    RETURN
  END
  IF QFR = QTO THEN DO
    CALL APPEND '*** Departure and arrival airports cannot be the same'
    RETURN
  END
  QDATE  = QDT
  QROUTE = QFR || '/' || QTO
  CALL GETAIRPORTNAME QFR
  ANMFR = RESULT
  CALL GETAIRPORTNAME QTO
  ANMTO = RESULT
  CALL APPEND 'Route: ' || QFR || ' (' || ANMFR || ')'
  CALL APPEND '       to ' || QTO || ' (' || ANMTO || ')'
  CALL GENERATEFLIGHTS QDT, QFR, QTO, QTM
  CALL DISPLAYFLIGHTS QDT, QFR, QTO, QTM
  RETURN

/* --- SELL / BOOK <n>: write a persisted PNR --------------------- */
DO_SELL: PROCEDURE EXPOSE AGENT CURPNR NCAND CAND. HIST. TRM,
         seatConfig. eqDesc.
  PARSE ARG REST
  NUM = STRIP(REST)
  IF \DATATYPE(NUM,'W') THEN DO
    CALL APPEND '*** Invalid flight number'
    RETURN
  END
  NUM = NUM + 0
  IF NUM < 1 | NUM > CAND.0 THEN DO
    CALL APPEND '*** Invalid flight number (1-' || CAND.0 || ')'
    RETURN
  END
  CANROW = CAND.NUM
  PARSE VAR CANROW AIR FLT DEPC DEPD DEPT ARRT ARRC AVST EQMT
  /* First available seat for this equipment (1A by default). */
  CALL FIRSTSEAT EQMT
  SEAT = RESULT
  /* Build the PNR header record and write with DUPREC re-mint. */
  WDONE = 0
  TRIES = 0
  LOC   = ''
  DO WHILE WDONE = 0 & TRIES < 20
    CALL MINT_LOCATOR
    LOC = RESULT
    CALL BUILD_PNR 'A', LOC, '/TBD', 'ADT', SEAT, AIR, FLT,,
         DEPC, ARRC, DEPD, DEPT, EQMT, ' ', 0, 1, AGENT
    REC = RESULT
    PKEY = 'P' || LOC || '00'
    EXEC CICS WRITE FILE('sabre') FROM(REC) RIDFLD(PKEY) END-EXEC
    RR = EIBRESP                            /* 0 NORMAL, 14 DUPREC */
    IF RR = 0 THEN WDONE = 1
    ELSE IF RR = 14 THEN TRIES = TRIES + 1   /* collision -- re-mint */
    ELSE DO
      CALL APPEND '*** SELL failed RESP=' || RR
      RETURN
    END
  END
  IF WDONE = 0 THEN DO
    CALL APPEND '*** SELL failed: could not mint unique locator'
    RETURN
  END
  CURPNR = LOC
  CALL APPEND 'BOOKED ' || LOC || ' /TBD SEAT ' || STRIP(SEAT),
              || ' -- use N/ADD-1 to set name'
  RETURN

/* --- PNR <loc>: read header + browse FF and extra segments ------ */
DO_PNR: PROCEDURE EXPOSE CURPNR HIST. fareTypes. paxTypes.
  PARSE ARG REST
  LOC = LEFT(STRIP(REST), 6)
  IF STRIP(LOC) = '' THEN DO
    CALL APPEND '*** PNR requires a locator (PNR <loc>)'
    RETURN
  END
  CALL NORMLOC LOC
  LOC = RESULT
  PKEY = 'P' || LOC || '00'
  EXEC CICS READ FILE('sabre') INTO(REC) RIDFLD(PKEY) END-EXEC
  RR = EIBRESP                                 /* 0 NORMAL, 13 NOTFND */
  IF RR = 13 THEN DO
    CALL APPEND '*** PNR ' || STRIP(LOC) || ' not found.'
    RETURN
  END
  IF RR \= 0 THEN DO
    CALL APPEND '*** PNR read failed RESP=' || RR
    RETURN
  END
  CURPNR = LOC
  CALL SHOW_PNR REC
  /* Extra segments: browse 'S'+loc prefix. */
  CALL SHOW_SEGS LOC
  /* Frequent-flyer entries: browse 'F'+loc prefix. */
  CALL SHOW_FFS LOC
  RETURN

/* --- LIST: browse every PNR header ------------------------------ */
DO_LIST: PROCEDURE EXPOSE HIST.
  CALL APPEND 'LOC    ST PAX                  FLIGHT       SEAT'
  HK = 'P'
  EXEC CICS STARTBR FILE('sabre') RIDFLD(HK) GENERIC KEYLENGTH(1) END-EXEC
  RR = EIBRESP                                 /* 0 NORMAL */
  IF RR \= 0 THEN DO
    /* 12 FILENOTFOUND (no sabre file yet), 13 NOTFND, 20 ENDFILE -> empty. */
    IF RR = 12 | RR = 13 | RR = 20 THEN CALL APPEND 'No PNRs on file.'
    ELSE CALL APPEND '*** LIST failed RESP=' || RR
    RETURN
  END
  N = 0
  DONE = 0
  DO WHILE DONE = 0
    EXEC CICS READNEXT FILE('sabre') INTO(REC) RIDFLD(KEY) END-EXEC
    RR = EIBRESP                               /* 0 NORMAL, 20 ENDFILE */
    IF RR \= 0 THEN DONE = 1
    ELSE DO
      ST  = SUBSTR(REC,1,1)
      LC  = STRIP(SUBSTR(REC,2,6),'T')
      PAX = STRIP(SUBSTR(REC,8,24),'T')
      AIR = STRIP(SUBSTR(REC,39,4),'T')
      FLT = STRIP(SUBSTR(REC,43,4),'T')
      SEAT= STRIP(SUBSTR(REC,35,4),'T')
      LINE = LEFT(LC,6) || ' ' || LEFT(ST,2) || LEFT(PAX,20),
             || ' ' || LEFT(AIR || ' ' || FLT, 12) || ' ' || LEFT(SEAT,4)
      CALL APPEND LEFT(LINE, 78)
      N = N + 1
    END
  END
  EXEC CICS ENDBR FILE('sabre') END-EXEC
  IF N = 0 THEN CALL APPEND 'No PNRs on file.'
  ELSE CALL APPEND N || ' PNR(s) listed.'
  RETURN

/* --- CANCEL <loc> [PURGE]: soft cancel or hard purge ------------ */
DO_CANCEL: PROCEDURE EXPOSE CURPNR HIST.
  PARSE ARG REST
  PARSE VAR REST LOCRAW MODE
  CALL NORMLOC LEFT(STRIP(LOCRAW), 6)
  LOC = RESULT
  MODE = STRIP(TRANSLATE(MODE))
  IF STRIP(LOC) = '' THEN DO
    CALL APPEND '*** CANCEL requires a locator (CANCEL <loc>)'
    RETURN
  END
  IF MODE = 'PURGE' THEN DO
    CALL CANCEL_PURGE LOC
    RETURN
  END
  PKEY = 'P' || LOC || '00'
  EXEC CICS READ FILE('sabre') INTO(REC) RIDFLD(PKEY) UPDATE END-EXEC
  RR = EIBRESP                                 /* 0 NORMAL, 13 NOTFND */
  IF RR = 13 THEN DO
    CALL APPEND '*** PNR ' || STRIP(LOC) || ' not found.'
    RETURN
  END
  IF RR \= 0 THEN DO
    CALL APPEND '*** CANCEL read failed RESP=' || RR
    RETURN
  END
  REC = OVERLAY('X', REC, 1, 1)                /* STATUS = X (cancelled) */
  EXEC CICS REWRITE FILE('sabre') FROM(REC) END-EXEC
  RR = EIBRESP                                 /* 0 NORMAL, 16 INVREQ */
  IF RR \= 0 THEN DO
    CALL APPEND '*** CANCEL rewrite failed RESP=' || RR
    RETURN
  END
  CALL APPEND 'CANCELLED ' || STRIP(LOC) || ' (status X, still listed)'
  RETURN

/* Hard purge: delete the header + cascade-delete FF and seg bands. */
CANCEL_PURGE: PROCEDURE EXPOSE HIST.
  PARSE ARG LOC
  PKEY = 'P' || LOC || '00'
  EXEC CICS DELETE FILE('sabre') RIDFLD(PKEY) END-EXEC
  RR = EIBRESP                                 /* 0 NORMAL, 13 NOTFND */
  IF RR = 13 THEN DO
    CALL APPEND '*** PNR ' || STRIP(LOC) || ' not found.'
    RETURN
  END
  IF RR \= 0 THEN DO
    CALL APPEND '*** PURGE failed RESP=' || RR
    RETURN
  END
  FPFX = 'F' || LOC
  EXEC CICS DELETE FILE('sabre') RIDFLD(FPFX) GENERIC KEYLENGTH(7) END-EXEC
  SPFX = 'S' || LOC
  EXEC CICS DELETE FILE('sabre') RIDFLD(SPFX) GENERIC KEYLENGTH(7) END-EXEC
  CALL APPEND 'PURGED ' || STRIP(LOC) || ' and all related records.'
  RETURN

/* --- 4G: seat map display or seat assignment -------------------- */
DO_4G: PROCEDURE EXPOSE CURPNR HIST. seatConfig. eqSeats. eqDesc.
  PARSE ARG CMD
  BODY = SUBSTR(CMD, 3)                         /* after '4G' */
  SPOS = POS('S', BODY)
  IF SPOS > 0 THEN DO
    /* Assignment: 4G<seg>S<seat> */
    SEGTXT  = SUBSTR(BODY, 1, SPOS - 1)
    SEATRAW = STRIP(SUBSTR(BODY, SPOS + 1))
    IF SEGTXT = '' THEN SEG = 1
    ELSE SEG = SEGTXT
    IF \DATATYPE(SEG,'W') THEN DO
      CALL APPEND '*** Invalid segment number'
      RETURN
    END
    CALL ASSIGN_SEAT SEATRAW
    RETURN
  END
  /* Display map: 4G<seg>* */
  CALL SEATMAP
  RETURN

ASSIGN_SEAT: PROCEDURE EXPOSE CURPNR HIST. seatConfig. eqDesc.
  PARSE ARG SEATRAW
  IF CURPNR = '' THEN DO
    CALL APPEND '*** NO ACTIVE PNR - DISPLAY PNR FIRST'
    RETURN
  END
  /* Split seat into row digits + letter (e.g. 12A). */
  I = 1
  DO I = 1 TO LENGTH(SEATRAW)
    IF \DATATYPE(SUBSTR(SEATRAW,I,1),'W') THEN LEAVE
  END
  IF I = 1 | I > LENGTH(SEATRAW) THEN DO
    CALL APPEND '*** Invalid seat format - use ROW+LETTER (e.g. 12A)'
    RETURN
  END
  SROW = SUBSTR(SEATRAW, 1, I-1) + 0
  SLET = SUBSTR(SEATRAW, I)
  PKEY = 'P' || CURPNR || '00'
  EXEC CICS READ FILE('sabre') INTO(REC) RIDFLD(PKEY) UPDATE END-EXEC
  RR = EIBRESP                                 /* 0 NORMAL, 13 NOTFND */
  IF RR = 13 THEN DO
    CALL APPEND '*** PNR ' || STRIP(CURPNR) || ' NOT FOUND'
    RETURN
  END
  IF RR \= 0 THEN DO
    CALL APPEND '*** Seat read failed RESP=' || RR
    RETURN
  END
  EQMT = STRIP(SUBSTR(REC, 64, 4), 'T')
  SEATCFG = seatConfig.EQMT
  PARSE VAR SEATCFG ROWS '|' LAYOUT '|' EXITR '|',
        FIRSTR '|' WHEELR '|' BASSR '|' BLOCKS
  IF ROWS = '' THEN DO
    CALL APPEND '*** Invalid equipment type: ' || EQMT
    /* release the lock we hold by REWRITE-ing unchanged. */
    EXEC CICS REWRITE FILE('sabre') FROM(REC) END-EXEC
    RETURN
  END
  IF SROW < 1 | SROW > (ROWS + 0) THEN DO
    CALL APPEND '*** Invalid row ' || SROW || ' for ' || eqDesc.EQMT
    EXEC CICS REWRITE FILE('sabre') FROM(REC) END-EXEC
    RETURN
  END
  IF POS(SLET, LAYOUT) = 0 THEN DO
    CALL APPEND '*** Invalid seat letter ' || SLET || ' for ' || eqDesc.EQMT
    EXEC CICS REWRITE FILE('sabre') FROM(REC) END-EXEC
    RETURN
  END
  NEWSEAT = SROW || SLET
  IF WORDPOS(NEWSEAT, BLOCKS) > 0 THEN DO
    CALL APPEND '*** Seat ' || NEWSEAT || ' is blocked'
    EXEC CICS REWRITE FILE('sabre') FROM(REC) END-EXEC
    RETURN
  END
  REC = OVERLAY(LEFT(NEWSEAT, 4), REC, 35, 4)  /* SEAT field */
  EXEC CICS REWRITE FILE('sabre') FROM(REC) END-EXEC
  RR = EIBRESP                                 /* 0 NORMAL, 16 INVREQ */
  IF RR \= 0 THEN DO
    CALL APPEND '*** Seat rewrite failed RESP=' || RR
    RETURN
  END
  CALL APPEND 'Seat changed to ' || NEWSEAT || ' for ' || STRIP(CURPNR)
  RETURN

/* Generated seat map for the current PNR's primary flight. */
SEATMAP: PROCEDURE EXPOSE CURPNR HIST. seatConfig. eqSeats. eqDesc.
  IF CURPNR = '' THEN DO
    CALL APPEND '*** NO ACTIVE PNR - DISPLAY PNR FIRST'
    RETURN
  END
  PKEY = 'P' || CURPNR || '00'
  EXEC CICS READ FILE('sabre') INTO(REC) RIDFLD(PKEY) END-EXEC
  RR = EIBRESP                                 /* 0 NORMAL, 13 NOTFND */
  IF RR = 13 THEN DO
    CALL APPEND '*** PNR ' || STRIP(CURPNR) || ' NOT FOUND'
    RETURN
  END
  IF RR \= 0 THEN DO
    CALL APPEND '*** Seat map read failed RESP=' || RR
    RETURN
  END
  AIR  = STRIP(SUBSTR(REC,39,4),'T')
  FLT  = STRIP(SUBSTR(REC,43,4),'T')
  DEPD = STRIP(SUBSTR(REC,53,6),'T')
  CURS = STRIP(SUBSTR(REC,35,4),'T')
  EQMT = STRIP(SUBSTR(REC,64,4),'T')
  SEATCFG = seatConfig.EQMT
  PARSE VAR SEATCFG ROWS '|' LAYOUT '|' EXITR '|',
        FIRSTR '|' WHEELR '|' BASSR '|' BLOCKS
  IF ROWS = '' THEN DO
    CALL APPEND '*** Invalid equipment type: ' || EQMT
    RETURN
  END
  ROWS = ROWS + 0
  CALL APPEND 'SEAT MAP FOR ' || AIR || FLT || ' ' || eqDesc.EQMT
  CALL APPEND 'DATE: ' || DEPD || '  ASSIGNED: ' || CURS
  /* Column header line. */
  COLH = '   '
  DO C = 1 TO LENGTH(LAYOUT)
    COLH = COLH || ' ' || SUBSTR(LAYOUT, C, 1)
  END
  CALL APPEND COLH
  /* Seat rows. */
  DO R = 1 TO ROWS
    RSTR = RIGHT(R, 2) || ' '
    DO C = 1 TO LENGTH(LAYOUT)
      CH = SUBSTR(LAYOUT, C, 1)
      IF CH = ' ' THEN DO
        RSTR = RSTR || '  '
      END
      ELSE DO
        SEATC = R || CH
        STAT = 'A'                              /* available */
        IF CURS = SEATC THEN STAT = 'X'         /* this PNR's seat */
        IF WORDPOS(SEATC, BLOCKS) > 0 & STAT = 'A' THEN STAT = 'M'
        IF WORDPOS(R, WHEELR) > 0 & STAT = 'A' THEN STAT = 'W'
        IF WORDPOS(R, BASSR) > 0 & STAT = 'A' THEN STAT = 'C'
        IF WORDPOS(R, EXITR) > 0 & STAT = 'A' THEN STAT = 'E'
        IF WORDPOS(R, FIRSTR) > 0 & STAT = 'A' THEN STAT = 'F'
        RSTR = RSTR || ' ' || STAT
      END
    END
    CALL APPEND LEFT(RSTR, 78)
  END
  CALL APPEND 'A=AVAIL X=OCC E=EXIT F=FIRST W=WHEELCHAIR C=BASSINET M=MIDBLK'
  RETURN

/* --- FF: add / delete / display frequent-flyer numbers ---------- */
DO_FF: PROCEDURE EXPOSE HIST.
  PARSE ARG CMD
  BODY = SUBSTR(CMD, 3)                         /* after 'FF' */
  PARSE VAR BODY LOCPART '/' FFNUM
  CALL NORMLOC LEFT(STRIP(LOCPART), 6)
  LOC = RESULT
  FFNUM = STRIP(FFNUM)
  IF STRIP(LOC) = '' THEN DO
    CALL APPEND '*** FF requires a locator (FF<loc>)'
    RETURN
  END
  /* PNR must exist. */
  PKEY = 'P' || LOC || '00'
  EXEC CICS READ FILE('sabre') INTO(REC) RIDFLD(PKEY) END-EXEC
  RR = EIBRESP                                 /* 0 NORMAL, 13 NOTFND */
  IF RR = 13 THEN DO
    CALL APPEND '*** PNR ' || STRIP(LOC) || ' not found'
    RETURN
  END
  IF RR \= 0 THEN DO
    CALL APPEND '*** FF read failed RESP=' || RR
    RETURN
  END
  IF FFNUM = '' THEN DO
    CALL SHOW_FFS LOC
    RETURN
  END
  IF FFNUM = '*' THEN DO
    CALL FF_DELETE LOC
    RETURN
  END
  CALL FF_ADD LOC, FFNUM
  RETURN

FF_ADD: PROCEDURE EXPOSE HIST.
  PARSE ARG LOC, FFNUM
  FFAIR = LEFT(FFNUM, 2)
  REC = LEFT(FFNUM, 12) || LEFT(FFAIR, 2)
  REC = LEFT(REC, 40)
  SEQ = 1
  WDONE = 0
  DO WHILE WDONE = 0 & SEQ <= 99
    FKEY = 'F' || LOC || RIGHT(SEQ, 2, '0')
    EXEC CICS WRITE FILE('sabre') FROM(REC) RIDFLD(FKEY) END-EXEC
    RR = EIBRESP                               /* 0 NORMAL, 14 DUPREC */
    IF RR = 0 THEN WDONE = 1
    ELSE IF RR = 14 THEN SEQ = SEQ + 1          /* bump seq */
    ELSE DO
      CALL APPEND '*** FF add failed RESP=' || RR
      RETURN
    END
  END
  IF WDONE = 0 THEN CALL APPEND '*** FF add failed: too many entries'
  ELSE CALL APPEND 'FF ' || FFNUM || ' (' || STRIP(FFAIR) || ') added to ',
                   || STRIP(LOC)
  RETURN

FF_DELETE: PROCEDURE EXPOSE HIST.
  PARSE ARG LOC
  FPFX = 'F' || LOC
  EXEC CICS DELETE FILE('sabre') RIDFLD(FPFX) GENERIC KEYLENGTH(7) END-EXEC
  RR = EIBRESP                                 /* 0 NORMAL, 13 NOTFND */
  IF RR = 13 THEN CALL APPEND 'No FF numbers stored for ' || STRIP(LOC)
  ELSE IF RR \= 0 THEN CALL APPEND '*** FF delete failed RESP=' || RR
  ELSE CALL APPEND 'FF numbers deleted for ' || STRIP(LOC)
  RETURN

/* Browse and display the FF band for one locator. */
SHOW_FFS: PROCEDURE EXPOSE HIST.
  PARSE ARG LOC
  FPFX = 'F' || LOC
  EXEC CICS STARTBR FILE('sabre') RIDFLD(FPFX) GENERIC KEYLENGTH(7) END-EXEC
  RR = EIBRESP                                 /* 0 NORMAL, 13/20=none */
  IF RR \= 0 THEN RETURN
  N = 0
  DONE = 0
  DO WHILE DONE = 0
    EXEC CICS READNEXT FILE('sabre') INTO(REC) RIDFLD(KEY) END-EXEC
    RR = EIBRESP                               /* 0 NORMAL, 20 ENDFILE */
    IF RR \= 0 THEN DONE = 1
    ELSE DO
      FFNUM = STRIP(SUBSTR(REC,1,12),'T')
      FFAIR = STRIP(SUBSTR(REC,13,2),'T')
      CALL APPEND '   FF: ' || FFNUM || ' (' || FFAIR || ')'
      N = N + 1
    END
  END
  EXEC CICS ENDBR FILE('sabre') END-EXEC
  IF N = 0 THEN CALL APPEND '   No FF numbers stored for ' || STRIP(LOC)
  RETURN

/* Browse and display extra segments for one locator. */
SHOW_SEGS: PROCEDURE EXPOSE HIST.
  PARSE ARG LOC
  SPFX = 'S' || LOC
  EXEC CICS STARTBR FILE('sabre') RIDFLD(SPFX) GENERIC KEYLENGTH(7) END-EXEC
  RR = EIBRESP                                 /* 0 NORMAL, 13/20=none */
  IF RR \= 0 THEN RETURN
  DONE = 0
  DO WHILE DONE = 0
    EXEC CICS READNEXT FILE('sabre') INTO(REC) RIDFLD(KEY) END-EXEC
    RR = EIBRESP                               /* 0 NORMAL, 20 ENDFILE */
    IF RR \= 0 THEN DONE = 1
    ELSE DO
      AIR  = STRIP(SUBSTR(REC,1,4),'T')
      FLT  = STRIP(SUBSTR(REC,5,4),'T')
      DEPC = STRIP(SUBSTR(REC,9,3),'T')
      ARRC = STRIP(SUBSTR(REC,12,3),'T')
      CALL APPEND '   SEG: ' || AIR || ' ' || FLT || ' ' || DEPC || '/' || ARRC
    END
  END
  EXEC CICS ENDBR FILE('sabre') END-EXEC
  RETURN

/* --- Q/ queue commands ------------------------------------------ */
DO_QUEUE: PROCEDURE EXPOSE HIST.
  PARSE ARG CMD
  PARSE VAR CMD 'Q/' QCMD REST
  IF QCMD = 'C' THEN DO
    CALL QUEUE_COUNTS
    RETURN
  END
  IF LEFT(QCMD, 2) = 'P/' THEN DO
    /* Q/P/<n>/<loc> */
    PARSE VAR CMD 'Q/P/' QNO '/' LOCRAW
    QNO = STRIP(QNO)
    CALL NORMLOC LEFT(STRIP(LOCRAW), 6)
    LOC = RESULT
    IF \DATATYPE(QNO,'W') | QNO < 1 | QNO > 5 THEN DO
      CALL APPEND '*** Invalid queue number (1-5)'
      RETURN
    END
    IF STRIP(LOC) = '' THEN DO
      CALL APPEND '*** Queue placement requires a locator'
      RETURN
    END
    /* PNR must exist. */
    PKEY = 'P' || LOC || '00'
    EXEC CICS READ FILE('sabre') INTO(REC) RIDFLD(PKEY) END-EXEC
    RR = EIBRESP                               /* 0 NORMAL, 13 NOTFND */
    IF RR = 13 THEN DO
      CALL APPEND '*** PNR ' || STRIP(LOC) || ' not found'
      RETURN
    END
    IF RR \= 0 THEN DO
      CALL APPEND '*** Queue read failed RESP=' || RR
      RETURN
    END
    QREC = LEFT(LOC, 6) || LEFT(DATE('S'), 8)
    QREC = LEFT(QREC, 40)
    QKEY = 'Q' || QNO || LOC || ' '
    EXEC CICS WRITE FILE('sabre') FROM(QREC) RIDFLD(QKEY) END-EXEC
    RR = EIBRESP                               /* 0 NORMAL, 14 DUPREC */
    IF RR = 0 THEN CALL APPEND 'PNR ' || STRIP(LOC) || ' placed in queue ' || QNO
    ELSE IF RR = 14 THEN CALL APPEND 'PNR ' || STRIP(LOC) || ' already in queue ' || QNO
    ELSE CALL APPEND '*** Queue placement failed RESP=' || RR
    RETURN
  END
  CALL APPEND '*** Invalid queue command (Q/C or Q/P/<n>/<loc>)'
  RETURN

/* Tally queue placements by browsing the whole 'Q' band. */
QUEUE_COUNTS: PROCEDURE EXPOSE HIST.
  Q.1 = 0
  Q.2 = 0
  Q.3 = 0
  Q.4 = 0
  Q.5 = 0
  HK = 'Q'
  EXEC CICS STARTBR FILE('sabre') RIDFLD(HK) GENERIC KEYLENGTH(1) END-EXEC
  RR = EIBRESP                                 /* 0 NORMAL, 13/20=none */
  IF RR = 0 THEN DO
    DONE = 0
    DO WHILE DONE = 0
      EXEC CICS READNEXT FILE('sabre') INTO(REC) RIDFLD(KEY) END-EXEC
      RR = EIBRESP                             /* 0 NORMAL, 20 ENDFILE */
      IF RR \= 0 THEN DONE = 1
      ELSE DO
        QN = SUBSTR(KEY, 2, 1)
        IF DATATYPE(QN,'W') THEN DO
          IF QN >= 1 & QN <= 5 THEN Q.QN = Q.QN + 1
        END
      END
    END
    EXEC CICS ENDBR FILE('sabre') END-EXEC
  END
  CALL APPEND 'Queue Counts:'
  CALL APPEND '  1 GENERAL   : ' || Q.1 || ' PNRs'
  CALL APPEND '  2 TICKETING : ' || Q.2 || ' PNRs'
  CALL APPEND '  3 SCHEDULE  : ' || Q.3 || ' PNRs'
  CALL APPEND '  4 WAITLIST  : ' || Q.4 || ' PNRs'
  CALL APPEND '  5 SPECIAL   : ' || Q.5 || ' PNRs'
  RETURN

/* --- WP/ pricing ------------------------------------------------ */
DO_WP: PROCEDURE EXPOSE CURPNR HIST. fareTypes.
  PARSE ARG CMD
  PARSE VAR CMD 'WP/' PCMD REST
  PCMD = STRIP(PCMD)
  REST = STRIP(REST)
  IF PCMD = 'NI' THEN DO
    CALL APPEND 'Searching for alternative fares...'
    CALL SHOW_FARES
    RETURN
  END
  IF PCMD = 'NCB' THEN DO
    IF \DATATYPE(REST,'W') THEN DO
      CALL APPEND '*** Invalid segment number'
      RETURN
    END
    CALL APPEND 'Searching for lowest available fare...'
    CALL SHOW_FARES
    /* Stamp the lowest (Q) fare onto the current PNR. */
    IF CURPNR = '' THEN DO
      CALL APPEND '*** NO ACTIVE PNR - DISPLAY PNR FIRST'
      RETURN
    END
    CALL GETRANDOMNUM 100, 1000
    PRICE = RESULT
    PKEY = 'P' || CURPNR || '00'
    EXEC CICS READ FILE('sabre') INTO(REC) RIDFLD(PKEY) UPDATE END-EXEC
    RR = EIBRESP                               /* 0 NORMAL, 13 NOTFND */
    IF RR = 13 THEN DO
      CALL APPEND '*** PNR ' || STRIP(CURPNR) || ' not found'
      RETURN
    END
    IF RR \= 0 THEN DO
      CALL APPEND '*** Price read failed RESP=' || RR
      RETURN
    END
    REC = OVERLAY('Q', REC, 68, 1)             /* FARECLS */
    REC = OVERLAY(RIGHT(PRICE, 7), REC, 69, 7) /* FAREAMT */
    EXEC CICS REWRITE FILE('sabre') FROM(REC) END-EXEC
    RR = EIBRESP                               /* 0 NORMAL, 16 INVREQ */
    IF RR \= 0 THEN DO
      CALL APPEND '*** Price rewrite failed RESP=' || RR
      RETURN
    END
    CALL APPEND 'BOOKED Q class fare $' || PRICE || '.00 on ' || STRIP(CURPNR)
    RETURN
  END
  CALL APPEND '*** Invalid pricing command (WP/NI or WP/NCB <seg>)'
  RETURN

SHOW_FARES: PROCEDURE EXPOSE HIST. fareTypes.
  DO I = 1 TO WORDS('Y B M Q')
    FARE = WORD('Y B M Q', I)
    CALL GETRANDOMNUM 100, 1000
    PRICE = RESULT
    CALL APPEND '  ' || FARE || ' class (' || fareTypes.FARE || '): $' || PRICE || '.00'
  END
  RETURN

/* --- N/ passenger name add / change ----------------------------- */
DO_NAME: PROCEDURE EXPOSE CURPNR HIST. paxTypes.
  PARSE ARG CMD
  PARSE VAR CMD 'N/' NCMD REST
  PARSE VAR NCMD CMDTYPE '-' PAXNUM
  CMDTYPE = STRIP(CMDTYPE)
  PAXNUM  = STRIP(PAXNUM)
  IF CMDTYPE \= 'ADD' & CMDTYPE \= 'CHG' THEN DO
    CALL APPEND '*** Invalid name command (N/ADD-<n> or N/CHG-<n>)'
    RETURN
  END
  IF \DATATYPE(PAXNUM,'W') THEN DO
    CALL APPEND '*** Invalid passenger number'
    RETURN
  END
  IF CURPNR = '' THEN DO
    CALL APPEND '*** NO ACTIVE PNR - DISPLAY PNR FIRST'
    RETURN
  END
  PARSE VAR REST LASTNM '/' FIRSTNM PTYPE
  LASTNM  = STRIP(LASTNM)
  FIRSTNM = STRIP(FIRSTNM)
  PTYPE   = STRIP(PTYPE)
  IF LASTNM = '' THEN DO
    CALL APPEND '*** Name required as LAST/FIRST'
    RETURN
  END
  IF CMDTYPE = 'ADD' THEN DO
    IF PTYPE = '' THEN PTYPE = 'ADT'
    IF WORDPOS(PTYPE, 'ADT CHD INF SNR STU') = 0 THEN DO
      CALL APPEND '*** Invalid passenger type (ADT CHD INF SNR STU)'
      RETURN
    END
  END
  NEWNAME = LASTNM || '/' || FIRSTNM
  PKEY = 'P' || CURPNR || '00'
  EXEC CICS READ FILE('sabre') INTO(REC) RIDFLD(PKEY) UPDATE END-EXEC
  RR = EIBRESP                                 /* 0 NORMAL, 13 NOTFND */
  IF RR = 13 THEN DO
    CALL APPEND '*** PNR ' || STRIP(CURPNR) || ' not found'
    RETURN
  END
  IF RR \= 0 THEN DO
    CALL APPEND '*** Name read failed RESP=' || RR
    RETURN
  END
  REC = OVERLAY(LEFT(NEWNAME, 24), REC, 8, 24)  /* PAXNAME */
  IF CMDTYPE = 'ADD' THEN REC = OVERLAY(LEFT(PTYPE, 3), REC, 32, 3)
  EXEC CICS REWRITE FILE('sabre') FROM(REC) END-EXEC
  RR = EIBRESP                                 /* 0 NORMAL, 16 INVREQ */
  IF RR \= 0 THEN DO
    CALL APPEND '*** Name rewrite failed RESP=' || RR
    RETURN
  END
  IF CMDTYPE = 'ADD' THEN,
    CALL APPEND 'Added passenger ' || NEWNAME || ' (' || paxTypes.PTYPE || ') to ' || STRIP(CURPNR)
  ELSE CALL APPEND 'Changed passenger name to ' || NEWNAME || ' in ' || STRIP(CURPNR)
  RETURN

/* --- W/EQ equipment query --------------------------------------- */
DO_WEQ: PROCEDURE EXPOSE HIST. eqDesc. eqSeats.
  PARSE ARG CMD
  IF LENGTH(CMD) > 5 & SUBSTR(CMD,5,1) = '*' THEN DO
    EQ = STRIP(TRANSLATE(SUBSTR(CMD,6)))
    /* An unset stem tail resolves to its uppercased name, so an unknown
     * code makes eqDesc.EQ = 'EQDESC.<EQ>' (bricks has no SYMBOL()). */
    NAME = eqDesc.EQ
    IF NAME = 'EQDESC.' || EQ THEN NAME = 'Unknown'
    CALL APPEND 'Equipment ' || EQ || ' - ' || NAME
    RETURN
  END
  CALL APPEND 'Available Equipment Types:'
  DO I = 1 TO WORDS('A320 B738 B789 A350 B77W B747 B767 B757 MD981')
    EQ = WORD('A320 B738 B789 A350 B77W B747 B767 B757 MD981', I)
    CALL APPEND '  ' || LEFT(EQ,5) || ' - ' || LEFT(eqDesc.EQ,20) || RIGHT(eqSeats.EQ,4) || ' seats'
  END
  RETURN


/* ================================================================ */
/* PNR RECORD HELPERS                                               */
/* ================================================================ */

/* Pack a PNR header record (fixed-width, ~93 bytes, padded to 120). */
BUILD_PNR: PROCEDURE
  PARSE ARG ST, LOC, PAX, PTYPE, SEAT, AIR, FLT, DEPC, ARRC, DEPD,,
        DEPT, EQMT, FCLS, FAMT, SEGC, AGT
  REC = LEFT(ST,1) || LEFT(LOC,6) || LEFT(PAX,24) || LEFT(PTYPE,3),
        || LEFT(SEAT,4) || LEFT(AIR,4) || LEFT(FLT,4) || LEFT(DEPC,3),
        || LEFT(ARRC,3) || LEFT(DEPD,6) || LEFT(DEPT,5) || LEFT(EQMT,4),
        || LEFT(FCLS,1) || RIGHT(FAMT,7) || RIGHT(SEGC,2,'0'),
        || LEFT(AGT,8) || LEFT(DATE('S'),8)
  RETURN LEFT(REC, 120)

/* Render a PNR header record into transcript lines. */
SHOW_PNR: PROCEDURE EXPOSE HIST. fareTypes. paxTypes.
  /* ARG(1), not PARSE ARG -- PARSE collapses internal whitespace runs
   * (strings.Fields/Join), which would scramble the fixed-width record's
   * column alignment. ARG(1) returns the argument verbatim. */
  REC = ARG(1)
  ST   = SUBSTR(REC,1,1)
  LOC  = STRIP(SUBSTR(REC,2,6),'T')
  PAX  = STRIP(SUBSTR(REC,8,24),'T')
  PTYP = STRIP(SUBSTR(REC,32,3),'T')
  SEAT = STRIP(SUBSTR(REC,35,4),'T')
  AIR  = STRIP(SUBSTR(REC,39,4),'T')
  FLT  = STRIP(SUBSTR(REC,43,4),'T')
  DEPC = STRIP(SUBSTR(REC,47,3),'T')
  ARRC = STRIP(SUBSTR(REC,50,3),'T')
  DEPD = STRIP(SUBSTR(REC,53,6),'T')
  DEPT = STRIP(SUBSTR(REC,59,5),'T')
  EQMT = STRIP(SUBSTR(REC,64,4),'T')
  FCLS = STRIP(SUBSTR(REC,68,1),'T')
  FAMT = STRIP(SUBSTR(REC,69,7))
  STDESC = 'ACTIVE'
  IF ST = 'X' THEN STDESC = 'CANCELLED'
  IF ST = 'T' THEN STDESC = 'TICKETED'
  L = LOC || ' ' || STDESC || ' ' || PAX
  CALL APPEND LEFT(L, 78)
  L = '   ' || AIR || ' ' || FLT || ' ' || DEPC || ' ' || DEPD || ' ',
      || DEPT || ' ' || ARRC || ' SEAT ' || SEAT || ' ' || EQMT
  CALL APPEND LEFT(L, 78)
  IF PTYP \= '' THEN CALL APPEND '   Type: ' || paxTypes.PTYP
  IF FCLS \= '' THEN CALL APPEND '   Fare: ' || FCLS || ' (' || fareTypes.FCLS || ') $' || STRIP(FAMT) || '.00'
  RETURN

/* Normalize a typed locator: uppercase, trim, pad to 6. */
NORMLOC: PROCEDURE
  PARSE ARG LOC
  LOC = STRIP(TRANSLATE(LOC))
  RETURN LEFT(LOC, 6)

/* Mint a 6-char locator: 3 letters + 3 digits, no confusables.
 * RANDOM (a bricks builtin) draws each character; uniqueness is
 * guaranteed by the DUPREC (EIBRESP=14) re-mint retry on WRITE -- not by
 * an in-memory counter, since dialogue state resets every turn. The
 * task number / terminal id (ASSIGN entropy) further spread the draws
 * because GETRANDOMNUM-style callers mix the long clock into RANDOM. */
MINT_LOCATOR: PROCEDURE
  LETS = 'ABCDEFGHJKLMNPQRSTUVWXYZ'             /* no I, O */
  DIGS = '23456789'                             /* no 0, 1 */
  LOC = ''
  DO K = 1 TO 3
    IDX = RANDOM(1, LENGTH(LETS))
    LOC = LOC || SUBSTR(LETS, IDX, 1)
  END
  DO K = 1 TO 3
    IDX = RANDOM(1, LENGTH(DIGS))
    LOC = LOC || SUBSTR(DIGS, IDX, 1)
  END
  RETURN LOC

/* First available seat for an equipment type (top-left, e.g. 1A). */
FIRSTSEAT: PROCEDURE EXPOSE seatConfig.
  PARSE ARG EQMT
  SEATCFG = seatConfig.EQMT
  PARSE VAR SEATCFG ROWS '|' LAYOUT '|' REST
  IF LAYOUT = '' THEN RETURN '1A'
  DO C = 1 TO LENGTH(LAYOUT)
    CH = SUBSTR(LAYOUT, C, 1)
    IF CH \= ' ' THEN RETURN '1' || CH
  END
  RETURN '1A'


/* ================================================================ */
/* FLIGHT GENERATION + STATIC TABLES (ported from sabre.rexx)       */
/* ================================================================ */

DISPLAYFLIGHTS: PROCEDURE EXPOSE NCAND CAND. HIST. FLIGHTS.
  PARSE ARG QDATE, QFR, QTO, QTM
  CALL APPEND QDATE || ' ' || QFR || '/' || QTO || ' ---------------------'
  CALL APPEND ' #  ARLN  FLTN  DEPC/ARVC  DEPT   ARRT   AVST  EQTYP'
  CAND.0 = 0
  IF FLIGHTS.0 = 0 THEN DO
    CALL APPEND 'NO FLIGHTS AVAILABLE FOR THAT QUERY'
    NCAND = 0
    RETURN
  END
  IDX = 0
  DO I = 1 TO FLIGHTS.0
    FLROW = FLIGHTS.I
    PARSE VAR FLROW AIR FLT DEPC DEPD DEPT ARRT ARRC AVST EQMT
    MATCH = 1
    IF QTM \= '' THEN DO
      PARSE VAR DEPT HR 3 MN 5 AP 6
      IF \DATATYPE(HR,'W') | \DATATYPE(MN,'W') THEN MATCH = 0
      ELSE DO
        MINS = (HR * 60) + MN
        IF AP = 'P' & HR \= 12 THEN MINS = MINS + (12 * 60)
        IF AP = 'A' & HR = 12 THEN MINS = 0
        THR = SUBSTR(QTM, 1, LENGTH(QTM)-1)
        TAP = RIGHT(QTM, 1)
        IF \DATATYPE(THR,'W') THEN MATCH = 0
        ELSE DO
          TMINS = (THR * 60)
          IF TAP = 'P' & THR \= 12 THEN TMINS = TMINS + (12 * 60)
          IF TAP = 'A' & THR = 12 THEN TMINS = 0
          IF ABS(MINS - TMINS) > 120 THEN MATCH = 0
        END
      END
    END
    IF MATCH = 1 THEN DO
      IDX = IDX + 1
      CAND.IDX = AIR FLT DEPC DEPD DEPT ARRT ARRC AVST EQMT
      OUT = RIGHT(IDX, 2) || '  ' || LEFT(AIR,5) || ' ' || LEFT(FLT,5),
            || ' ' || LEFT(DEPC || '/' || ARRC, 9) || '  ' || LEFT(DEPT,6),
            || ' ' || LEFT(ARRT,6) || ' ' || LEFT(AVST,5) || ' ' || EQMT
      CALL APPEND LEFT(OUT, 78)
    END
  END
  CAND.0 = IDX
  NCAND  = IDX
  IF IDX = 0 THEN CALL APPEND 'NO FLIGHTS AVAILABLE FOR THAT QUERY'
  ELSE CALL APPEND 'Use SELL <n> to book.'
  RETURN

GENERATEFLIGHTS: PROCEDURE EXPOSE FLIGHTS. airlines. flightNumRange. eqSeats.
  PARSE ARG QDATE, DEPAPT, ARRAPT, TIMEFILTER
  FLIGHTS.0 = 0
  USEDNUMS = ''
  CALL GETROUTEEQUIPMENT DEPAPT, ARRAPT
  ROUTEEQ = RESULT
  NUMEQ = WORDS(ROUTEEQ)
  DO A = 1 TO airlines.0
    AIRLINE = airlines.A
    FNR = flightNumRange.AIRLINE
    PARSE VAR FNR MINFLT MAXFLT
    CALL GETRANDOMNUM 2, 5
    NUMFLIGHTS = RESULT
    DO F = 1 TO NUMFLIGHTS
      CALL GETUNIQUEFLIGHTNUM AIRLINE, MINFLT, MAXFLT, USEDNUMS
      FLTSTR = RESULT
      USEDNUMS = USEDNUMS AIRLINE || FLTSTR
      CALL GETRANDOMNUM 360, 1380
      DEPTIME = RESULT
      DEPTIME = (DEPTIME % 5) * 5
      CALL GETRANDOMNUM 1, NUMEQ
      EQIDX = RESULT
      EQTYPE = WORD(ROUTEEQ, EQIDX)
      CALL GETFLIGHTTIME DEPAPT, ARRAPT
      FLIGHTDUR = RESULT
      ARRTIME = DEPTIME + FLIGHTDUR
      CALL FORMATTIME DEPTIME
      DEPTSTR = RESULT
      CALL FORMATTIME ARRTIME
      ARRTSTR = RESULT
      MAXSEATS = eqSeats.EQTYPE
      IF \DATATYPE(MAXSEATS,'W') THEN MAXSEATS = 150
      MINSEATS = TRUNC(MAXSEATS * 0.2)
      MAXAVAIL = TRUNC(MAXSEATS * 0.95)
      CALL GETRANDOMNUM MINSEATS, MAXAVAIL
      AVAILSEATS = RESULT
      NIDX = FLIGHTS.0 + 1
      FLIGHTS.0 = NIDX
      FLIGHTS.NIDX = AIRLINE FLTSTR DEPAPT QDATE DEPTSTR ARRTSTR ARRAPT AVAILSEATS EQTYPE
    END
  END
  /* Sort by departure time. */
  IF FLIGHTS.0 > 1 THEN DO
    DO I = 1 TO FLIGHTS.0 - 1
      DO J = I + 1 TO FLIGHTS.0
        FLROWI = FLIGHTS.I
        FLROWJ = FLIGHTS.J
        PARSE VAR FLROWI AI FI DCI DDI DPI ATI ACI AVI EI
        PARSE VAR FLROWJ AJ FJ DCJ DDJ DPJ ATJ ACJ AVJ EJ
        IF DPI > DPJ THEN DO
          TEMP = FLIGHTS.I
          FLIGHTS.I = FLIGHTS.J
          FLIGHTS.J = TEMP
        END
      END
    END
  END
  RETURN

GETROUTEEQUIPMENT: PROCEDURE
  PARSE ARG DEP, ARR
  CALL GETAIRPORTREGION DEP
  DEPR = RESULT
  CALL GETAIRPORTREGION ARR
  ARRR = RESULT
  IF DEPR = ARRR THEN DO
    IF DEPR = 'NA' THEN RETURN 'A320 A320 B738 B738 B738'
    RETURN 'A320 B738 A320 B738 A320'
  END
  IF (DEPR = 'NA' & ARRR = 'EU') | (DEPR = 'EU' & ARRR = 'NA') THEN,
    RETURN 'B789 A350 B77W B789 A350'
  IF (DEPR = 'NA' & ARRR = 'AP') | (DEPR = 'AP' & ARRR = 'NA') THEN,
    RETURN 'B789 B77W B77W B789 B77W'
  RETURN 'B789 A350 B77W A350 B789'

GETAIRPORTREGION: PROCEDURE
  PARSE ARG CODE
  NA = 'JFK LAX ORD DFW DEN SFO LAS SEA MCO EWR MIA PHX IAH BOS MSP DTW FLL CLT LGA BWI SLC YYZ YVR YUL'
  EU = 'LHR CDG AMS FRA IST MAD BCN LGW MUC FCO SVO DME DUB ZRH CPH OSL ARN VIE BRU MXP'
  AP = 'PEK HND HKG ICN BKK SIN CGK KUL DEL BOM SYD MEL AKL KIX TPE MNL CAN PVG NRT'
  ME = 'DXB DOH AUH CAI JNB CPT TLV BAH RUH JED MCT'
  LA = 'GRU MEX BOG LIM SCL GIG EZE PTY CUN UIO'
  IF WORDPOS(CODE, NA) > 0 THEN RETURN 'NA'
  IF WORDPOS(CODE, EU) > 0 THEN RETURN 'EU'
  IF WORDPOS(CODE, AP) > 0 THEN RETURN 'AP'
  IF WORDPOS(CODE, ME) > 0 THEN RETURN 'ME'
  IF WORDPOS(CODE, LA) > 0 THEN RETURN 'LA'
  RETURN 'OT'

GETFLIGHTTIME: PROCEDURE
  PARSE ARG DEP, ARR
  IF LENGTH(DEP) = 3 & LENGTH(ARR) = 3 THEN DO
    CALL GETRANDOMNUM 60, 720
    RETURN 60 + RESULT
  END
  RETURN 120

FORMATTIME: PROCEDURE
  PARSE ARG MINS
  IF \DATATYPE(MINS,'W') THEN RETURN '0000A'
  HOURS = MINS % 60
  MINUTES = MINS // 60
  AP = 'A'
  IF HOURS >= 12 THEN DO
    AP = 'P'
    IF HOURS > 12 THEN HOURS = HOURS - 12
  END
  IF HOURS = 0 THEN HOURS = 12
  RETURN RIGHT(HOURS,2,'0') || RIGHT(MINUTES,2,'0') || AP

GETRANDOMNUM: PROCEDURE
  PARSE ARG MIN, MAX
  NUMERIC DIGITS 20
  COUNTER = RANDOM(1, 10000)
  T = TIME('L')
  SEED = (RIGHT(T, 8) * COUNTER) // 1000000
  RETURN TRUNC(MIN + (SEED // (MAX - MIN + 1)))

GETUNIQUEFLIGHTNUM: PROCEDURE
  PARSE ARG AIRLINE, MINFLT, MAXFLT, USEDNUMS
  DO FOREVER
    DO I = 1 TO 100 ; NOP ; END
    CALL GETRANDOMNUM MINFLT, MAXFLT
    FLIGHTNUM = RESULT
    FLIGHTSTR = RIGHT(FLIGHTNUM, 4, '0')
    IF WORDPOS(AIRLINE || FLIGHTSTR, USEDNUMS) = 0 THEN RETURN FLIGHTSTR
  END

ISVALIDAIRPORT: PROCEDURE EXPOSE airports.
  PARSE ARG CODE
  IF CODE = '' THEN RETURN 0
  IF LENGTH(CODE) \= 3 THEN RETURN 0
  /* An unset stem tail resolves (REXX NOVALUE) to its own uppercased
   * name, e.g. airports.ZZZ -> 'AIRPORTS.ZZZ'. A real airport's value
   * never equals that literal, so the comparison is the membership test
   * (bricks has no SYMBOL() builtin). */
  IF VALUE('airports.' || CODE) = 'AIRPORTS.' || CODE THEN RETURN 0
  RETURN 1

GETAIRPORTNAME: PROCEDURE EXPOSE airports.
  PARSE ARG CODE
  V = VALUE('airports.' || CODE)
  IF V = 'AIRPORTS.' || CODE THEN RETURN ''
  RETURN V


/* ================================================================ */
/* STATIC REFERENCE TABLES (rebuilt each turn, NOT in the COMMAREA) */
/* ================================================================ */

INIT_TABLES: PROCEDURE EXPOSE airports. eqDesc. eqSeats. seatConfig.,
             airlines. flightNumRange. fareTypes. paxTypes.
  /* North America */
  airports.ATL = 'Atlanta Hartsfield'
  airports.LAX = 'Los Angeles Intl'
  airports.ORD = 'Chicago OHare'
  airports.DFW = 'Dallas Fort Worth'
  airports.DEN = 'Denver Intl'
  airports.JFK = 'New York Kennedy'
  airports.SFO = 'San Francisco Intl'
  airports.LAS = 'Las Vegas McCarran'
  airports.SEA = 'Seattle-Tacoma'
  airports.MCO = 'Orlando Intl'
  airports.EWR = 'Newark Liberty'
  airports.MIA = 'Miami Intl'
  airports.PHX = 'Phoenix Sky Harbor'
  airports.IAH = 'Houston Bush'
  airports.BOS = 'Boston Logan'
  airports.MSP = 'Minneapolis-St Paul'
  airports.DTW = 'Detroit Metro'
  airports.FLL = 'Fort Lauderdale'
  airports.CLT = 'Charlotte Douglas'
  airports.LGA = 'New York LaGuardia'
  airports.BWI = 'Baltimore Washington'
  airports.SLC = 'Salt Lake City'
  airports.YYZ = 'Toronto Pearson'
  airports.YVR = 'Vancouver Intl'
  airports.YUL = 'Montreal Trudeau'
  /* Europe */
  airports.LHR = 'London Heathrow'
  airports.CDG = 'Paris de Gaulle'
  airports.AMS = 'Amsterdam Schiphol'
  airports.FRA = 'Frankfurt Intl'
  airports.IST = 'Istanbul Intl'
  airports.MAD = 'Madrid Barajas'
  airports.BCN = 'Barcelona El Prat'
  airports.LGW = 'London Gatwick'
  airports.MUC = 'Munich Intl'
  airports.FCO = 'Rome Fiumicino'
  airports.SVO = 'Moscow Sheremetyevo'
  airports.DME = 'Moscow Domodedovo'
  airports.DUB = 'Dublin Intl'
  airports.ZRH = 'Zurich Intl'
  airports.CPH = 'Copenhagen Kastrup'
  airports.OSL = 'Oslo Gardermoen'
  airports.ARN = 'Stockholm Arlanda'
  airports.VIE = 'Vienna Intl'
  airports.BRU = 'Brussels Intl'
  airports.MXP = 'Milan Malpensa'
  /* Asia Pacific */
  airports.PEK = 'Beijing Capital'
  airports.HND = 'Tokyo Haneda'
  airports.DXB = 'Dubai Intl'
  airports.HKG = 'Hong Kong Intl'
  airports.ICN = 'Seoul Incheon'
  airports.BKK = 'Bangkok Suvarnabhumi'
  airports.SIN = 'Singapore Changi'
  airports.CGK = 'Jakarta Soekarno'
  airports.KUL = 'Kuala Lumpur Intl'
  airports.DEL = 'Delhi Indira Gandhi'
  airports.BOM = 'Mumbai Intl'
  airports.SYD = 'Sydney Kingsford'
  airports.MEL = 'Melbourne Intl'
  airports.AKL = 'Auckland Intl'
  airports.KIX = 'Osaka Kansai'
  airports.TPE = 'Taipei Taoyuan'
  airports.MNL = 'Manila Ninoy Aquino'
  airports.CAN = 'Guangzhou Baiyun'
  airports.PVG = 'Shanghai Pudong'
  airports.NRT = 'Tokyo Narita'
  /* Middle East and Africa */
  airports.DOH = 'Doha Hamad'
  airports.AUH = 'Abu Dhabi Intl'
  airports.CAI = 'Cairo Intl'
  airports.JNB = 'Johannesburg Tambo'
  airports.CPT = 'Cape Town Intl'
  airports.TLV = 'Tel Aviv Ben Gurion'
  airports.BAH = 'Bahrain Intl'
  airports.RUH = 'Riyadh King Khalid'
  airports.JED = 'Jeddah Abdulaziz'
  airports.MCT = 'Muscat Intl'
  /* Latin America */
  airports.GRU = 'Sao Paulo Guarulhos'
  airports.MEX = 'Mexico City Intl'
  airports.BOG = 'Bogota El Dorado'
  airports.LIM = 'Lima Jorge Chavez'
  airports.SCL = 'Santiago Intl'
  airports.GIG = 'Rio de Janeiro Galeao'
  airports.EZE = 'Buenos Aires Ezeiza'
  airports.PTY = 'Panama City Tocumen'
  airports.CUN = 'Cancun Intl'
  airports.UIO = 'Quito Intl'

  /* Equipment descriptions */
  eqDesc.A320 = 'Airbus A320-100'
  eqDesc.B738 = 'Boeing 737-800'
  eqDesc.B789 = 'Boeing 787-9'
  eqDesc.A350 = 'Airbus A350-100'
  eqDesc.B77W = 'Boeing 777-300ER'
  eqDesc.B747 = 'Boeing 747-800'
  eqDesc.B767 = 'Boeing 767-300'
  eqDesc.B757 = 'Boeing 757-200'
  eqDesc.MD981 = 'MD-8-81'

  /* Seat map configurations:
   * ROWS|LAYOUT|EXIT ROWS|FIRST CLASS ROWS|WHEELCHAIR|BASSINET|BLOCK */
  seatConfig.A320 = '27|ABC DEF|11 12|1-4|1 27|12|14B 14E'
  seatConfig.B738 = '28|ABC DEF|14 15|1-4|1 28|15|16B 16E'
  seatConfig.B789 = '42|ABC DEF GHJ|24 25|1-5|1 42|25|26E 26F'
  seatConfig.A350 = '44|ABC DEF GHJ|24 25|1-5|1 44|25|26E 26F'
  seatConfig.B77W = '51|ABC DEFG HJK|24 25|1-4|1 51|25|26E 26F'
  seatConfig.B747 = '58|ABC DEFG HJK|24 25|1-4|1 58|25|26E 26F'
  seatConfig.B767 = '34|ABC DEF GH|20 21|1-3|1 34|21|22D 22E'
  seatConfig.B757 = '25|ABC DEF|14 15|1-3|1 25|15|16B 16E'
  seatConfig.MD981 = '23|ABC DE|10 11|1-2|1 23|11|12B 12D'

  /* Seat counts per equipment type */
  eqSeats.A320 = 158
  eqSeats.B738 = 162
  eqSeats.B789 = 290
  eqSeats.A350 = 308
  eqSeats.B77W = 357
  eqSeats.B747 = 412
  eqSeats.B767 = 203
  eqSeats.B757 = 152
  eqSeats.MD981 = 109

  /* Airlines */
  airlines.1 = 'AAL'
  airlines.2 = 'DAL'
  airlines.3 = 'LH'
  airlines.0 = 3
  flightNumRange.AAL = '100 999'
  flightNumRange.DAL = '1000 1999'
  flightNumRange.LH = '400 799'

  /* Fares */
  fareTypes.Y = 'FULL'
  fareTypes.B = 'FLEX'
  fareTypes.M = 'ECON'
  fareTypes.Q = 'DISC'

  /* Passenger types */
  paxTypes.ADT = 'ADULT'
  paxTypes.CHD = 'CHILD'
  paxTypes.INF = 'INFANT'
  paxTypes.SNR = 'SENIOR'
  paxTypes.STU = 'STUDENT'
  RETURN
