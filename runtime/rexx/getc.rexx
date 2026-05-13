/* GETC -- get customer.                                                */
/* Usage:  GETC <customer-number>                                       */
/*                                                                      */
/* Reads the operator's command line via EXEC CICS RECEIVE INTO(...),   */
/* takes the SECOND token as the customer number (the first being the   */
/* transid GETC itself), READs the 'customers' file, and paints the     */
/* details with EXEC CICS SEND TEXT -- no map.                          */
/*                                                                      */
/* 3270 has no line feed: SEND TEXT lays out its FROM buffer as a flat  */
/* row-major byte array (cols=80 chars per row by default). To get      */
/* multi-line output we LEFT-pad each logical line to 80 chars and      */
/* concatenate -- never embed '0A'X / '\n' / X'15' newlines.            */
/*                                                                      */
/* Companion to runtime/rexx/cust.rexx (full menu) and                  */
/* runtime/cobol/exam.cob (the same RECEIVE INTO pattern in COBOL).     */

ADDRESS CICS

/* RECEIVE INTO returns the unedited prompt line, e.g. "GETC 100".      */
/* EOC (RESP=6) means we were chained from another transaction without  */
/* a fresh user-typed command -- bail with a hint.                      */
EXEC CICS RECEIVE INTO(BUF) END-EXEC
IF EIBRESP = 6 THEN DO
  EXEC CICS SEND TEXT FROM('GETC: nothing to read (chained dispatch).') ERASE END-EXEC
  EXEC CICS RETURN END-EXEC
END

/* PARSE peels TID=GETC, CKEY=<custno>, '.' eats any extra trailing args.*/
PARSE VAR BUF TID CKEY .
CKEY = STRIP(CKEY)

IF CKEY = '' THEN DO
  EXEC CICS SEND TEXT FROM('Usage: GETC <customer-number>') ERASE END-EXEC
  EXEC CICS RETURN END-EXEC
END

/* Application record format (set by cust.rexx on WRITE):               */
/*   name|addr|city|phone                                               */
EXEC CICS READ FILE('customers') INTO(REC) RIDFLD(CKEY) END-EXEC
IF EIBRESP = 13 THEN DO
  MSG = 'Customer' CKEY 'not found.'
  EXEC CICS SEND TEXT FROM(MSG) ERASE END-EXEC
  EXEC CICS RETURN END-EXEC
END
IF EIBRESP \= 0 THEN DO
  MSG = 'READ failed RESP=' || EIBRESP
  EXEC CICS SEND TEXT FROM(MSG) ERASE END-EXEC
  EXEC CICS RETURN END-EXEC
END

PARSE VAR REC NM '|' AD '|' CY '|' PH

/* Build the page as 80-char rows concatenated into one buffer. Each    */
/* LEFT(...,80) pads the row to the column width so the next row starts */
/* exactly at column 0 of the next line under the auto-wrap layout.     */
TXT = LEFT('Customer details for #' || CKEY, 80)
TXT = TXT || LEFT('', 80)
TXT = TXT || LEFT('Name:    ' || NM, 80)
TXT = TXT || LEFT('Address: ' || AD, 80)
TXT = TXT || LEFT('City:    ' || CY, 80)
TXT = TXT || LEFT('Phone:   ' || PH, 80)
TXT = TXT || LEFT('', 80)
TXT = TXT || LEFT('Press ENTER to continue.', 80)

EXEC CICS SEND TEXT FROM(TXT) ERASE END-EXEC
EXEC CICS RETURN END-EXEC
EXIT
