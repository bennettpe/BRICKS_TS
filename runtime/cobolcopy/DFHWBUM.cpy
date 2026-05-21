      *> DFHWBUM -- URIMAP record fields for EXEC CICS WEB EXTRACT
      *> URIMAP(...). A URIMAP is a named entry in
      *> runtime/web_routes.conf that defines an outbound endpoint
      *> (scheme://host[:port][/path-prefix]); the WEB EXTRACT URIMAP
      *> verb writes its fields into the variables below so a
      *> program can inspect the resolved endpoint at runtime.
      *>
      *>     COPY DFHWBUM.
      *>     EXEC CICS WEB EXTRACT URIMAP('GITHUB')
      *>                    SCHEME(DFH-WB-UM-SCHEME)
      *>                    HOST(DFH-WB-UM-HOST)
      *>                    PORT(DFH-WB-UM-PORT)
      *>                    PATH(DFH-WB-UM-PATH) END-EXEC.
      *>
      *> Field widths are conservative — most URIMAP rows use
      *> hostnames well under 64 chars and path-prefixes under 128.
      *> Programs that need wider buffers declare their own.
       01 DFH-WB-UM-NAME    PIC X(8).
       01 DFH-WB-UM-SCHEME  PIC X(8).
       01 DFH-WB-UM-HOST    PIC X(64).
       01 DFH-WB-UM-PORT    PIC X(5).
       01 DFH-WB-UM-PATH    PIC X(128).
