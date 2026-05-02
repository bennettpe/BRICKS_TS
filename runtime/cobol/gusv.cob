      *> GUSV -- COBOL twin of cusv.rexx. Customer-number validator,
      *> invoked via EXEC CICS LINK PROGRAM('GUSV') COMMAREA(...) from
      *> GUST. Reads the candidate customer number from DFHCOMMAREA,
      *> uppercases it, and writes the cleaned form back. The dispatcher
      *> rstrips the COBOL frame's DFHCOMMAREA on the way out, so the
      *> trailing-space behaviour matches the REXX twin's STRIP exactly.
       IDENTIFICATION DIVISION.
       PROGRAM-ID. GUSV.

       DATA DIVISION.
       WORKING-STORAGE SECTION.
       01 KEY-IN PIC X(8).

       PROCEDURE DIVISION.
       MAIN.
           MOVE FUNCTION UPPER-CASE(DFHCOMMAREA) TO KEY-IN.
           DISPLAY 'GUSV: validated customer number = ' KEY-IN.
           MOVE KEY-IN TO DFHCOMMAREA.
           EXEC CICS RETURN END-EXEC.
           STOP RUN.
