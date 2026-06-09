/* FUNC -- smoke test for the 4 new bricks REXX syntax additions.       */
/* Type FUNC at the prompt; it paints one PASS/FAIL line per feature.   */
/*   1. hex/binary string literals   'NN'X  /  'NN'B                     */
/*   2. internal function-call syntax  X = NAME(args)                   */
/*   3. PARSE VAR stem.tail  (dynamic compound tail resolution)         */
/*   4. whitespace-preserving PARSE  (verbatim remainder)               */

ADDRESS CICS

/* 1. hex/binary literals: 'F3'X is one byte 0xF3, '0110'B is 0x06.     */
T1 = 'FAIL'
IF C2X('F3'X) = 'F3' & C2X('0110'B) = '06' THEN T1 = 'PASS'

/* 2. internal function call: DBL is an internal PROCEDURE used as a fn. */
T2 = 'FAIL'
IF DBL(21) = 42 THEN T2 = 'PASS'

/* 3. PARSE VAR stem.tail: AIR.CODE resolves CODE='LAX' -> AIR.LAX.     */
AIR.LAX = 'Los Angeles'
CODE = 'LAX'
PARSE VAR AIR.CODE A1 A2
T3 = 'FAIL'
IF A1 = 'Los' & A2 = 'Angeles' THEN T3 = 'PASS'

/* 4. whitespace-preserving PARSE: the final var keeps the 2 spaces     */
/* between TWO and THREE (old PARSE collapsed them to one).             */
LINE = 'ONE TWO  THREE'
PARSE VAR LINE P1 PREST
T4 = 'FAIL'
IF P1 = 'ONE' & PREST = 'TWO  THREE' THEN T4 = 'PASS'

/* Paint the results as 80-column rows (SEND TEXT, no map).             */
TXT = LEFT('FUNC -- new REXX syntax smoke test', 80)
TXT = TXT || LEFT('', 80)
TXT = TXT || LEFT('1. hex / binary literals       ' || T1, 80)
TXT = TXT || LEFT('2. internal function call      ' || T2, 80)
TXT = TXT || LEFT('3. PARSE VAR stem.tail         ' || T3, 80)
TXT = TXT || LEFT('4. whitespace-preserving PARSE ' || T4, 80)
TXT = TXT || LEFT('', 80)
TXT = TXT || LEFT('Press CLEAR to exit.', 80)

EXEC CICS SEND TEXT FROM(TXT) ERASE END-EXEC
EXEC CICS RETURN END-EXEC
EXIT

/* -- internal routine, callable as a function (feature 2) ------------ */
DBL: PROCEDURE
  PARSE ARG N
  RETURN N * 2
