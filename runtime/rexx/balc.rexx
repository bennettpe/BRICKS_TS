/* BALC -- runtime per-field colour override demo.                 */
/* Paints the map's STATUS field GREEN when the balance is in      */
/* funds, RED when overdrawn, by assigning SCR.STATUS_C before the */
/* SEND MAP. The map's COLOR= default loses to the runtime value.  */
/* After ENTER the program re-sends STATUS in TURQUOISE.           */
/*                                                                 */
/* CAVEAT: REXX evaluates stem tails by VALUE, not literal. If     */
/* anywhere in this program we assigned a bare variable STATUS_C,  */
/* then SCR.STATUS_C = 'RED' would bind to the VALUE of STATUS_C   */
/* instead of the literal tail. We never assign STATUS_C as a      */
/* bare symbol on purpose. The defensive form is the quoted tail:  */
/* SCR.'STATUS_C' = 'RED'.                                         */

ADDRESS CICS

BALANCE = 1500
SCR.BALOUT = 'BAL  1500.00'
IF BALANCE > 1000 THEN DO
   SCR.STATUS   = 'IN-FUNDS'
   SCR.STATUS_C = 'GREEN'
END
ELSE DO
   SCR.STATUS   = 'OVERDRAWN'
   SCR.STATUS_C = 'RED'
END

EXEC CICS SEND MAP('BALC') FROM(SCR.) ERASE END-EXEC
EXEC CICS RECEIVE MAP('BALC') INTO(SCR.) END-EXEC

/* PF03 quits; anything else flips the colour to TURQUOISE. */
IF EIBAID = 'F3'X THEN DO
   EXEC CICS RETURN END-EXEC
END

SCR.STATUS_C = 'TURQUOISE'
EXEC CICS SEND MAP('BALC') FROM(SCR.) END-EXEC
EXEC CICS RETURN END-EXEC

EXIT
