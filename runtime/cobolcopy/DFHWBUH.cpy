      *> DFHWBUH -- common HTTP header-name literals for EXEC CICS WEB.
      *>
      *> COPY DFHWBUH into WORKING-STORAGE, then use the named
      *> constants on the HTTPHEADER(...) option so a typo can't
      *> silently fail to match an inbound header:
      *>
      *>     EXEC CICS WEB READ HTTPHEADER(WB-CONTENT-TYPE)
      *>          VALUE(CT) END-EXEC.
      *>
      *>     EXEC CICS WEB WRITE HTTPHEADER(WB-CACHE-CONTROL)
      *>          VALUE('no-cache') END-EXEC.
       01 WB-CONTENT-TYPE     PIC X(20) VALUE 'Content-Type'.
       01 WB-CONTENT-LENGTH   PIC X(20) VALUE 'Content-Length'.
       01 WB-ACCEPT           PIC X(20) VALUE 'Accept'.
       01 WB-AUTHORIZATION    PIC X(20) VALUE 'Authorization'.
       01 WB-LOCATION         PIC X(20) VALUE 'Location'.
       01 WB-CACHE-CONTROL    PIC X(20) VALUE 'Cache-Control'.
       01 WB-USER-AGENT       PIC X(20) VALUE 'User-Agent'.
       01 WB-HOST             PIC X(20) VALUE 'Host'.
       01 WB-REFERER          PIC X(20) VALUE 'Referer'.
       01 WB-DATE             PIC X(20) VALUE 'Date'.
       01 WB-EXPIRES          PIC X(20) VALUE 'Expires'.
       01 WB-IFMODSINCE       PIC X(20) VALUE 'If-Modified-Since'.
       01 WB-IFNONEMATCH      PIC X(20) VALUE 'If-None-Match'.
       01 WB-ETAG             PIC X(20) VALUE 'ETag'.
