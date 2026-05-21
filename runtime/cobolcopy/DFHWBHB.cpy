      *> DFHWBHB -- header-browse helper variables for EXEC CICS WEB
      *> STARTBROWSE/READNEXT/ENDBROWSE HTTPHEADER. Works for both
      *> the server-side (inbound request) and client-side (response,
      *> with SESSTOKEN) browse forms -- the variable shapes are the
      *> same; the verb shapes are what differs.
      *>
      *>     COPY DFHWBHB.
      *>     EXEC CICS WEB STARTBROWSE HTTPHEADER END-EXEC.
      *>     PERFORM UNTIL EIBRESP = DFHRESP-ENDFILE
      *>         EXEC CICS WEB READNEXT HTTPHEADER
      *>                       NAME(DFH-WB-HDR-NAME)
      *>                       NAMELENGTH(DFH-WB-HDR-NL)
      *>                       VALUE(DFH-WB-HDR-VAL)
      *>                       VALUELENGTH(DFH-WB-HDR-VL)
      *>         END-EXEC
      *>         IF EIBRESP = DFHRESP-NORMAL
      *>             *> consume DFH-WB-HDR-NAME / DFH-WB-HDR-VAL
      *>         END-IF
      *>     END-PERFORM.
      *>     EXEC CICS WEB ENDBROWSE HTTPHEADER END-EXEC.
      *>
      *> Field widths match the common HTTP header limits (64 chars
      *> for the name, 256 for the value). Programs that handle
      *> Set-Cookie or other wide-value headers declare their own.
       01 DFH-WB-HDR-NAME  PIC X(64).
       01 DFH-WB-HDR-NL    PIC 9(4)  COMP.
       01 DFH-WB-HDR-VAL   PIC X(256).
       01 DFH-WB-HDR-VL    PIC 9(4)  COMP.
