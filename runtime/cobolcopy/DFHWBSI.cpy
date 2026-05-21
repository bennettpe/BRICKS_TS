      *> DFHWBSI -- session-token template + length constants for
      *> the EXEC CICS WEB *outbound* client surface (WEB OPEN /
      *> SEND / RECEIVE / CONVERSE / CLOSE).
      *>
      *>     COPY DFHWBSI.
      *>
      *>     EXEC CICS WEB OPEN HOST('api.github.com') PORT(443)
      *>                    SCHEME('HTTPS')
      *>                    SESSTOKEN(DFH-WB-SESS) END-EXEC.
      *>
      *>     EXEC CICS WEB CONVERSE SESSTOKEN(DFH-WB-SESS)
      *>                    METHOD('GET') PATH('/zen')
      *>                    INTO(DFH-WB-BODY)
      *>                    STATUSCODE(STAT) END-EXEC.
      *>
      *>     EXEC CICS WEB CLOSE SESSTOKEN(DFH-WB-SESS) END-EXEC.
      *>
      *> Bricks issues a 32-hex-char token per WEB OPEN. The 36-byte
      *> field below leaves headroom for future UUID-shaped tokens.
       01 DFH-WB-SESS     PIC X(36).
      *> Buffer for inbound response bodies. Programs that expect
      *> larger payloads should declare their own PIC X(n) and
      *> cap with MAXLENGTH(n) on WEB CONVERSE / WEB RECEIVE.
       01 DFH-WB-BODY     PIC X(8192).
      *> URL buffer template -- a typical maximum for outbound
      *> request URLs. Programs that need longer URLs declare
      *> their own field.
       01 DFH-WB-URL      PIC X(2048).
