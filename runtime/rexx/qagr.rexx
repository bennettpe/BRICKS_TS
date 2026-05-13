/* QAGR -- query age, result half. Pseudo-conversational follow-up to */
/* QAGE: RECEIVE the typed birthdate, validate, compute age in years  */
/* and exact days alive (DATE('B') basedate arithmetic), display the  */
/* QAGR1 result map, and RETURN to the bare prompt.                   */
/*                                                                    */
/* Validation failures redisplay QAGE1 with an error in MSG and chain */
/* back to QAGR so the operator can keep trying without retyping the  */
/* transid. PF3 on the redisplay still cancels (handled in qage.rexx  */
/* on the next chained dispatch).                                     */

ADDRESS CICS

EXEC CICS ASSIGN TERMID(TRM) END-EXEC

EXEC CICS RECEIVE MAP('QAGE1') END-EXEC

/* PF3 on the input screen has already short-circuited via qage.rexx; */
/* if we somehow get here on PF3, treat it the same way and bail.     */
IF C2X(EIBAID) = 'F3' THEN DO
  EXEC CICS RETURN END-EXEC
END

BY = STRIP(MAP.YEAR)
BM = STRIP(MAP.MONTH)
BD = STRIP(MAP.DAY)

ERR = ''
IF BY = '' | BM = '' | BD = '' THEN ERR = 'Year, month, and day are all required.'
ELSE IF \DATATYPE(BY,'W') | \DATATYPE(BM,'W') | \DATATYPE(BD,'W') THEN ERR = 'Year, month, and day must be whole numbers.'
ELSE DO
  BYI = BY + 0
  BMI = BM + 0
  BDI = BD + 0
  IF BYI < 1880 | BYI > 2200 THEN ERR = 'Year out of range (1880 - 2200).'
  ELSE IF BMI < 1 | BMI > 12 THEN ERR = 'Month must be 1 - 12.'
  ELSE IF BDI < 1 | BDI > 31 THEN ERR = 'Day must be 1 - 31.'
END

IF ERR = '' THEN DO
  /* Pad to YYYYMMDD for DATE('B', input, 'S'). Local names are kept    */
  /* distinct from the QAGR1 map field names (BIRTH, AGE, DAYS) so that */
  /* REXX compound-tail substitution doesn't rewrite OUT.BIRTH into     */
  /* OUT.<value-of-BIRTH> at SEND MAP time -- same trap cust.rexx warns */
  /* about with AKT vs ACTION etc.                                      */
  BSTR  = RIGHT(BYI,4,'0') || RIGHT(BMI,2,'0') || RIGHT(BDI,2,'0')
  TODAY = DATE('S')
  BBASE = DATE('B', BSTR, 'S')
  TBASE = DATE('B')
  NDAYS = TBASE - BBASE
  IF NDAYS < 0 THEN ERR = 'Birth date is in the future.'
END

IF ERR \= '' THEN DO
  /* Bounce back to QAGE1 with the error message. The map values for */
  /* the three input fields are not refilled -- operator just retypes. */
  SCR. = ''
  SCR.TERMID = TRM
  SCR.MSG    = ERR
  EXEC CICS SEND MAP('QAGE1') FROM(SCR.) ERASE END-EXEC
  IF C2X(EIBAID) = 'F3' THEN DO
    EXEC CICS RETURN END-EXEC
  END
  EXEC CICS RETURN TRANSID('QAGR') END-EXEC
END

/* Compute age in whole years: difference of years, minus one if the */
/* birthday has not yet occurred this year. Compare MMDD as MM*100+DD */
/* so we never have to think about month-end edge cases.             */
TY = LEFT(TODAY,4) + 0
TM = SUBSTR(TODAY,5,2) + 0
TD = RIGHT(TODAY,2) + 0
YRS = TY - BYI
IF (TM*100 + TD) < (BMI*100 + BDI) THEN YRS = YRS - 1

OUT. = ''
OUT.TERMID = TRM
OUT.BIRTH  = RIGHT(BYI,4,'0') || '-' || RIGHT(BMI,2,'0') || '-' || RIGHT(BDI,2,'0')
OUT.AGE    = YRS 'years'
OUT.DAYS   = NDAYS
EXEC CICS SEND MAP('QAGR1') FROM(OUT.) ERASE END-EXEC

EXEC CICS RETURN END-EXEC
EXIT
