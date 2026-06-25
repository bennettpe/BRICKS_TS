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
  /* Swissair boot splash -- scroll the embedded logo up from the bottom
   * once, BEFORE the READY prompt is painted. */
  CALL LOGO_INTRO
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
      /* SABRE-style combinability: a single line may hold several entries
       * separated by ',' -- run each in turn (no command uses a comma). */
      REMAIN = CMDIN
      DO WHILE REMAIN \= '' & ENDFLAG = 0
        CP = POS(',', REMAIN)
        IF CP = 0 THEN DO
          PART   = STRIP(REMAIN)
          REMAIN = ''
        END
        ELSE DO
          PART   = STRIP(LEFT(REMAIN, CP - 1))
          REMAIN = SUBSTR(REMAIN, CP + 1)
        END
        IF PART \= '' THEN DO
          CALL APPEND '> ' || PART
          CALL DISPATCH PART
        END
      END
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

/* Cold-start splash: scroll the Swissair logo up from the bottom of the
 * screen, once, before the welcome paint. The logo art is EMBEDDED here
 * (never read from disk -- logo.swissair is unavailable at run time).
 *
 * Frames are painted with SEND MAP ... DATAONLY: that is the only
 * fire-and-forget form (a plain SEND MAP blocks waiting for an AID). Each
 * frame sets every body row to a full 78-byte value so the partial paint
 * fully overwrites the previous frame (no ghosting), and blanks the chrome
 * fields so only the logo shows. DELAY FOR MILLISECS paces it. */
LOGO_INTRO: PROCEDURE EXPOSE MAPNAME NVIS HIST.
  LOGO.1  = ' '
  LOGO.2  = ' A27APR ZRHFRA 1900 SWISS'
  LOGO.3  = '                 SSAI'
  LOGO.4  = '                 AIRSWI'
  LOGO.5  = '                 SAIRSWI'
  LOGO.6  = '                 RSWISSAIR'
  LOGO.7  = '                 WISSWISAIRS                $'
  LOGO.8  = '     AIRSWISSAIRSWISSAIRSWISSAIRSWISSAIRSWISS   S   S'
  LOGO.9  = '     AIRSWISSAIRSWISSAIRSWISSAIRSWISSAIRSWISS   S   S'
  LOGO.10 = '                 SWISWISSAIR                $'
  LOGO.11 = '                 IRSWISSAI'
  LOGO.12 = '                 SAIRSWI                   S W I S S A I R'
  LOGO.13 = '                 ISSAIR              RESERVATION AND TICKETING SYSTEM'
  LOGO.14 = '                 SWISS                   '
  LOGO.0  = 14
  DLY = 55                                       /* ms per frame -- gentle    */
  /* Blank the chrome once (these stay set across the DATAONLY frames). */
  SCR. = ''
  SCR.TITLE  = LEFT('', 30)
  SCR.CLOCK  = LEFT('', 8)
  SCR.AGTLBL = LEFT('', 6)
  SCR.AGTID  = LEFT('', 18)
  SCR.STATUS = LEFT('', 78)
  SCR.PROMPT = LEFT('', 4)
  SCR.CMD    = LEFT('', 62)
  SCR.FOOTER = LEFT('', 60)
  /* Strip = NVIS blank rows then the logo. Slide the NVIS-row window DOWN
   * the strip so the logo rises UP the screen. STOP with the logo
   * BOTTOM-aligned -- exactly where it will sit in the transcript once the
   * logo lines (+ the READY line beneath) are appended below. Stopping
   * there means the welcome paint keeps the logo in place instead of
   * moving it. Screen row J shows logo line (P + J - NVIS); at P = LOGO.0+1
   * the last logo line lands on the row just above the (future) READY line. */
  PSTOP = LOGO.0 + 1
  DO P = 0 TO PSTOP
    DO J = 1 TO NVIS
      ROWNAME = 'SCR.ROW' || RIGHT(J, 2, '0')
      LIDX = (P + J) - NVIS                       /* logo line if 1..LOGO.0    */
      IF LIDX >= 1 & LIDX <= LOGO.0 THEN,
        CALL VALUE ROWNAME, LEFT(LOGO.LIDX, 78)
      ELSE CALL VALUE ROWNAME, LEFT('', 78)       /* 78 spaces -> overwrite    */
    END
    EXEC CICS SEND MAP(MAPNAME) FROM(SCR.) DATAONLY END-EXEC
    EXEC CICS DELAY FOR MILLISECS(DLY) END-EXEC
  END
  /* Brief beat on the settled logo, then COMMIT it to the transcript so it
   * STAYS on screen when the welcome/prompt paints over the splash (it then
   * scrolls away naturally as the operator works, like any banner). */
  EXEC CICS DELAY FOR MILLISECS(1000) END-EXEC
  DO I = 1 TO LOGO.0
    CALL APPEND LOGO.I
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
          flightNumRange. fareTypes. paxTypes.,
          cityCode. aptRegion. airlineName. routeMiles. regionMiles.
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
  /* W/ -- encode/decode reference (must follow W/EQ above). */
  IF LEFT(CMD,2) = 'W/' THEN DO
    CALL DO_W CMD
    RETURN
  END
  /* DD<citypair> -- mileage and elapsed flying time. */
  IF LEFT(CMD,2) = 'DD' & LENGTH(CMD) >= 8 THEN DO
    CALL DO_DD CMD
    RETURN
  END
  /* S<date><citypair> -- schedule/timetable (digit after S guards
   * against SO* / SIA* / SELL, whose 2nd char is a letter). */
  IF LEFT(CMD,1) = 'S' & LENGTH(CMD) >= 7,
     & DATATYPE(SUBSTR(CMD,2,1),'W') THEN DO
    CALL DO_SCHED CMD
    RETURN
  END
  /* Canonical city-pair availability 1<date><pair>[time][-mods].
   * WORDS=1 keeps the friendly '18OCT JFK ZRH' (3 words) on the
   * fall-through path to DO_AVAIL below. */
  IF LEFT(CMD,1) = '1' & WORDS(CMD) = 1 & LENGTH(CMD) >= 9 THEN DO
    CALL DO_AVAIL1 CMD
    RETURN
  END
  /* Canonical sell 0<line><class>[seg], e.g. 01Y1. */
  IF LEFT(CMD,1) = '0' & WORDS(CMD) = 1 & LENGTH(CMD) >= 2 THEN DO
    CALL DO_SELL0 CMD
    RETURN
  END
  /* PNR mandatory-field entries (annotate the active PNR). */
  IF LEFT(CMD,1) = '-' THEN DO
    CALL DO_NAMEDASH CMD
    RETURN
  END
  IF LEFT(CMD,1) = '9' & LENGTH(CMD) > 1 THEN DO
    CALL DO_PHONE CMD
    RETURN
  END
  IF LEFT(CMD,1) = '7' THEN DO
    CALL DO_TKT CMD
    RETURN
  END
  IF LEFT(CMD,1) = '6' THEN DO
    CALL DO_RCVD CMD
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
  IF FIRST = 'TTP' THEN DO
    CALL DO_TTP REST
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
  CALL APPEND 'TTP [<loc>]          Ticket the PNR (status A -> T)'
  CALL APPEND 'W/*<code>            Decode airport(3) or airline(2)'
  CALL APPEND 'W/-CC<city>          Encode city name to airport code'
  CALL APPEND 'W/EQ*<code>          Decode aircraft equipment type'
  CALL APPEND 'S<date><frto>        Flight schedule (e.g. S13JUNJFKZRH)'
  CALL APPEND '1<date><frto><tm>    Avail entry (e.g. 113JUNJFKZRH9A)'
  CALL APPEND '0<n><cls>            Sell line n in class (e.g. 01Y1)'
  CALL APPEND 'DD<frto>             Miles + flying time (e.g. DDJFKZRH)'
  CALL APPEND '-LAST/FIRST TITLE    PNR name field (e.g. -SMITH/JOHN MR)'
  CALL APPEND '9<phone>-<H/B/T>     PNR phone field (e.g. 9203555121-B)'
  CALL APPEND '7TAW<date>/          PNR ticketing field (e.g. 7TAW15JUN/)'
  CALL APPEND '6<name>              PNR received-from field (e.g. 6SMITH)'
  CALL APPEND 'FF<loc>              Display FF numbers for PNR'
  CALL APPEND 'FF<loc>/<num>        Add FF number to PNR'
  CALL APPEND 'FF<loc>/*            Delete FF numbers from PNR'
  CALL APPEND 'Q/C                  Display queue counts'
  CALL APPEND 'Q/P/<n>/<loc>        Place PNR in queue n'
  CALL APPEND 'WP/NI                Display alternate fare options'
  CALL APPEND 'WP/NCB <seg>         Price lowest fare (seg default 1)'
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
          airports. eqDesc. eqSeats. airlines. flightNumRange. aptRegion.
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

/* --- TTP [<loc>]: Ticket The PNR -- issue e-ticket, status A -> T. */
DO_TTP: PROCEDURE EXPOSE CURPNR HIST. fareTypes.
  PARSE ARG REST
  LOC = STRIP(REST)
  IF LOC = '' THEN LOC = STRIP(CURPNR)
  IF LOC = '' THEN DO
    CALL APPEND '*** NO ACTIVE PNR - DISPLAY (PNR <loc>) OR SELL FIRST'
    RETURN
  END
  CALL NORMLOC LEFT(LOC, 6)
  LOC = RESULT
  PKEY = 'P' || LOC || '00'
  EXEC CICS READ FILE('sabre') INTO(REC) RIDFLD(PKEY) UPDATE END-EXEC
  RR = EIBRESP                                 /* 0 NORMAL, 13 NOTFND */
  IF RR = 13 THEN DO
    CALL APPEND '*** PNR ' || STRIP(LOC) || ' not found.'
    RETURN
  END
  IF RR \= 0 THEN DO
    CALL APPEND '*** Ticket read failed RESP=' || RR
    RETURN
  END
  ST = SUBSTR(REC, 1, 1)
  IF ST = 'X' THEN DO
    CALL APPEND '*** PNR ' || STRIP(LOC) || ' is cancelled - cannot ticket'
    EXEC CICS REWRITE FILE('sabre') FROM(REC) END-EXEC
    RETURN
  END
  IF ST = 'T' THEN DO
    CALL APPEND '*** PNR ' || STRIP(LOC) || ' is already ticketed'
    EXEC CICS REWRITE FILE('sabre') FROM(REC) END-EXEC
    RETURN
  END
  PAX = STRIP(SUBSTR(REC, 8, 24), 'T')
  IF PAX = '' | PAX = '/TBD' THEN DO
    CALL APPEND '*** Add a passenger name first (-LAST/FIRST or N/ADD-1)'
    EXEC CICS REWRITE FILE('sabre') FROM(REC) END-EXEC
    RETURN
  END
  REC = OVERLAY('T', REC, 1, 1)                 /* STATUS = T (ticketed) */
  EXEC CICS REWRITE FILE('sabre') FROM(REC) END-EXEC
  RR = EIBRESP                                 /* 0 NORMAL, 16 INVREQ */
  IF RR \= 0 THEN DO
    CALL APPEND '*** Ticket rewrite failed RESP=' || RR
    RETURN
  END
  CURPNR = LOC
  FCLS = STRIP(SUBSTR(REC, 68, 1), 'T')
  FAMT = STRIP(SUBSTR(REC, 69, 7))
  IF FCLS = '' THEN,
    CALL APPEND 'ETKT ISSUED ' || STRIP(LOC) || ' - ' || PAX,
                || ' (unpriced - WP/NCB to fare)'
  ELSE CALL APPEND 'ETKT ISSUED ' || STRIP(LOC) || ' - ' || PAX || '  ',
                || FCLS || ' (' || fareTypes.FCLS || ') $' || FAMT || '.00'
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
    IF REST = '' THEN REST = '1'              /* default to segment 1 */
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

/* --- W/ encode & decode reference ------------------------------- */
DO_W: PROCEDURE EXPOSE HIST. airports. cityCode. airlineName.
  PARSE ARG CMD
  BODY = SUBSTR(CMD, 3)                          /* text after 'W/' */
  IF LEFT(BODY,1) = '*' THEN DO                  /* decode code -> name */
    KEY = STRIP(SUBSTR(BODY, 2))
    IF LENGTH(KEY) = 3 THEN DO                   /* 3 chars -> airport */
      CALL GETAIRPORTNAME KEY
      NM = RESULT
      IF NM = '' THEN CALL APPEND '*** Unknown airport code: ' || KEY
      ELSE CALL APPEND KEY || '  ' || NM
      RETURN
    END
    IF LENGTH(KEY) = 2 THEN DO                   /* 2 chars -> airline */
      CALL LOADAIRLINES
      CALL DECODE_AIRLINE KEY
      RETURN
    END
    CALL APPEND '*** W/* needs a 3-letter airport or 2-letter airline'
    RETURN
  END
  IF LEFT(BODY,3) = '-CC' THEN DO                /* encode city -> code */
    RAWCITY = STRIP(SUBSTR(BODY, 4))
    KEY = SPACE(TRANSLATE(RAWCITY), 0)           /* uppercase, drop spaces */
    IF KEY = '' THEN DO
      CALL APPEND '*** Usage: W/-CC<city name>'
      RETURN
    END
    CODES = VALUE('cityCode.' || KEY)
    IF CODES = 'CITYCODE.' || KEY THEN,
      CALL APPEND '*** No airport on file for city: ' || RAWCITY
    ELSE CALL APPEND RAWCITY || ' = ' || CODES
    RETURN
  END
  CALL APPEND '*** Use W/*<code> to decode or W/-CC<city> to encode'
  RETURN

DECODE_AIRLINE: PROCEDURE EXPOSE HIST. airlineName.
  PARSE ARG AL
  NM = VALUE('airlineName.' || AL)
  IF NM = 'AIRLINENAME.' || AL THEN,
    CALL APPEND '*** Unknown airline code: ' || AL
  ELSE CALL APPEND AL || '  ' || NM
  RETURN

/* --- DD<citypair> mileage and elapsed flying time --------------- */
DO_DD: PROCEDURE EXPOSE HIST. airports. aptRegion. routeMiles. regionMiles.
  PARSE ARG CMD
  PAIR = STRIP(SUBSTR(CMD, 3))
  IF LENGTH(PAIR) \= 6 THEN DO
    CALL APPEND '*** Usage: DD<from><to> (e.g. DDJFKZRH)'
    RETURN
  END
  QFR = LEFT(PAIR, 3)
  QTO = SUBSTR(PAIR, 4, 3)
  CALL ISVALIDAIRPORT QFR
  IF \RESULT THEN DO
    CALL APPEND '*** Invalid airport code: ' || QFR
    RETURN
  END
  CALL ISVALIDAIRPORT QTO
  IF \RESULT THEN DO
    CALL APPEND '*** Invalid airport code: ' || QTO
    RETURN
  END
  IF QFR = QTO THEN DO
    CALL APPEND '*** Airports must differ'
    RETURN
  END
  /* Curated route first, then the reverse pair. If both are unset MI
   * still holds the unset-tail literal -- the DATATYPE test below treats
   * that as "no curated distance" and drops to the region fallback. */
  MI = VALUE('routeMiles.' || QFR || QTO)
  IF MI = 'ROUTEMILES.' || QFR || QTO THEN,
    MI = VALUE('routeMiles.' || QTO || QFR)
  IF \DATATYPE(MI,'W') THEN DO                   /* region-pair fallback */
    CALL GETAIRPORTREGION QFR
    R1 = RESULT
    CALL GETAIRPORTREGION QTO
    R2 = RESULT
    MI = VALUE('regionMiles.' || R1 || R2)
    IF \DATATYPE(MI,'W') THEN MI = VALUE('regionMiles.' || R2 || R1)
    IF \DATATYPE(MI,'W') THEN MI = 3000
  END
  MINS = TRUNC(MI / 500 * 60)                    /* 500 mph avg, no trig */
  HRS = MINS % 60
  MM  = MINS // 60
  CALL APPEND QFR || '/' || QTO || '  ' || MI || ' MILES  EFT ',
              || HRS || 'H' || RIGHT(MM, 2, '0') || 'M'
  RETURN

/* --- S<date><citypair> schedule/timetable ----------------------- */
DO_SCHED: PROCEDURE EXPOSE HIST. airports. aptRegion. FLIGHTS.,
          airlines. flightNumRange. eqSeats.
  PARSE ARG CMD
  REST = SUBSTR(CMD, 2)                          /* text after 'S' */
  IF LENGTH(REST) < 7 THEN DO
    CALL APPEND '*** Usage: S<date><from><to> (e.g. S13JUNJFKZRH)'
    RETURN
  END
  PAIR = RIGHT(REST, 6)
  DT   = LEFT(REST, LENGTH(REST) - 6)
  QFR  = LEFT(PAIR, 3)
  QTO  = SUBSTR(PAIR, 4, 3)
  CALL ISVALIDAIRPORT QFR
  IF \RESULT THEN DO
    CALL APPEND '*** Invalid departure airport code: ' || QFR
    RETURN
  END
  CALL ISVALIDAIRPORT QTO
  IF \RESULT THEN DO
    CALL APPEND '*** Invalid arrival airport code: ' || QTO
    RETURN
  END
  IF QFR = QTO THEN DO
    CALL APPEND '*** Departure and arrival airports cannot be the same'
    RETURN
  END
  CALL GENERATEFLIGHTS DT, QFR, QTO, ''
  CALL APPEND 'SCHEDULE ' || DT || '  ' || QFR || '/' || QTO || '  DAILY'
  CALL APPEND 'ARLN FLT  DEP    ARR    EQ    DAYS'
  IF FLIGHTS.0 = 0 THEN DO
    CALL APPEND 'NO SCHEDULED SERVICE'
    RETURN
  END
  DO I = 1 TO FLIGHTS.0
    FLROW = FLIGHTS.I
    PARSE VAR FLROW AIR FLT DEPC DEPD DEPT ARRT ARRC AVST EQMT
    OUT = LEFT(AIR,4) || ' ' || LEFT(FLT,4) || ' ' || LEFT(DEPT,6),
          || ' ' || LEFT(ARRT,6) || ' ' || LEFT(EQMT,5) || ' 1234567'
    CALL APPEND LEFT(OUT, 78)
  END
  CALL APPEND FLIGHTS.0 || ' flight(s) scheduled.'
  RETURN

/* --- 1<date><pair><tm><-carr><-cls> canonical availability ------ */
DO_AVAIL1: PROCEDURE EXPOSE NCAND QDATE QROUTE CAND. HIST.,
           airports. eqDesc. eqSeats. airlines. flightNumRange. aptRegion.
  PARSE ARG CMD
  BODY = SUBSTR(CMD, 2)                          /* drop leading '1' */
  CLS  = ''
  CARR = ''
  DO WHILE POS('-', BODY) > 0                    /* peel -carr / -cls */
    P   = LASTPOS('-', BODY)
    MOD = SUBSTR(BODY, P + 1)
    BODY = LEFT(BODY, P - 1)
    IF LENGTH(MOD) = 1 THEN CLS = MOD
    ELSE CARR = MOD
  END
  QTM = ''
  LCH = RIGHT(BODY, 1)
  IF LCH = 'A' | LCH = 'P' THEN DO               /* trailing <digits>A/P */
    I = LENGTH(BODY) - 1
    DO WHILE I >= 1 & DATATYPE(SUBSTR(BODY, I, 1), 'W')
      I = I - 1
    END
    IF I <= LENGTH(BODY) - 2 THEN DO
      QTM  = SUBSTR(BODY, I + 1)
      BODY = LEFT(BODY, I)
    END
  END
  IF LENGTH(BODY) < 7 THEN DO
    CALL APPEND '*** Invalid availability entry (use 113JUNJFKZRH)'
    RETURN
  END
  PAIR = RIGHT(BODY, 6)
  DT   = LEFT(BODY, LENGTH(BODY) - 6)
  QFR  = LEFT(PAIR, 3)
  QTO  = SUBSTR(PAIR, 4, 3)
  IF CLS  \= '' THEN CALL APPEND 'Class of service requested: ' || CLS
  IF CARR \= '' THEN CALL APPEND 'Preferred carrier: ' || CARR
  QSTR = DT QFR QTO QTM
  CALL DO_AVAIL QSTR
  RETURN

/* --- 0<line><class>[seg] canonical sell ------------------------- */
DO_SELL0: PROCEDURE EXPOSE AGENT CURPNR NCAND CAND. HIST. TRM,
          seatConfig. eqDesc.
  PARSE ARG CMD
  BODY = SUBSTR(CMD, 2)                          /* drop leading '0' */
  I = 1
  DO WHILE I <= LENGTH(BODY) & DATATYPE(SUBSTR(BODY, I, 1), 'W')
    I = I + 1
  END
  LINE = LEFT(BODY, I - 1)
  CLS  = SUBSTR(BODY, I, 1)
  IF LINE = '' THEN DO
    CALL APPEND '*** Usage: 0<line><class>  (e.g. 01Y1)'
    RETURN
  END
  PREV = CURPNR
  CALL DO_SELL LINE
  /* Only stamp class when DO_SELL actually minted a NEW PNR. */
  IF CLS \= '' & CURPNR \= '' & CURPNR \= PREV THEN DO
    PKEY = 'P' || CURPNR || '00'
    EXEC CICS READ FILE('sabre') INTO(REC) RIDFLD(PKEY) UPDATE END-EXEC
    IF EIBRESP = 0 THEN DO
      REC = OVERLAY(CLS, REC, 68, 1)
      EXEC CICS REWRITE FILE('sabre') FROM(REC) END-EXEC
    END
  END
  RETURN

/* --- -LAST/FIRST TITLE  PNR name field -------------------------- */
DO_NAMEDASH: PROCEDURE EXPOSE CURPNR HIST.
  PARSE ARG CMD
  BODY = STRIP(SUBSTR(CMD, 2))                   /* text after '-' */
  PARSE VAR BODY LASTNM '/' FIRSTNM
  LASTNM  = STRIP(LASTNM)
  FIRSTNM = STRIP(FIRSTNM)
  IF LASTNM = '' | FIRSTNM = '' THEN DO
    CALL APPEND '*** Name required as -LAST/FIRST TITLE'
    RETURN
  END
  IF CURPNR = '' THEN DO
    CALL APPEND '*** NO ACTIVE PNR - DISPLAY OR SELL A PNR FIRST'
    RETURN
  END
  NEWNAME = LASTNM || '/' || FIRSTNM
  PKEY = 'P' || CURPNR || '00'
  EXEC CICS READ FILE('sabre') INTO(REC) RIDFLD(PKEY) UPDATE END-EXEC
  RR = EIBRESP
  IF RR = 13 THEN DO
    CALL APPEND '*** PNR ' || STRIP(CURPNR) || ' not found'
    RETURN
  END
  IF RR \= 0 THEN DO
    CALL APPEND '*** Name read failed RESP=' || RR
    RETURN
  END
  REC = OVERLAY(LEFT(NEWNAME, 24), REC, 8, 24)
  EXEC CICS REWRITE FILE('sabre') FROM(REC) END-EXEC
  IF EIBRESP \= 0 THEN DO
    CALL APPEND '*** Name rewrite failed RESP=' || EIBRESP
    RETURN
  END
  CALL APPEND 'Name ' || NEWNAME || ' set in ' || STRIP(CURPNR)
  RETURN

/* --- 9<digits>-<H/B/T>  PNR phone field ------------------------- */
DO_PHONE: PROCEDURE EXPOSE CURPNR HIST.
  PARSE ARG CMD
  BODY = STRIP(SUBSTR(CMD, 2))                   /* text after '9' */
  IF BODY = '' THEN DO
    CALL APPEND '*** Usage: 9<number>-<H/B/T>  (e.g. 9203555121-B)'
    RETURN
  END
  IF CURPNR = '' THEN DO
    CALL APPEND '*** NO ACTIVE PNR - DISPLAY OR SELL A PNR FIRST'
    RETURN
  END
  PKEY = 'P' || CURPNR || '00'
  EXEC CICS READ FILE('sabre') INTO(REC) RIDFLD(PKEY) UPDATE END-EXEC
  RR = EIBRESP
  IF RR = 13 THEN DO
    CALL APPEND '*** PNR ' || STRIP(CURPNR) || ' not found'
    RETURN
  END
  IF RR \= 0 THEN DO
    CALL APPEND '*** Phone read failed RESP=' || RR
    RETURN
  END
  REC = OVERLAY(LEFT(BODY, 13), REC, 94, 13)
  EXEC CICS REWRITE FILE('sabre') FROM(REC) END-EXEC
  IF EIBRESP \= 0 THEN DO
    CALL APPEND '*** Phone rewrite failed RESP=' || EIBRESP
    RETURN
  END
  CALL APPEND 'Phone ' || BODY || ' added to ' || STRIP(CURPNR)
  RETURN

/* --- 7TAW<date>/  PNR ticketing field --------------------------- */
DO_TKT: PROCEDURE EXPOSE CURPNR HIST.
  PARSE ARG CMD
  BODY = STRIP(SUBSTR(CMD, 2))                   /* text after '7' */
  IF RIGHT(BODY,1) = '/' THEN BODY = LEFT(BODY, LENGTH(BODY) - 1)
  IF BODY = '' THEN DO
    CALL APPEND '*** Usage: 7TAW<date>/  (e.g. 7TAW15JUN/)'
    RETURN
  END
  IF CURPNR = '' THEN DO
    CALL APPEND '*** NO ACTIVE PNR - DISPLAY OR SELL A PNR FIRST'
    RETURN
  END
  PKEY = 'P' || CURPNR || '00'
  EXEC CICS READ FILE('sabre') INTO(REC) RIDFLD(PKEY) UPDATE END-EXEC
  RR = EIBRESP
  IF RR = 13 THEN DO
    CALL APPEND '*** PNR ' || STRIP(CURPNR) || ' not found'
    RETURN
  END
  IF RR \= 0 THEN DO
    CALL APPEND '*** Ticketing read failed RESP=' || RR
    RETURN
  END
  REC = OVERLAY(LEFT(BODY, 8), REC, 107, 8)
  EXEC CICS REWRITE FILE('sabre') FROM(REC) END-EXEC
  IF EIBRESP \= 0 THEN DO
    CALL APPEND '*** Ticketing rewrite failed RESP=' || EIBRESP
    RETURN
  END
  CALL APPEND 'Ticketing ' || BODY || ' set in ' || STRIP(CURPNR)
  RETURN

/* --- 6<name>  PNR received-from field ---------------------------- */
DO_RCVD: PROCEDURE EXPOSE CURPNR HIST.
  PARSE ARG CMD
  BODY = STRIP(SUBSTR(CMD, 2))                   /* text after '6' */
  IF BODY = '' THEN DO
    CALL APPEND '*** Usage: 6<name>  (e.g. 6SMITH)'
    RETURN
  END
  IF CURPNR = '' THEN DO
    CALL APPEND '*** NO ACTIVE PNR - DISPLAY OR SELL A PNR FIRST'
    RETURN
  END
  PKEY = 'P' || CURPNR || '00'
  EXEC CICS READ FILE('sabre') INTO(REC) RIDFLD(PKEY) UPDATE END-EXEC
  RR = EIBRESP
  IF RR = 13 THEN DO
    CALL APPEND '*** PNR ' || STRIP(CURPNR) || ' not found'
    RETURN
  END
  IF RR \= 0 THEN DO
    CALL APPEND '*** Received-from read failed RESP=' || RR
    RETURN
  END
  REC = OVERLAY(LEFT(BODY, 6), REC, 115, 6)
  EXEC CICS REWRITE FILE('sabre') FROM(REC) END-EXEC
  IF EIBRESP \= 0 THEN DO
    CALL APPEND '*** Received-from rewrite failed RESP=' || EIBRESP
    RETURN
  END
  CALL APPEND 'Received from ' || BODY || ' in ' || STRIP(CURPNR)
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
  PHON = STRIP(SUBSTR(REC,94,13),'T')
  TKTF = STRIP(SUBSTR(REC,107,8),'T')
  RCVF = STRIP(SUBSTR(REC,115,6),'T')
  IF PHON \= '' THEN CALL APPEND '   Phone: ' || PHON
  IF TKTF \= '' THEN CALL APPEND '   Tktg:  ' || TKTF
  IF RCVF \= '' THEN CALL APPEND '   Rcvd:  ' || RCVF
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

GENERATEFLIGHTS: PROCEDURE EXPOSE FLIGHTS. airlines. flightNumRange. eqSeats.,
                 aptRegion.
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

GETROUTEEQUIPMENT: PROCEDURE EXPOSE aptRegion.
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

GETAIRPORTREGION: PROCEDURE EXPOSE aptRegion.
  PARSE ARG CODE
  /* Region comes from the LOADAIRPORTS data (aptRegion.<CODE>); an unset
   * tail resolves to its uppercased name, which means "unknown" -> 'OT'. */
  R = VALUE('aptRegion.' || CODE)
  IF R = 'APTREGION.' || CODE THEN RETURN 'OT'
  RETURN R

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
             airlines. flightNumRange. fareTypes. paxTypes.,
             cityCode. aptRegion. routeMiles. regionMiles.
  /* Airports + city index + region map (hundreds of entries). */
  CALL LOADAIRPORTS

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

  /* Curated great-circle miles for popular routes (DD command). Keys are
   * DEP||ARR; DO_DD tries the reverse pair too, then a region fallback. */
  routeMiles.JFKLHR = 3451
  routeMiles.JFKLAX = 2475
  routeMiles.JFKZRH = 3936
  routeMiles.JFKCDG = 3635
  routeMiles.JFKFRA = 3851
  routeMiles.JFKGRU = 4759
  routeMiles.JFKNRT = 6740
  routeMiles.JFKDXB = 6836
  routeMiles.JFKSFO = 2586
  routeMiles.JFKMIA = 1090
  routeMiles.JFKORD = 740
  routeMiles.LAXNRT = 5451
  routeMiles.LAXSYD = 7488
  routeMiles.LAXHND = 5478
  routeMiles.LAXLHR = 5456
  routeMiles.LAXSFO = 337
  routeMiles.SFOHKG = 6927
  routeMiles.SFOSIN = 8446
  routeMiles.LHRDXB = 3414
  routeMiles.LHRSIN = 6764
  routeMiles.LHRHKG = 5994
  routeMiles.LHRJFK = 3451
  routeMiles.LHRCDG = 214
  routeMiles.LHRFRA = 406
  routeMiles.LHRZRH = 489
  routeMiles.FRADXB = 2989
  routeMiles.DXBSIN = 3633
  routeMiles.DXBSYD = 7484
  routeMiles.SINSYD = 3907
  routeMiles.HKGSIN = 1594
  routeMiles.SINKUL = 184
  routeMiles.ORDLHR = 3953

  /* Region-pair fallback miles (R1||R2); DO_DD tries R2||R1 too. */
  regionMiles.NANA = 1200
  regionMiles.NAEU = 4200
  regionMiles.NAAP = 7000
  regionMiles.NAME = 7200
  regionMiles.NAAF = 7600
  regionMiles.NASA = 3300
  regionMiles.EUEU = 700
  regionMiles.EUAP = 5800
  regionMiles.EUME = 2500
  regionMiles.EUAF = 3400
  regionMiles.EUSA = 6200
  regionMiles.APAP = 2400
  regionMiles.APME = 3600
  regionMiles.APAF = 6400
  regionMiles.APSA = 11500
  regionMiles.MEME = 900
  regionMiles.MEAF = 3000
  regionMiles.MESA = 8000
  regionMiles.AFAF = 2100
  regionMiles.AFSA = 4900
  regionMiles.SASA = 1600
  RETURN

/* ================================================================ */
/* REFERENCE DATA LOADERS (airports, city index, airlines)          */
/* ================================================================ */

/* Build airports.<CODE>, aptRegion.<CODE> and the reverse city index
 * cityCode.<UPPER-NOSPACE-CITY> from one data block. Called every turn
 * from INIT_TABLES (airports power availability, schedules, DD and
 * decode). APT does the per-row work. */
APT: PROCEDURE EXPOSE airports. cityCode. aptRegion.
  PARSE ARG CODE, CITY, NAME, REGION
  airports.CODE  = CITY || ' - ' || NAME
  aptRegion.CODE = REGION
  KEY = SPACE(TRANSLATE(CITY), 0)               /* uppercase, drop spaces */
  EXIST = VALUE('cityCode.' || KEY)
  IF EXIST = 'CITYCODE.' || KEY THEN cityCode.KEY = CODE
  ELSE IF WORDPOS(CODE, EXIST) = 0 THEN cityCode.KEY = EXIST CODE
  RETURN

/* Build airlineName.<IATA> and airlineName.<ICAO>. Loaded lazily (only
 * when a 2-letter airline decode is issued) so the common turn stays lean.
 * NOTE: never write the W-slash-star form here -- a literal slash-star
 * inside a comment opens a nested comment and eats the rest of the file. */
AIRL: PROCEDURE EXPOSE airlineName.
  PARSE ARG IATA, ICAO, NAME
  airlineName.IATA = NAME
  IF ICAO \= '' THEN airlineName.ICAO = NAME
  RETURN

LOADAIRPORTS: PROCEDURE EXPOSE airports. cityCode. aptRegion.
  CALL APT 'ATL','Atlanta','Hartsfield Jackson Intl','NA'
  CALL APT 'LAX','Los Angeles','Los Angeles Intl','NA'
  CALL APT 'ORD','Chicago','OHare Intl','NA'
  CALL APT 'DFW','Dallas','Dallas Fort Worth Intl','NA'
  CALL APT 'DEN','Denver','Denver Intl','NA'
  CALL APT 'JFK','New York','John F Kennedy Intl','NA'
  CALL APT 'SFO','San Francisco','San Francisco Intl','NA'
  CALL APT 'LAS','Las Vegas','Harry Reid Intl','NA'
  CALL APT 'SEA','Seattle','Seattle Tacoma Intl','NA'
  CALL APT 'MCO','Orlando','Orlando Intl','NA'
  CALL APT 'EWR','New York','Newark Liberty Intl','NA'
  CALL APT 'MIA','Miami','Miami Intl','NA'
  CALL APT 'PHX','Phoenix','Sky Harbor Intl','NA'
  CALL APT 'IAH','Houston','George Bush Intercontinental','NA'
  CALL APT 'BOS','Boston','Logan Intl','NA'
  CALL APT 'MSP','Minneapolis','Minneapolis St Paul Intl','NA'
  CALL APT 'DTW','Detroit','Detroit Metro Wayne County','NA'
  CALL APT 'FLL','Fort Lauderdale','Fort Lauderdale Hollywood Intl','NA'
  CALL APT 'CLT','Charlotte','Charlotte Douglas Intl','NA'
  CALL APT 'LGA','New York','LaGuardia','NA'
  CALL APT 'BWI','Baltimore','Baltimore Washington Intl','NA'
  CALL APT 'SAN','San Diego','San Diego Intl','NA'
  CALL APT 'PDX','Portland','Portland Intl','NA'
  CALL APT 'STL','St Louis','St Louis Lambert Intl','NA'
  CALL APT 'BNA','Nashville','Nashville Intl','NA'
  CALL APT 'AUS','Austin','Austin Bergstrom Intl','NA'
  CALL APT 'MCI','Kansas City','Kansas City Intl','NA'
  CALL APT 'CLE','Cleveland','Cleveland Hopkins Intl','NA'
  CALL APT 'CMH','Columbus','John Glenn Columbus Intl','NA'
  CALL APT 'IND','Indianapolis','Indianapolis Intl','NA'
  CALL APT 'MKE','Milwaukee','Milwaukee Mitchell Intl','NA'
  CALL APT 'RDU','Raleigh','Raleigh Durham Intl','NA'
  CALL APT 'SMF','Sacramento','Sacramento Intl','NA'
  CALL APT 'SJC','San Jose','San Jose Intl','NA'
  CALL APT 'OAK','Oakland','Oakland Intl','NA'
  CALL APT 'ONT','Ontario','Ontario Intl','NA'
  CALL APT 'SNA','Santa Ana','John Wayne Orange County','NA'
  CALL APT 'BUR','Burbank','Hollywood Burbank','NA'
  CALL APT 'PIT','Pittsburgh','Pittsburgh Intl','NA'
  CALL APT 'CVG','Cincinnati','Cincinnati Northern Kentucky','NA'
  CALL APT 'MEM','Memphis','Memphis Intl','NA'
  CALL APT 'OKC','Oklahoma City','Will Rogers World','NA'
  CALL APT 'TUL','Tulsa','Tulsa Intl','NA'
  CALL APT 'ABQ','Albuquerque','Albuquerque Sunport','NA'
  CALL APT 'TUS','Tucson','Tucson Intl','NA'
  CALL APT 'ELP','El Paso','El Paso Intl','NA'
  CALL APT 'OMA','Omaha','Eppley Airfield','NA'
  CALL APT 'TPA','Tampa','Tampa Intl','NA'
  CALL APT 'PBI','West Palm Beach','Palm Beach Intl','NA'
  CALL APT 'RSW','Fort Myers','Southwest Florida Intl','NA'
  CALL APT 'JAX','Jacksonville','Jacksonville Intl','NA'
  CALL APT 'MSY','New Orleans','Louis Armstrong Intl','NA'
  CALL APT 'SAT','San Antonio','San Antonio Intl','NA'
  CALL APT 'HOU','Houston','William P Hobby','NA'
  CALL APT 'DAL','Dallas','Dallas Love Field','NA'
  CALL APT 'MDW','Chicago','Midway Intl','NA'
  CALL APT 'HNL','Honolulu','Daniel K Inouye Intl','NA'
  CALL APT 'OGG','Kahului','Kahului','NA'
  CALL APT 'ANC','Anchorage','Ted Stevens Anchorage Intl','NA'
  CALL APT 'RIC','Richmond','Richmond Intl','NA'
  CALL APT 'ORF','Norfolk','Norfolk Intl','NA'
  CALL APT 'GRR','Grand Rapids','Gerald R Ford Intl','NA'
  CALL APT 'BUF','Buffalo','Buffalo Niagara Intl','NA'
  CALL APT 'ROC','Rochester','Greater Rochester Intl','NA'
  CALL APT 'ALB','Albany','Albany Intl','NA'
  CALL APT 'PVD','Providence','T F Green Intl','NA'
  CALL APT 'BDL','Hartford','Bradley Intl','NA'
  CALL APT 'SYR','Syracuse','Syracuse Hancock Intl','NA'
  CALL APT 'GSO','Greensboro','Piedmont Triad Intl','NA'
  CALL APT 'CHS','Charleston','Charleston Intl','NA'
  CALL APT 'SAV','Savannah','Savannah Hilton Head Intl','NA'
  CALL APT 'MYR','Myrtle Beach','Myrtle Beach Intl','NA'
  CALL APT 'GSP','Greenville','Greenville Spartanburg Intl','NA'
  CALL APT 'BHM','Birmingham','Birmingham Shuttlesworth Intl','NA'
  CALL APT 'JAN','Jackson','Jackson Medgar Wiley Evers Intl','NA'
  CALL APT 'LIT','Little Rock','Clinton National','NA'
  CALL APT 'DSM','Des Moines','Des Moines Intl','NA'
  CALL APT 'ICT','Wichita','Wichita Eisenhower Intl','NA'
  CALL APT 'BOI','Boise','Boise Airport','NA'
  CALL APT 'GEG','Spokane','Spokane Intl','NA'
  CALL APT 'RNO','Reno','Reno Tahoe Intl','NA'
  CALL APT 'SLC','Salt Lake City','Salt Lake City Intl','NA'
  CALL APT 'COS','Colorado Springs','Colorado Springs Airport','NA'
  CALL APT 'PSP','Palm Springs','Palm Springs Intl','NA'
  CALL APT 'FAT','Fresno','Fresno Yosemite Intl','NA'
  CALL APT 'LGB','Long Beach','Long Beach Airport','NA'
  CALL APT 'DAY','Dayton','Dayton Intl','NA'
  CALL APT 'MSN','Madison','Dane County Regional','NA'
  CALL APT 'PWM','Portland','Portland Intl Jetport','NA'
  CALL APT 'BTV','Burlington','Burlington Intl','NA'
  CALL APT 'TYS','Knoxville','McGhee Tyson','NA'
  CALL APT 'GPT','Gulfport','Gulfport Biloxi Intl','NA'
  CALL APT 'PNS','Pensacola','Pensacola Intl','NA'
  CALL APT 'XNA','Fayetteville','Northwest Arkansas','NA'
  CALL APT 'FAR','Fargo','Hector Intl','NA'
  CALL APT 'BIL','Billings','Billings Logan Intl','NA'
  CALL APT 'JAC','Jackson','Jackson Hole','NA'
  CALL APT 'EUG','Eugene','Eugene Airport','NA'
  CALL APT 'YYZ','Toronto','Toronto Pearson Intl','NA'
  CALL APT 'YVR','Vancouver','Vancouver Intl','NA'
  CALL APT 'YUL','Montreal','Montreal Trudeau Intl','NA'
  CALL APT 'YYC','Calgary','Calgary Intl','NA'
  CALL APT 'YEG','Edmonton','Edmonton Intl','NA'
  CALL APT 'YOW','Ottawa','Ottawa Macdonald Cartier Intl','NA'
  CALL APT 'YWG','Winnipeg','Winnipeg James Richardson Intl','NA'
  CALL APT 'YHZ','Halifax','Halifax Stanfield Intl','NA'
  CALL APT 'YQB','Quebec City','Quebec City Jean Lesage Intl','NA'
  CALL APT 'YYT','St Johns','St Johns Intl','NA'
  CALL APT 'YXE','Saskatoon','Saskatoon Diefenbaker Intl','NA'
  CALL APT 'YQR','Regina','Regina Intl','NA'
  CALL APT 'YLW','Kelowna','Kelowna Intl','NA'
  CALL APT 'YVI','Victoria','Victoria Intl','NA'
  CALL APT 'LHR','London','Heathrow','EU'
  CALL APT 'LGW','London','Gatwick','EU'
  CALL APT 'STN','London','Stansted','EU'
  CALL APT 'LTN','London','Luton','EU'
  CALL APT 'LCY','London','London City','EU'
  CALL APT 'MAN','Manchester','Manchester Airport','EU'
  CALL APT 'BHX','Birmingham','Birmingham Airport','EU'
  CALL APT 'EDI','Edinburgh','Edinburgh Airport','EU'
  CALL APT 'GLA','Glasgow','Glasgow Airport','EU'
  CALL APT 'BRS','Bristol','Bristol Airport','EU'
  CALL APT 'NCL','Newcastle','Newcastle Airport','EU'
  CALL APT 'LPL','Liverpool','Liverpool John Lennon','EU'
  CALL APT 'BFS','Belfast','Belfast Intl','EU'
  CALL APT 'DUB','Dublin','Dublin Airport','EU'
  CALL APT 'ORK','Cork','Cork Airport','EU'
  CALL APT 'CDG','Paris','Charles de Gaulle','EU'
  CALL APT 'ORY','Paris','Orly','EU'
  CALL APT 'NCE','Nice','Nice Cote dAzur','EU'
  CALL APT 'LYS','Lyon','Lyon Saint Exupery','EU'
  CALL APT 'MRS','Marseille','Marseille Provence','EU'
  CALL APT 'TLS','Toulouse','Toulouse Blagnac','EU'
  CALL APT 'NTE','Nantes','Nantes Atlantique','EU'
  CALL APT 'BOD','Bordeaux','Bordeaux Merignac','EU'
  CALL APT 'AMS','Amsterdam','Schiphol','EU'
  CALL APT 'FRA','Frankfurt','Frankfurt Airport','EU'
  CALL APT 'MUC','Munich','Munich Airport','EU'
  CALL APT 'DUS','Dusseldorf','Dusseldorf Airport','EU'
  CALL APT 'HAM','Hamburg','Hamburg Airport','EU'
  CALL APT 'STR','Stuttgart','Stuttgart Airport','EU'
  CALL APT 'CGN','Cologne','Cologne Bonn','EU'
  CALL APT 'TXL','Berlin','Berlin Tegel','EU'
  CALL APT 'BER','Berlin','Berlin Brandenburg','EU'
  CALL APT 'HAJ','Hanover','Hanover Airport','EU'
  CALL APT 'NUE','Nuremberg','Nuremberg Airport','EU'
  CALL APT 'LEJ','Leipzig','Leipzig Halle','EU'
  CALL APT 'BRU','Brussels','Brussels Airport','EU'
  CALL APT 'ANR','Antwerp','Antwerp Intl','EU'
  CALL APT 'ZRH','Zurich','Zurich Airport','EU'
  CALL APT 'GVA','Geneva','Geneva Airport','EU'
  CALL APT 'BSL','Basel','EuroAirport Basel','EU'
  CALL APT 'VIE','Vienna','Vienna Intl','EU'
  CALL APT 'MAD','Madrid','Adolfo Suarez Barajas','EU'
  CALL APT 'BCN','Barcelona','Barcelona El Prat','EU'
  CALL APT 'VLC','Valencia','Valencia Airport','EU'
  CALL APT 'SVQ','Seville','Seville Airport','EU'
  CALL APT 'AGP','Malaga','Malaga Costa del Sol','EU'
  CALL APT 'BIO','Bilbao','Bilbao Airport','EU'
  CALL APT 'PMI','Palma','Palma de Mallorca','EU'
  CALL APT 'LPA','Las Palmas','Gran Canaria','EU'
  CALL APT 'TFS','Tenerife','Tenerife South','EU'
  CALL APT 'FCO','Rome','Fiumicino','EU'
  CALL APT 'CIA','Rome','Ciampino','EU'
  CALL APT 'MXP','Milan','Malpensa','EU'
  CALL APT 'LIN','Milan','Linate','EU'
  CALL APT 'BGY','Milan','Bergamo Orio al Serio','EU'
  CALL APT 'VCE','Venice','Venice Marco Polo','EU'
  CALL APT 'NAP','Naples','Naples Intl','EU'
  CALL APT 'BLQ','Bologna','Bologna Guglielmo Marconi','EU'
  CALL APT 'PSA','Pisa','Pisa Intl','EU'
  CALL APT 'CTA','Catania','Catania Fontanarossa','EU'
  CALL APT 'PMO','Palermo','Palermo Airport','EU'
  CALL APT 'LIS','Lisbon','Humberto Delgado','EU'
  CALL APT 'OPO','Porto','Porto Airport','EU'
  CALL APT 'FAO','Faro','Faro Airport','EU'
  CALL APT 'ATH','Athens','Athens Intl','EU'
  CALL APT 'SKG','Thessaloniki','Thessaloniki Airport','EU'
  CALL APT 'HER','Heraklion','Heraklion Airport','EU'
  CALL APT 'HEL','Helsinki','Helsinki Vantaa','EU'
  CALL APT 'ARN','Stockholm','Stockholm Arlanda','EU'
  CALL APT 'GOT','Gothenburg','Gothenburg Landvetter','EU'
  CALL APT 'MMX','Malmo','Malmo Airport','EU'
  CALL APT 'OSL','Oslo','Oslo Gardermoen','EU'
  CALL APT 'BGO','Bergen','Bergen Flesland','EU'
  CALL APT 'TRD','Trondheim','Trondheim Vaernes','EU'
  CALL APT 'SVG','Stavanger','Stavanger Sola','EU'
  CALL APT 'CPH','Copenhagen','Copenhagen Kastrup','EU'
  CALL APT 'AAL','Aalborg','Aalborg Airport','EU'
  CALL APT 'BLL','Billund','Billund Airport','EU'
  CALL APT 'KEF','Reykjavik','Keflavik Intl','EU'
  CALL APT 'WAW','Warsaw','Warsaw Chopin','EU'
  CALL APT 'KRK','Krakow','Krakow John Paul II','EU'
  CALL APT 'GDN','Gdansk','Gdansk Lech Walesa','EU'
  CALL APT 'PRG','Prague','Vaclav Havel Prague','EU'
  CALL APT 'BUD','Budapest','Budapest Ferenc Liszt','EU'
  CALL APT 'OTP','Bucharest','Henri Coanda Intl','EU'
  CALL APT 'SOF','Sofia','Sofia Airport','EU'
  CALL APT 'ZAG','Zagreb','Zagreb Franjo Tudman','EU'
  CALL APT 'BEG','Belgrade','Belgrade Nikola Tesla','EU'
  CALL APT 'LJU','Ljubljana','Ljubljana Joze Pucnik','EU'
  CALL APT 'RIX','Riga','Riga Intl','EU'
  CALL APT 'TLL','Tallinn','Tallinn Lennart Meri','EU'
  CALL APT 'VNO','Vilnius','Vilnius Airport','EU'
  CALL APT 'KBP','Kyiv','Boryspil Intl','EU'
  CALL APT 'IST','Istanbul','Istanbul Airport','EU'
  CALL APT 'SAW','Istanbul','Sabiha Gokcen','EU'
  CALL APT 'AYT','Antalya','Antalya Airport','EU'
  CALL APT 'ESB','Ankara','Esenboga Intl','EU'
  CALL APT 'ADB','Izmir','Adnan Menderes','EU'
  CALL APT 'SVO','Moscow','Sheremetyevo','EU'
  CALL APT 'DME','Moscow','Domodedovo','EU'
  CALL APT 'VKO','Moscow','Vnukovo','EU'
  CALL APT 'LED','St Petersburg','Pulkovo','EU'
  CALL APT 'SVX','Yekaterinburg','Koltsovo','EU'
  CALL APT 'OVB','Novosibirsk','Tolmachevo','EU'
  CALL APT 'PEK','Beijing','Beijing Capital Intl','AP'
  CALL APT 'PKX','Beijing','Beijing Daxing Intl','AP'
  CALL APT 'PVG','Shanghai','Shanghai Pudong Intl','AP'
  CALL APT 'SHA','Shanghai','Shanghai Hongqiao Intl','AP'
  CALL APT 'CAN','Guangzhou','Guangzhou Baiyun Intl','AP'
  CALL APT 'SZX','Shenzhen','Shenzhen Baoan Intl','AP'
  CALL APT 'CTU','Chengdu','Chengdu Tianfu Intl','AP'
  CALL APT 'CKG','Chongqing','Chongqing Jiangbei Intl','AP'
  CALL APT 'XIY','Xian','Xian Xianyang Intl','AP'
  CALL APT 'KMG','Kunming','Kunming Changshui Intl','AP'
  CALL APT 'HGH','Hangzhou','Hangzhou Xiaoshan Intl','AP'
  CALL APT 'NKG','Nanjing','Nanjing Lukou Intl','AP'
  CALL APT 'WUH','Wuhan','Wuhan Tianhe Intl','AP'
  CALL APT 'TSN','Tianjin','Tianjin Binhai Intl','AP'
  CALL APT 'XMN','Xiamen','Xiamen Gaoqi Intl','AP'
  CALL APT 'HKG','Hong Kong','Hong Kong Intl','AP'
  CALL APT 'MFM','Macau','Macau Intl','AP'
  CALL APT 'TPE','Taipei','Taoyuan Intl','AP'
  CALL APT 'TSA','Taipei','Songshan','AP'
  CALL APT 'KHH','Kaohsiung','Kaohsiung Intl','AP'
  CALL APT 'NRT','Tokyo','Narita Intl','AP'
  CALL APT 'HND','Tokyo','Haneda','AP'
  CALL APT 'KIX','Osaka','Kansai Intl','AP'
  CALL APT 'ITM','Osaka','Itami','AP'
  CALL APT 'NGO','Nagoya','Chubu Centrair Intl','AP'
  CALL APT 'FUK','Fukuoka','Fukuoka Airport','AP'
  CALL APT 'CTS','Sapporo','New Chitose','AP'
  CALL APT 'OKA','Okinawa','Naha Airport','AP'
  CALL APT 'ICN','Seoul','Incheon Intl','AP'
  CALL APT 'GMP','Seoul','Gimpo Intl','AP'
  CALL APT 'PUS','Busan','Gimhae Intl','AP'
  CALL APT 'CJU','Jeju','Jeju Intl','AP'
  CALL APT 'BKK','Bangkok','Suvarnabhumi','AP'
  CALL APT 'DMK','Bangkok','Don Mueang Intl','AP'
  CALL APT 'HKT','Phuket','Phuket Intl','AP'
  CALL APT 'CNX','Chiang Mai','Chiang Mai Intl','AP'
  CALL APT 'SIN','Singapore','Changi','AP'
  CALL APT 'KUL','Kuala Lumpur','Kuala Lumpur Intl','AP'
  CALL APT 'PEN','Penang','Penang Intl','AP'
  CALL APT 'BKI','Kota Kinabalu','Kota Kinabalu Intl','AP'
  CALL APT 'CGK','Jakarta','Soekarno Hatta Intl','AP'
  CALL APT 'DPS','Denpasar','Ngurah Rai Intl','AP'
  CALL APT 'SUB','Surabaya','Juanda Intl','AP'
  CALL APT 'MNL','Manila','Ninoy Aquino Intl','AP'
  CALL APT 'CEB','Cebu','Mactan Cebu Intl','AP'
  CALL APT 'DVO','Davao','Francisco Bangoy Intl','AP'
  CALL APT 'SGN','Ho Chi Minh City','Tan Son Nhat Intl','AP'
  CALL APT 'HAN','Hanoi','Noi Bai Intl','AP'
  CALL APT 'DAD','Da Nang','Da Nang Intl','AP'
  CALL APT 'RGN','Yangon','Yangon Intl','AP'
  CALL APT 'PNH','Phnom Penh','Phnom Penh Intl','AP'
  CALL APT 'REP','Siem Reap','Siem Reap Angkor Intl','AP'
  CALL APT 'VTE','Vientiane','Wattay Intl','AP'
  CALL APT 'DAC','Dhaka','Hazrat Shahjalal Intl','AP'
  CALL APT 'CMB','Colombo','Bandaranaike Intl','AP'
  CALL APT 'KTM','Kathmandu','Tribhuvan Intl','AP'
  CALL APT 'DEL','Delhi','Indira Gandhi Intl','AP'
  CALL APT 'BOM','Mumbai','Chhatrapati Shivaji Intl','AP'
  CALL APT 'MAA','Chennai','Chennai Intl','AP'
  CALL APT 'BLR','Bengaluru','Kempegowda Intl','AP'
  CALL APT 'HYD','Hyderabad','Rajiv Gandhi Intl','AP'
  CALL APT 'CCU','Kolkata','Netaji Subhas Chandra Bose','AP'
  CALL APT 'COK','Kochi','Cochin Intl','AP'
  CALL APT 'AMD','Ahmedabad','Sardar Vallabhbhai Patel','AP'
  CALL APT 'PNQ','Pune','Pune Airport','AP'
  CALL APT 'GOI','Goa','Goa Dabolim','AP'
  CALL APT 'ISB','Islamabad','Islamabad Intl','AP'
  CALL APT 'LHE','Lahore','Allama Iqbal Intl','AP'
  CALL APT 'KHI','Karachi','Jinnah Intl','AP'
  CALL APT 'TAS','Tashkent','Tashkent Intl','AP'
  CALL APT 'ALA','Almaty','Almaty Intl','AP'
  CALL APT 'NQZ','Astana','Astana Nursultan Nazarbayev','AP'
  CALL APT 'ULN','Ulaanbaatar','Chinggis Khaan Intl','AP'
  CALL APT 'SYD','Sydney','Sydney Kingsford Smith','AP'
  CALL APT 'MEL','Melbourne','Melbourne Airport','AP'
  CALL APT 'BNE','Brisbane','Brisbane Airport','AP'
  CALL APT 'PER','Perth','Perth Airport','AP'
  CALL APT 'ADL','Adelaide','Adelaide Airport','AP'
  CALL APT 'OOL','Gold Coast','Gold Coast Airport','AP'
  CALL APT 'CNS','Cairns','Cairns Airport','AP'
  CALL APT 'DRW','Darwin','Darwin Intl','AP'
  CALL APT 'HBA','Hobart','Hobart Airport','AP'
  CALL APT 'CBR','Canberra','Canberra Airport','AP'
  CALL APT 'AKL','Auckland','Auckland Airport','AP'
  CALL APT 'CHC','Christchurch','Christchurch Airport','AP'
  CALL APT 'WLG','Wellington','Wellington Airport','AP'
  CALL APT 'ZQN','Queenstown','Queenstown Airport','AP'
  CALL APT 'NAN','Nadi','Nadi Intl','AP'
  CALL APT 'POM','Port Moresby','Jacksons Intl','AP'
  CALL APT 'GUM','Guam','Antonio B Won Pat Intl','AP'
  CALL APT 'DXB','Dubai','Dubai Intl','ME'
  CALL APT 'DWC','Dubai','Al Maktoum Intl','ME'
  CALL APT 'AUH','Abu Dhabi','Zayed Intl','ME'
  CALL APT 'SHJ','Sharjah','Sharjah Intl','ME'
  CALL APT 'DOH','Doha','Hamad Intl','ME'
  CALL APT 'BAH','Manama','Bahrain Intl','ME'
  CALL APT 'KWI','Kuwait City','Kuwait Intl','ME'
  CALL APT 'MCT','Muscat','Muscat Intl','ME'
  CALL APT 'RUH','Riyadh','King Khalid Intl','ME'
  CALL APT 'JED','Jeddah','King Abdulaziz Intl','ME'
  CALL APT 'DMM','Dammam','King Fahd Intl','ME'
  CALL APT 'MED','Medina','Prince Mohammad Bin Abdulaziz','ME'
  CALL APT 'AHB','Abha','Abha Intl','ME'
  CALL APT 'TLV','Tel Aviv','Ben Gurion Intl','ME'
  CALL APT 'AMM','Amman','Queen Alia Intl','ME'
  CALL APT 'BEY','Beirut','Rafic Hariri Intl','ME'
  CALL APT 'BGW','Baghdad','Baghdad Intl','ME'
  CALL APT 'BSR','Basra','Basra Intl','ME'
  CALL APT 'EBL','Erbil','Erbil Intl','ME'
  CALL APT 'IKA','Tehran','Imam Khomeini Intl','ME'
  CALL APT 'THR','Tehran','Mehrabad Intl','ME'
  CALL APT 'GYD','Baku','Heydar Aliyev Intl','ME'
  CALL APT 'EVN','Yerevan','Zvartnots Intl','ME'
  CALL APT 'TBS','Tbilisi','Tbilisi Intl','ME'
  CALL APT 'CAI','Cairo','Cairo Intl','AF'
  CALL APT 'HRG','Hurghada','Hurghada Intl','AF'
  CALL APT 'SSH','Sharm El Sheikh','Sharm El Sheikh Intl','AF'
  CALL APT 'ASW','Aswan','Aswan Intl','AF'
  CALL APT 'CMN','Casablanca','Mohammed V Intl','AF'
  CALL APT 'RAK','Marrakech','Marrakech Menara','AF'
  CALL APT 'FEZ','Fez','Fez Saiss','AF'
  CALL APT 'TNG','Tangier','Tangier Ibn Battouta','AF'
  CALL APT 'AGA','Agadir','Agadir Al Massira','AF'
  CALL APT 'ALG','Algiers','Houari Boumediene','AF'
  CALL APT 'ORN','Oran','Oran Es Senia','AF'
  CALL APT 'TUN','Tunis','Tunis Carthage','AF'
  CALL APT 'DJE','Djerba','Djerba Zarzis','AF'
  CALL APT 'TIP','Tripoli','Tripoli Intl','AF'
  CALL APT 'LOS','Lagos','Murtala Muhammed Intl','AF'
  CALL APT 'ABV','Abuja','Nnamdi Azikiwe Intl','AF'
  CALL APT 'PHC','Port Harcourt','Port Harcourt Intl','AF'
  CALL APT 'ACC','Accra','Kotoka Intl','AF'
  CALL APT 'ABJ','Abidjan','Felix Houphouet Boigny Intl','AF'
  CALL APT 'DKR','Dakar','Blaise Diagne Intl','AF'
  CALL APT 'NBO','Nairobi','Jomo Kenyatta Intl','AF'
  CALL APT 'MBA','Mombasa','Moi Intl','AF'
  CALL APT 'ADD','Addis Ababa','Bole Intl','AF'
  CALL APT 'DAR','Dar es Salaam','Julius Nyerere Intl','AF'
  CALL APT 'JRO','Kilimanjaro','Kilimanjaro Intl','AF'
  CALL APT 'ZNZ','Zanzibar','Abeid Amani Karume Intl','AF'
  CALL APT 'EBB','Entebbe','Entebbe Intl','AF'
  CALL APT 'KGL','Kigali','Kigali Intl','AF'
  CALL APT 'HRE','Harare','Robert Mugabe Intl','AF'
  CALL APT 'LUN','Lusaka','Kenneth Kaunda Intl','AF'
  CALL APT 'GBE','Gaborone','Sir Seretse Khama Intl','AF'
  CALL APT 'WDH','Windhoek','Hosea Kutako Intl','AF'
  CALL APT 'MRU','Mauritius','Sir Seewoosagur Ramgoolam','AF'
  CALL APT 'SEZ','Mahe','Seychelles Intl','AF'
  CALL APT 'JNB','Johannesburg','OR Tambo Intl','AF'
  CALL APT 'CPT','Cape Town','Cape Town Intl','AF'
  CALL APT 'DUR','Durban','King Shaka Intl','AF'
  CALL APT 'PLZ','Port Elizabeth','Chief Dawid Stuurman Intl','AF'
  CALL APT 'LAD','Luanda','Quatro de Fevereiro','AF'
  CALL APT 'MEX','Mexico City','Benito Juarez Intl','SA'
  CALL APT 'NLU','Mexico City','Felipe Angeles Intl','SA'
  CALL APT 'GDL','Guadalajara','Guadalajara Intl','SA'
  CALL APT 'MTY','Monterrey','Monterrey Intl','SA'
  CALL APT 'TIJ','Tijuana','Tijuana Intl','SA'
  CALL APT 'CUN','Cancun','Cancun Intl','SA'
  CALL APT 'SJD','Los Cabos','Los Cabos Intl','SA'
  CALL APT 'PVR','Puerto Vallarta','Puerto Vallarta Intl','SA'
  CALL APT 'MID','Merida','Merida Intl','SA'
  CALL APT 'GUA','Guatemala City','La Aurora Intl','SA'
  CALL APT 'SAL','San Salvador','Monsenor Romero Intl','SA'
  CALL APT 'SJO','San Jose','Juan Santamaria Intl','SA'
  CALL APT 'PTY','Panama City','Tocumen Intl','SA'
  CALL APT 'HAV','Havana','Jose Marti Intl','SA'
  CALL APT 'SDQ','Santo Domingo','Las Americas Intl','SA'
  CALL APT 'PUJ','Punta Cana','Punta Cana Intl','SA'
  CALL APT 'SJU','San Juan','Luis Munoz Marin Intl','SA'
  CALL APT 'KIN','Kingston','Norman Manley Intl','SA'
  CALL APT 'MBJ','Montego Bay','Sangster Intl','SA'
  CALL APT 'NAS','Nassau','Lynden Pindling Intl','SA'
  CALL APT 'POS','Port of Spain','Piarco Intl','SA'
  CALL APT 'BGI','Bridgetown','Grantley Adams Intl','SA'
  CALL APT 'CCS','Caracas','Simon Bolivar Intl','SA'
  CALL APT 'BOG','Bogota','El Dorado Intl','SA'
  CALL APT 'MDE','Medellin','Jose Maria Cordova Intl','SA'
  CALL APT 'CLO','Cali','Alfonso Bonilla Aragon Intl','SA'
  CALL APT 'CTG','Cartagena','Rafael Nunez Intl','SA'
  CALL APT 'UIO','Quito','Mariscal Sucre Intl','SA'
  CALL APT 'GYE','Guayaquil','Jose Joaquin de Olmedo Intl','SA'
  CALL APT 'LIM','Lima','Jorge Chavez Intl','SA'
  CALL APT 'CUZ','Cusco','Alejandro Velasco Astete Intl','SA'
  CALL APT 'LPB','La Paz','El Alto Intl','SA'
  CALL APT 'VVI','Santa Cruz','Viru Viru Intl','SA'
  CALL APT 'ASU','Asuncion','Silvio Pettirossi Intl','SA'
  CALL APT 'MVD','Montevideo','Carrasco Intl','SA'
  CALL APT 'SCL','Santiago','Arturo Merino Benitez Intl','SA'
  CALL APT 'EZE','Buenos Aires','Ministro Pistarini Ezeiza','SA'
  CALL APT 'AEP','Buenos Aires','Jorge Newbery Aeroparque','SA'
  CALL APT 'COR','Cordoba','Ingeniero Taravella Intl','SA'
  CALL APT 'MDZ','Mendoza','El Plumerillo Intl','SA'
  CALL APT 'GRU','Sao Paulo','Guarulhos Intl','SA'
  CALL APT 'CGH','Sao Paulo','Congonhas','SA'
  CALL APT 'VCP','Sao Paulo','Viracopos Campinas','SA'
  CALL APT 'GIG','Rio de Janeiro','Galeao Intl','SA'
  CALL APT 'SDU','Rio de Janeiro','Santos Dumont','SA'
  CALL APT 'BSB','Brasilia','Brasilia Intl','SA'
  CALL APT 'SSA','Salvador','Deputado Luis Eduardo Magalhaes','SA'
  CALL APT 'REC','Recife','Guararapes Intl','SA'
  CALL APT 'FOR','Fortaleza','Pinto Martins Intl','SA'
  CALL APT 'POA','Porto Alegre','Salgado Filho Intl','SA'
  CALL APT 'CWB','Curitiba','Afonso Pena Intl','SA'
  CALL APT 'CNF','Belo Horizonte','Tancredo Neves Intl','SA'
  CALL APT 'MAO','Manaus','Eduardo Gomes Intl','SA'
  CALL APT 'BEL','Belem','Val de Cans Intl','SA'
  RETURN

LOADAIRLINES: PROCEDURE EXPOSE airlineName.
  CALL AIRL 'AA','AAL','American Airlines'
  CALL AIRL 'DL','DAL','Delta Air Lines'
  CALL AIRL 'UA','UAL','United Airlines'
  CALL AIRL 'WN','SWA','Southwest Airlines'
  CALL AIRL 'B6','JBU','JetBlue Airways'
  CALL AIRL 'AS','ASA','Alaska Airlines'
  CALL AIRL 'NK','NKS','Spirit Airlines'
  CALL AIRL 'F9','FFT','Frontier Airlines'
  CALL AIRL 'G4','AAY','Allegiant Air'
  CALL AIRL 'HA','HAL','Hawaiian Airlines'
  CALL AIRL 'SY','SCX','Sun Country Airlines'
  CALL AIRL 'MX','MXY','Breeze Airways'
  CALL AIRL 'AC','ACA','Air Canada'
  CALL AIRL 'WS','WJA','WestJet'
  CALL AIRL 'PD','POE','Porter Airlines'
  CALL AIRL 'TS','TSC','Air Transat'
  CALL AIRL 'F8','FLE','Flair Airlines'
  CALL AIRL 'LA','LAN','LATAM Airlines'
  CALL AIRL 'JJ','TAM','LATAM Brasil'
  CALL AIRL 'AV','AVA','Avianca'
  CALL AIRL 'CM','CMP','Copa Airlines'
  CALL AIRL 'AM','AMX','Aeromexico'
  CALL AIRL 'Y4','VOI','Volaris'
  CALL AIRL 'AR','ARG','Aerolineas Argentinas'
  CALL AIRL 'AD','AZU','Azul Brazilian Airlines'
  CALL AIRL 'G3','GLO','Gol Linhas Aereas'
  CALL AIRL 'H2','SKU','Sky Airline'
  CALL AIRL 'BA','BAW','British Airways'
  CALL AIRL 'VS','VIR','Virgin Atlantic'
  CALL AIRL 'AF','AFR','Air France'
  CALL AIRL 'KL','KLM','KLM Royal Dutch Airlines'
  CALL AIRL 'LH','DLH','Lufthansa'
  CALL AIRL 'LX','SWR','Swiss Intl Air Lines'
  CALL AIRL 'OS','AUA','Austrian Airlines'
  CALL AIRL 'SN','BEL','Brussels Airlines'
  CALL AIRL 'IB','IBE','Iberia'
  CALL AIRL 'UX','AEA','Air Europa'
  CALL AIRL 'EI','EIN','Aer Lingus'
  CALL AIRL 'TP','TAP','TAP Air Portugal'
  CALL AIRL 'AZ','ITY','ITA Airways'
  CALL AIRL 'SK','SAS','Scandinavian Airlines'
  CALL AIRL 'AY','FIN','Finnair'
  CALL AIRL 'LO','LOT','LOT Polish Airlines'
  CALL AIRL 'OK','CSA','Czech Airlines'
  CALL AIRL 'OU','CTN','Croatia Airlines'
  CALL AIRL 'JU','ASL','Air Serbia'
  CALL AIRL 'RO','ROT','Tarom'
  CALL AIRL 'A3','AEE','Aegean Airlines'
  CALL AIRL 'FB','LZB','Bulgaria Air'
  CALL AIRL 'SU','AFL','Aeroflot'
  CALL AIRL 'S7','SBI','S7 Airlines'
  CALL AIRL 'TK','THY','Turkish Airlines'
  CALL AIRL 'PC','PGT','Pegasus Airlines'
  CALL AIRL 'PS','AUI','Ukraine Intl Airlines'
  CALL AIRL 'FR','RYR','Ryanair'
  CALL AIRL 'U2','EZY','easyJet'
  CALL AIRL 'VY','VLG','Vueling'
  CALL AIRL 'W6','WZZ','Wizz Air'
  CALL AIRL 'DY','NAX','Norwegian Air Shuttle'
  CALL AIRL 'EW','EWG','Eurowings'
  CALL AIRL 'HV','TRA','Transavia'
  CALL AIRL 'TO','TVF','Transavia France'
  CALL AIRL 'V7','VOE','Volotea'
  CALL AIRL 'DE','CFG','Condor'
  CALL AIRL 'LS','EXS','Jet2'
  CALL AIRL 'MT','TOM','TUI Airways'
  CALL AIRL 'BT','BTI','Air Baltic'
  CALL AIRL 'WK','EDW','Edelweiss Air'
  CALL AIRL 'LG','LGL','Luxair'
  CALL AIRL 'FI','ICE','Icelandair'
  CALL AIRL 'WW','PLY','PLAY'
  CALL AIRL 'KM','AMC','Air Malta'
  CALL AIRL 'OA','OAL','Olympic Air'
  CALL AIRL 'EK','UAE','Emirates'
  CALL AIRL 'EY','ETD','Etihad Airways'
  CALL AIRL 'QR','QTR','Qatar Airways'
  CALL AIRL 'SV','SVA','Saudia'
  CALL AIRL 'GF','GFA','Gulf Air'
  CALL AIRL 'WY','OMA','Oman Air'
  CALL AIRL 'RJ','RJA','Royal Jordanian'
  CALL AIRL 'ME','MEA','Middle East Airlines'
  CALL AIRL 'MS','MSR','EgyptAir'
  CALL AIRL 'FZ','FDB','Flydubai'
  CALL AIRL 'XY','KNE','Flynas'
  CALL AIRL 'G9','ABY','Air Arabia'
  CALL AIRL 'IR','IRA','Iran Air'
  CALL AIRL 'LY','ELY','El Al'
  CALL AIRL 'KU','KAC','Kuwait Airways'
  CALL AIRL 'J2','AHY','Azerbaijan Airlines'
  CALL AIRL 'A9','TGZ','Georgian Airways'
  CALL AIRL 'SQ','SIA','Singapore Airlines'
  CALL AIRL 'CX','CPA','Cathay Pacific'
  CALL AIRL 'JL','JAL','Japan Airlines'
  CALL AIRL 'NH','ANA','All Nippon Airways'
  CALL AIRL 'KE','KAL','Korean Air'
  CALL AIRL 'OZ','AAR','Asiana Airlines'
  CALL AIRL 'CI','CAL','China Airlines'
  CALL AIRL 'BR','EVA','EVA Air'
  CALL AIRL 'TG','THA','Thai Airways'
  CALL AIRL 'MH','MAS','Malaysia Airlines'
  CALL AIRL 'GA','GIA','Garuda Indonesia'
  CALL AIRL 'PR','PAL','Philippine Airlines'
  CALL AIRL 'VN','HVN','Vietnam Airlines'
  CALL AIRL 'CA','CCA','Air China'
  CALL AIRL 'CZ','CSN','China Southern Airlines'
  CALL AIRL 'MU','CES','China Eastern Airlines'
  CALL AIRL 'HU','CHH','Hainan Airlines'
  CALL AIRL 'FM','CSH','Shanghai Airlines'
  CALL AIRL 'ZH','CSZ','Shenzhen Airlines'
  CALL AIRL 'MF','CXA','Xiamen Airlines'
  CALL AIRL 'SC','CDG','Shandong Airlines'
  CALL AIRL 'AI','AIC','Air India'
  CALL AIRL '6E','IGO','IndiGo'
  CALL AIRL 'UK','VTI','Vistara'
  CALL AIRL 'SG','SEJ','SpiceJet'
  CALL AIRL 'IX','AXB','Air India Express'
  CALL AIRL 'PK','PIA','Pakistan Intl Airlines'
  CALL AIRL 'UL','ALK','SriLankan Airlines'
  CALL AIRL 'BG','BBC','Biman Bangladesh Airlines'
  CALL AIRL 'OM','MGL','MIAT Mongolian Airlines'
  CALL AIRL 'KC','KZR','Air Astana'
  CALL AIRL 'HY','UZB','Uzbekistan Airways'
  CALL AIRL 'QF','QFA','Qantas'
  CALL AIRL 'VA','VOZ','Virgin Australia'
  CALL AIRL 'JQ','JST','Jetstar Airways'
  CALL AIRL 'NZ','ANZ','Air New Zealand'
  CALL AIRL 'FJ','FJI','Fiji Airways'
  CALL AIRL 'TR','TGW','Scoot'
  CALL AIRL 'AK','AXM','AirAsia'
  CALL AIRL 'D7','XAX','AirAsia X'
  CALL AIRL 'QZ','AWQ','Indonesia AirAsia'
  CALL AIRL '5J','CEB','Cebu Pacific'
  CALL AIRL 'VJ','VJC','VietJet Air'
  CALL AIRL 'PG','BKP','Bangkok Airways'
  CALL AIRL 'DD','NOK','Nok Air'
  CALL AIRL 'FD','AIQ','Thai AirAsia'
  CALL AIRL 'JT','LNI','Lion Air'
  CALL AIRL 'ID','BTK','Batik Air'
  CALL AIRL 'QG','CTV','Citilink'
  CALL AIRL 'BI','RBA','Royal Brunei Airlines'
  CALL AIRL 'ET','ETH','Ethiopian Airlines'
  CALL AIRL 'SA','SAA','South African Airways'
  CALL AIRL 'KQ','KQA','Kenya Airways'
  CALL AIRL 'AT','RAM','Royal Air Maroc'
  CALL AIRL 'TU','TAR','Tunisair'
  CALL AIRL 'AH','DAH','Air Algerie'
  CALL AIRL 'WB','RWD','RwandAir'
  CALL AIRL 'DT','DTA','TAAG Angola Airlines'
  CALL AIRL 'MK','MAU','Air Mauritius'
  CALL AIRL 'HM','SEY','Air Seychelles'
  CALL AIRL 'P4','APG','Air Peace'
  RETURN
