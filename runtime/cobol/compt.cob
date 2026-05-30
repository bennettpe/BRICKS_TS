      *> COMPT -- COMP-3 / packed-decimal end-to-end demo. Shows the
      *> canonical CICS ABSTIME pattern: ASKTIME drops the 15-digit
      *> ms-since-1900 timestamp into a PIC S9(15) COMP-3 carrier (the
      *> standard EIBABSTIME shape), then FORMATTIME peels off an
      *> 8-digit YYYYMMDD date from the same packed field. Bricks
      *> handles the BCD packing transparently — every byte except the
      *> last two nibbles is a digit pair; the trailing low nibble is
      *> the sign (C for the positive timestamp).
       IDENTIFICATION DIVISION.
       PROGRAM-ID. COMPT.

       DATA DIVISION.
       WORKING-STORAGE SECTION.
       01 SYS-DT     PIC S9(15) COMP-3.
       01 YYYYMMDD   PIC X(8).

       PROCEDURE DIVISION.
       MAIN.
           EXEC CICS ASKTIME ABSTIME(SYS-DT) END-EXEC.
           EXEC CICS FORMATTIME ABSTIME(SYS-DT)
                                YYYYMMDD(YYYYMMDD) END-EXEC.
           DISPLAY 'Today is ' YYYYMMDD.
           EXEC CICS RETURN END-EXEC.
           STOP RUN.
