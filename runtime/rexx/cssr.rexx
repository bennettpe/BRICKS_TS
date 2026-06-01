/* CSSR -- "Sign-on Re-verify". Re-authenticates the signed-on user  */
/* against their own password before a privileged operation can      */
/* proceed. The verb under demo is EXEC CICS VERIFY PASSWORD.         */
/*                                                                   */
/* Usage:  CSSR                                                       */
/*                                                                   */
/* Operator pattern -- the canonical "type your password again"     */
/* gate that batch / SOAP entry points and sensitive screens use to  */
/* confirm the human at the keyboard before destroying records, even */
/* though the session is already signed on.                          */
/*                                                                   */
/* Three response codes:                                              */
/*   RESP=0  (NORMAL)  -- credentials matched; proceed.               */
/*   RESP=70 (NOTAUTH) -- bad credentials. Bricks does NOT distinguish*/
/*                       between "user doesn't exist" and "wrong     */
/*                       password" -- the same code surfaces for      */
/*                       both so callers can't username-enumerate    */
/*                       (see PROGRAMMING.md Chapter 6).              */
/*   RESP=16 (INVREQ)  -- USERID missing, or the dispatcher did not   */
/*                       wire a PasswordVerifier (operator misconfig).*/
/*                                                                   */
/* Production password-prompt pattern (vs. the prior demo): the      */
/* password is collected via SEND MAP / RECEIVE MAP on the CSSRPW    */
/* map, whose PASSWORD field is HIDDEN -- the operator's keystrokes  */
/* do NOT echo on the 3270 and shoulder-surfing is defeated. The      */
/* earlier "CSSR <password>" command-tail demo leaked the password   */
/* on the input pane and to CONS; do not copy that pattern.          */

ADDRESS CICS

/* The signed-on userid is the EIB-level USERID the dispatcher set   */
/* on this task -- the verb checks (USERID, PASSWORD) as a pair, so  */
/* we use the running user's id and re-verify against the typed pw. */
EXEC CICS ASSIGN USERID(USR) END-EXEC

/* Preload the map's USERID field with the signed-on userid so the   */
/* operator sees who is being re-verified. Clear PASSWORD so a       */
/* stale value from a prior task doesn't leak onto the screen.       */
MAP.USERID = USR
MAP.PASSWORD = ''

EXEC CICS SEND MAP('CSSRPW') FROM(MAP) ERASE END-EXEC
EXEC CICS RECEIVE MAP('CSSRPW') INTO(MAP) END-EXEC

/* PF3 (EIBAID = '3') cancels without verifying -- pseudo-                */
/* conversational courtesy. Any other AID falls through to VERIFY.   */
IF EIBAID = '3' THEN DO
  EXEC CICS SEND TEXT FROM('CSSR cancelled.') ERASE END-EXEC
  EXEC CICS RETURN END-EXEC
END

PWD = MAP.PASSWORD

/* Re-authenticate. RESP(RC) lets the IF read cleanly on the same    */
/* line instead of fishing through EIBRESP after the fact.           */
EXEC CICS VERIFY PASSWORD USERID(USR) PASSWORD(PWD) RESP(RC) END-EXEC

IF RC = 0 THEN DO
  MSG = 'Password OK. Privileged step authorised.'
END
ELSE IF RC = 70 THEN DO
  MSG = 'Bad credentials. Privileged step refused.'
END
ELSE DO
  MSG = 'VERIFY PASSWORD failed RESP=' || RC || ' RESP2=' || EIBRESP2
END

EXEC CICS SEND TEXT FROM(MSG) ERASE END-EXEC
EXEC CICS RETURN END-EXEC
EXIT
