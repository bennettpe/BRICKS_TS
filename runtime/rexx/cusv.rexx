/* CUSV -- customer-number validator. Invoked via                  */
/* EXEC CICS LINK PROGRAM('CUSV') COMMAREA(CUSTNO) from CUST.      */
/*                                                                 */
/* Reads the candidate customer number from DFHCOMMAREA, uppercases*/
/* and trims it, then writes the cleaned value back to DFHCOMMAREA */
/* so the caller's variable receives the normalised form.          */

ADDRESS CICS

DFHCOMMAREA = UPPER(STRIP(DFHCOMMAREA))
SAY 'CUSV: validated customer number =' DFHCOMMAREA

EXEC CICS RETURN END-EXEC
EXIT
