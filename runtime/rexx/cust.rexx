/* CUST -- customer file maintenance.                              */
/* Conversational transaction; loops on the menu screen.           */
/* Demonstrates EXEC CICS SEND, RECEIVE, LINK PROGRAM, READ,       */
/* WRITE, REWRITE, DELETE, STARTBR / READNEXT / ENDBR (via CUSL).  */
/*                                                                 */
/* The 'customers' file is a KSDS (key-sequenced) backed by a      */
/* B+tree, so READ/WRITE/REWRITE/DELETE are O(log n) and STARTBR + */
/* READNEXT walk records in key order. The on-disk record format   */
/* (name|addr|city|phone) is chosen here, by the application —     */
/* bricks stores record bodies opaquely.                           */
/*                                                                 */
/* Note: variables are deliberately named distinctly from map      */
/* field tail symbols (AKT vs ACTION, CKEY vs CUSTNO, NM/AD/CY/PH  */
/* vs NAME/ADDRESS/CITY/PHONE) so that REXX compound-tail          */
/* substitution does not turn DET.CUSTNO = CKEY into DET.<value>.  */

ADDRESS CICS

EXEC CICS ASSIGN USERID(USR) TERMID(TRM) SCREENHT(SCRH) END-EXEC

/* Suffix the map family by terminal model so a mod-4 (43-row) screen */
/* renders the wider CUST1L / CUST2L variants. mod 2 keeps the bare   */
/* names. MAPFAIL on a missing sized variant falls back to mod 2.     */
SUFFIX = ''
IF SCRH >= 43 THEN SUFFIX = 'L'
M_MENU   = 'CUST1' || SUFFIX
M_DETAIL = 'CUST2' || SUFFIX

/* Initialise the menu stem ONCE, outside the loop. SCR.MSG is set by */
/* each action below and carries through to the next iteration's      */
/* SEND so the operator sees "Customer 100 added." / "Query of 100    */
/* complete." etc. Resetting the stem at loop-top would erase the     */
/* message before it could be painted.                                */
SCR. = ''
SCR.INFOLINE = 'User:' USR '                           Term:' TRM

DO FOREVER
  EXEC CICS SEND MAP(M_MENU) FROM(SCR.) ERASE END-EXEC
  IF EIBRESP = 36 THEN DO
    M_MENU = 'CUST1'
    EXEC CICS SEND MAP(M_MENU) FROM(SCR.) ERASE END-EXEC
  END
  EXEC CICS RECEIVE MAP(M_MENU) END-EXEC

  /* PF12 from the menu screen exits the transaction immediately.       */
  /* C2X returns the AID byte as 2-char hex; PF12 = 0x7C.               */
  IF C2X(EIBAID) = '7C' THEN DO
    EXEC CICS RETURN END-EXEC
  END

  AKT  = UPPER(STRIP(MAP.ACTION))
  CKEY = UPPER(STRIP(MAP.CUSTNO))
  SRCH = STRIP(MAP.SEARCH)

  IF AKT = '' THEN DO
    SCR.MSG = 'Action required (A/Q/U/D/L/S, F12=exit).'
  END
  ELSE IF AKT \= 'A' & AKT \= 'Q' & AKT \= 'U' & AKT \= 'D' & AKT \= 'L' & AKT \= 'S' THEN DO
    SCR.MSG = 'Unknown action:' AKT
  END
  ELSE IF AKT \= 'L' & AKT \= 'S' & CKEY = '' THEN DO
    SCR.MSG = 'Customer # required.'
  END
  ELSE DO
    /* Validate the customer number via LINK to CUSV (skip for L and S — */
    /* listing/searching does not need a key). CUSV uppercases           */
    /* DFHCOMMAREA and writes a status string back; CUST reads the       */
    /* normalised value via COMMAREA(CKEY).                              */
    IF AKT \= 'L' & AKT \= 'S' THEN DO
      EXEC CICS LINK PROGRAM('CUSV') COMMAREA(CKEY) END-EXEC
    END

    SELECT
      WHEN AKT = 'A' THEN DO
        DET. = ''
        DET.CUSTNO = CKEY
        DET.MODE   = 'Mode: ADD -- fill in fields and press ENTER.'
        EXEC CICS SEND MAP(M_DETAIL) FROM(DET.) ERASE END-EXEC
        IF EIBRESP = 36 THEN DO
          M_DETAIL = 'CUST2'
          EXEC CICS SEND MAP(M_DETAIL) FROM(DET.) ERASE END-EXEC
        END
        EXEC CICS RECEIVE MAP(M_DETAIL) END-EXEC
        REC = STRIP(MAP.NAME) || '|' || STRIP(MAP.ADDRESS) || '|' || STRIP(MAP.CITY) || '|' || STRIP(MAP.PHONE)
        EXEC CICS WRITE FILE('customers') FROM(REC) RIDFLD(CKEY) END-EXEC
        IF EIBRESP = 14 THEN SCR.MSG = 'Customer' CKEY 'already exists.'
        ELSE IF EIBRESP \= 0 THEN SCR.MSG = 'WRITE failed RESP=' || EIBRESP
        ELSE SCR.MSG = 'Customer' CKEY 'added.'
      END

      WHEN AKT = 'Q' THEN DO
        EXEC CICS READ FILE('customers') INTO(REC) RIDFLD(CKEY) END-EXEC
        IF EIBRESP = 13 THEN DO
          SCR.MSG = 'Customer' CKEY 'not found.'
        END
        ELSE IF EIBRESP \= 0 THEN DO
          SCR.MSG = 'READ failed RESP=' || EIBRESP
        END
        ELSE DO
          PARSE VAR REC NM '|' AD '|' CY '|' PH
          DET. = ''
          DET.CUSTNO  = CKEY
          DET.NAME    = NM
          DET.ADDRESS = AD
          DET.CITY    = CY
          DET.PHONE   = PH
          DET.MODE    = 'Mode: QUERY -- press ENTER to return to the menu.'
          EXEC CICS SEND MAP('CUST2') FROM(DET.) ERASE END-EXEC
          EXEC CICS RECEIVE MAP('CUST2') END-EXEC
          SCR.MSG = 'Query of' CKEY 'complete.'
        END
      END

      WHEN AKT = 'U' THEN DO
        EXEC CICS READ FILE('customers') INTO(REC) RIDFLD(CKEY) UPDATE END-EXEC
        IF EIBRESP = 13 THEN DO
          SCR.MSG = 'Customer' CKEY 'not found.'
        END
        ELSE IF EIBRESP \= 0 THEN DO
          SCR.MSG = 'READ UPDATE failed RESP=' || EIBRESP
        END
        ELSE DO
          PARSE VAR REC NM '|' AD '|' CY '|' PH
          DET. = ''
          DET.CUSTNO  = CKEY
          DET.NAME    = NM
          DET.ADDRESS = AD
          DET.CITY    = CY
          DET.PHONE   = PH
          DET.MODE    = 'Mode: UPDATE -- modify and press ENTER.'
          EXEC CICS SEND MAP('CUST2') FROM(DET.) ERASE END-EXEC
          EXEC CICS RECEIVE MAP('CUST2') END-EXEC
          REC = STRIP(MAP.NAME) || '|' || STRIP(MAP.ADDRESS) || '|' || STRIP(MAP.CITY) || '|' || STRIP(MAP.PHONE)
          EXEC CICS REWRITE FILE('customers') FROM(REC) END-EXEC
          IF EIBRESP \= 0 THEN SCR.MSG = 'REWRITE failed RESP=' || EIBRESP
          ELSE SCR.MSG = 'Customer' CKEY 'updated.'
        END
      END

      WHEN AKT = 'D' THEN DO
        EXEC CICS DELETE FILE('customers') RIDFLD(CKEY) END-EXEC
        IF EIBRESP = 13 THEN SCR.MSG = 'Customer' CKEY 'not found.'
        ELSE IF EIBRESP \= 0 THEN SCR.MSG = 'DELETE failed RESP=' || EIBRESP
        ELSE SCR.MSG = 'Customer' CKEY 'deleted.'
      END

      WHEN AKT = 'L' THEN DO
        /* CUSL writes the match count back into the COMMAREA variable   */
        /* on return; CMSG carries 'filter in / count out'.              */
        CMSG = ''
        EXEC CICS LINK PROGRAM('CUSL') COMMAREA(CMSG) END-EXEC
        IF CMSG = '0' THEN SCR.MSG = 'No customers in file.'
        ELSE SCR.MSG = 'List complete (' || CMSG || ' records).'
      END

      WHEN AKT = 'S' THEN DO
        /* Pass the search term through DFHCOMMAREA on the way in; CUSL */
        /* writes the match count back into the same variable.          */
        CMSG = SRCH
        EXEC CICS LINK PROGRAM('CUSL') COMMAREA(CMSG) END-EXEC
        IF SRCH = '' THEN DO
          IF CMSG = '0' THEN SCR.MSG = 'No customers in file.'
          ELSE SCR.MSG = 'List complete (' || CMSG || ' records).'
        END
        ELSE IF CMSG = '0' THEN SCR.MSG = 'No matching records found.'
        ELSE SCR.MSG = 'Search:' SRCH '(' || CMSG || ' matches)'
      END

      OTHERWISE
        SCR.MSG = 'Internal error: action' AKT 'fell through.'
    END
  END
END

EXIT
