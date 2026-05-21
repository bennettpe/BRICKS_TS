      *> DFHDCDOC -- DOCUMENT API token + delimiter constants. The
      *> token is the program-visible handle EXEC CICS DOCUMENT
      *> CREATE returns; subsequent INSERT / RETRIEVE / DELETE /
      *> WEB SEND DOCTOKEN(t) thread it.
      *>
      *>     COPY DFHDCDOC.
      *>     EXEC CICS DOCUMENT CREATE DOCTOKEN(DFH-DOC-TOK) END-EXEC.
      *>     EXEC CICS DOCUMENT INSERT DOCTOKEN(DFH-DOC-TOK)
      *>                        FROM('<html>...</html>') END-EXEC.
      *>     EXEC CICS WEB SEND DOCTOKEN(DFH-DOC-TOK)
      *>                        MEDIATYPE('text/html')
      *>                        STATUSCODE(200) END-EXEC.
      *>
      *> Bricks issues a 32-hex-char token per DOCUMENT CREATE; the
      *> 36-byte field below matches the WEB session-token template
      *> in DFHWBSI for visual consistency.
       01 DFH-DOC-TOK        PIC X(36).
      *>
      *> Common SYMBOLLIST delimiters. CICS' default is `&` -- the
      *> HTML form-encoded form -- but programs that build CSV-like
      *> lists prefer `,` or `;` so the symbol-list parser can be
      *> told which separator to expect via DELIMITER(...).
       01 DFH-DOC-DEL-AMP    PIC X VALUE '&'.
       01 DFH-DOC-DEL-COMMA  PIC X VALUE ','.
       01 DFH-DOC-DEL-SEMI   PIC X VALUE ';'.
      *>
      *> DATAONLY is the literal CICS programs pass on RETRIEVE
      *> when they want the body bytes without the codepage
      *> conversion CICS would normally perform. Bricks is single-
      *> codepage ASCII so the flag is documentational only --
      *> RETRIEVE always returns the bytes verbatim. Kept here so
      *> programs ported from real CICS compile unchanged.
       01 DFH-DOC-DATAONLY   PIC X(8)  VALUE 'DATAONLY'.
