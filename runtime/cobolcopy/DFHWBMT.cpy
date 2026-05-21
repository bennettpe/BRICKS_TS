      *> DFHWBMT -- common Internet media-type (MIME) literals for
      *> EXEC CICS WEB SEND / WEB RECEIVE.
      *>
      *>     EXEC CICS WEB SEND FROM(BODY)
      *>          MEDIATYPE(WB-MT-JSON) END-EXEC.
       01 WB-MT-JSON      PIC X(32) VALUE 'application/json'.
       01 WB-MT-XML       PIC X(32) VALUE 'application/xml'.
       01 WB-MT-HTML      PIC X(32) VALUE 'text/html'.
       01 WB-MT-PLAIN     PIC X(32) VALUE 'text/plain'.
       01 WB-MT-FORM      PIC X(32)
                                VALUE 'application/x-www-form-urlencoded'.
       01 WB-MT-OCTET     PIC X(32) VALUE 'application/octet-stream'.
       01 WB-MT-CSV       PIC X(32) VALUE 'text/csv'.
       01 WB-MT-PDF       PIC X(32) VALUE 'application/pdf'.
