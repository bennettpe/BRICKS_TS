/* HELO -- query the EIB and greet the user using IBM-canonical    */
/* EXEC CICS  END-EXEC syntax. Maps carry no static text; every   */
/* visible string is supplied by this program via SEND MAP FROM.   */
/*                                                                 */
/* Adapts to terminal model:                                       */
/*   mod 2 (24x80)  → SEND MAP('HELO1')                            */
/*   mod 3 (32x80)  → SEND MAP('HELO1M')  [if HELO1M exists]       */
/*   mod 4 (43x80)  → SEND MAP('HELO1L')  with bonus info panes    */
/*   mod 5 (27x132) → SEND MAP('HELO1W')  [if HELO1W exists]       */
/*                                                                 */
/* The mod-2 map ignores tails it doesn't declare, so the program  */
/* always populates the bonus tails  they only render where the   */
/* mod-4 map's named fields exist. MAPFAIL (RESP=36) on a missing  */
/* sized variant falls back to the unsuffixed mod-2 map.           */

ADDRESS CICS

EXEC CICS ASSIGN USERID(USR) TERMID(TRM) CONNECTED(CT)
                 SCREENHT(SCRH) SCREENWD(SCRW) END-EXEC

/* Classify the terminal model up front so we can reuse the label  */
/* in the info pane below. Largest-first so a mod-3 connection     */
/* isn't misclassified as mod-4.                                   */
IF SCRH >= 43 THEN MDL = 'mod 4'
ELSE IF SCRH >= 32 THEN MDL = 'mod 3'
ELSE IF SCRW >= 132 THEN MDL = 'mod 5'
ELSE MDL = 'mod 2'

/* Common slots  visible on both mod-2 and mod-4. */
SCR. = ''
SCR.INFOLINE = 'USER:' USR '  TERMID:' TRM '  CONNECTED:' CT
SCR.GREETING = 'HELLO, ' || USR || '!'
SCR.FOOTER   = 'ENTER=Continue'

/* Bonus slots  only painted by the mod-4 (and bigger) maps.      */
SCR.INFO1 = 'Screen size:' SCRH 'rows x' SCRW 'cols   (' || MDL || ')'
SCR.INFO2 = 'Terminal id:' TRM '   User id:' USR
SCR.INFO3 = 'Connection time:' CT
SCR.ACT1  = 'No activity yet on this terminal.'
SCR.ACT2  = ''
SCR.ACT3  = ''

/* Build a model-suffixed map name; same fence order as MDL above.  */
SUFFIX = ''
IF SCRH >= 43 THEN SUFFIX = 'L'
ELSE IF SCRH >= 32 THEN SUFFIX = 'M'
ELSE IF SCRW >= 132 THEN SUFFIX = 'W'

MAPNAME = 'HELO1' || SUFFIX

EXEC CICS SEND MAP(MAPNAME) FROM(SCR.) ERASE END-EXEC
IF EIBRESP = 36 THEN DO
  /* MAPFAIL: sized variant absent — fall back to the mod-2 map. */
  EXEC CICS SEND MAP('HELO1') FROM(SCR.) ERASE END-EXEC
END

EXEC CICS RETURN END-EXEC

EXIT
