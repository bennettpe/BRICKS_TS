/* GMTQ -- "Good Morning Text Query". Reads the GMTEXT configured */
/* in bricks.cnf via EXEC CICS INQUIRE SYSTEM GMMTEXT(var) and    */
/* echoes it to the terminal.                                     */
/*                                                                */
/* Usage:  GMTQ                                                   */
/*                                                                */
/* Demonstrates the bricks v1 INQUIRE SYSTEM verb. Currently      */
/* GMMTEXT is the only honoured option; future options (RELEASE,  */
/* CICSSTATUS, MAXTASKS, JOBNAME, APPLID, SYSID) will land on the */
/* same verb without source changes here.                         */

ADDRESS CICS

MSG = ''
EXEC CICS INQUIRE SYSTEM GMMTEXT(MSG) RESP(RC) END-EXEC

IF RC \= 0 THEN
  MSG = 'INQUIRE SYSTEM GMMTEXT failed; EIBRESP=' || RC || ' EIBRESP2=' || EIBRESP2

EXEC CICS SEND TEXT FROM(MSG) ERASE END-EXEC
EXEC CICS RETURN END-EXEC
