      *> DFHWBSC -- EXEC CICS WEB HTTP status-code constants.
      *>
      *> COPY DFHWBSC into WORKING-STORAGE, then use the named
      *> constants instead of bare integer literals when emitting
      *> a response or comparing a response status:
      *>
      *>     EXEC CICS WEB SEND
      *>          STATUSCODE(DFHRESP-WB-OK)
      *>          FROM(BODY) MEDIATYPE('application/json')
      *>     END-EXEC.
      *>
      *>     EVALUATE STAT
      *>         WHEN DFHRESP-WB-OK        ...
      *>         WHEN DFHRESP-WB-NOTFND    ...
      *>     END-EVALUATE.
       01 DFHRESP-WB-OK          PIC 9(4) VALUE 200.
       01 DFHRESP-WB-CREATED     PIC 9(4) VALUE 201.
       01 DFHRESP-WB-NOCONTENT   PIC 9(4) VALUE 204.
       01 DFHRESP-WB-MOVED       PIC 9(4) VALUE 301.
       01 DFHRESP-WB-FOUND       PIC 9(4) VALUE 302.
       01 DFHRESP-WB-NOTMOD      PIC 9(4) VALUE 304.
       01 DFHRESP-WB-BADREQ      PIC 9(4) VALUE 400.
       01 DFHRESP-WB-UNAUTH      PIC 9(4) VALUE 401.
       01 DFHRESP-WB-FORBID      PIC 9(4) VALUE 403.
       01 DFHRESP-WB-NOTFND      PIC 9(4) VALUE 404.
       01 DFHRESP-WB-METHOD      PIC 9(4) VALUE 405.
       01 DFHRESP-WB-CONFLICT    PIC 9(4) VALUE 409.
       01 DFHRESP-WB-LENGREQ     PIC 9(4) VALUE 411.
       01 DFHRESP-WB-TOOLARGE    PIC 9(4) VALUE 413.
       01 DFHRESP-WB-INTERNAL    PIC 9(4) VALUE 500.
       01 DFHRESP-WB-NOTIMPL     PIC 9(4) VALUE 501.
       01 DFHRESP-WB-BADGW       PIC 9(4) VALUE 502.
       01 DFHRESP-WB-UNAVAIL     PIC 9(4) VALUE 503.
       01 DFHRESP-WB-GWTIME      PIC 9(4) VALUE 504.
