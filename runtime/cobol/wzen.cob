      *> WZEN -- outbound EXEC CICS WEB client demo. Fetches GitHub's
      *> public /zen endpoint over HTTPS and renders the one-line
      *> response on a 3270 map.
      *>
      *>     1. WEB OPEN  -- HTTPS to api.github.com:443.
      *>     2. WEB CONVERSE -- GET /zen, one-shot send + receive.
      *>     3. WEB CLOSE -- release the session token.
      *>     4. SEND MAP  -- render the body (or an error message).
      *>
      *> No JSON parsing: /zen returns plain UTF-8. For richer demos
      *> see PROGRAMMING.md -- the same WEB CONVERSE shape accepts
      *> JSON bodies that COBOL splits with UNSTRING.
      *>
      *> bricks.cnf: no extra knobs needed -- web_client_timeout
      *> (default 30s) caps the round-trip; the shared *http.Client
      *> uses the host system's CA bundle to verify the
      *> api.github.com cert.

       IDENTIFICATION DIVISION.
       PROGRAM-ID. WZEN.
       DATA DIVISION.
       WORKING-STORAGE SECTION.
       COPY DFHRESP.       *> RESP-NORMAL, RESP-NOTFND, ...
       COPY DFHWBSC.       *> DFHRESP-WB-OK, -NOTFND, -UNAUTH ...
       COPY DFHWBMETH.     *> WB-GET / WB-POST / ...
       COPY DFHWBSI.       *> DFH-WB-SESS template

       01 STAT     PIC 9(4).
       01 SCR.
          05 HEADER   PIC X(78).
          05 URLLINE  PIC X(78).
          05 STATLN   PIC X(78).
          05 ZEN      PIC X(70).
          05 ERRMSG   PIC X(70).
          05 FOOTER   PIC X(60).

       PROCEDURE DIVISION.
       MAIN.
      *> Prime the screen so a later error path doesn't leave
      *> last-call garbage in fields the program won't touch.
           MOVE SPACES TO HEADER.
           MOVE SPACES TO URLLINE.
           MOVE SPACES TO STATLN.
           MOVE SPACES TO ZEN.
           MOVE SPACES TO ERRMSG.
           MOVE SPACES TO FOOTER.
           MOVE 'WZEN -- outbound EXEC CICS WEB client demo'
                                                          TO HEADER.
           MOVE 'GET https://api.github.com/zen'
                                                          TO URLLINE.
           MOVE 'ENTER=Continue'                          TO FOOTER.

      *> ---- 1. Open the outbound session ----------------------
      *> Phase 3a: URIMAP-aware form -- looks up the GITHUB row in
      *> web_routes.conf (URIMAP GITHUB https://api.github.com) so
      *> the host/scheme/port don't need to be hardcoded here. An
      *> operator can re-target the demo by editing one row.
           EXEC CICS WEB OPEN URIMAP('GITHUB')
                              SESSTOKEN(DFH-WB-SESS) END-EXEC.
           IF EIBRESP NOT = DFHRESP-NORMAL GO TO OPENERR.

      *> ---- 2. One-shot SEND + RECEIVE ------------------------
           EXEC CICS WEB CONVERSE SESSTOKEN(DFH-WB-SESS)
                                  METHOD(WB-GET)
                                  PATH('/zen')
                                  INTO(DFH-WB-BODY)
                                  STATUSCODE(STAT) END-EXEC.
           IF EIBRESP NOT = DFHRESP-NORMAL GO TO FETCHERR.

      *> ---- 3. Release the session ----------------------------
           EXEC CICS WEB CLOSE SESSTOKEN(DFH-WB-SESS) END-EXEC.

      *> ---- 4. Render the response ----------------------------
           IF STAT NOT = DFHRESP-WB-OK GO TO HTTPERR.
           STRING 'HTTP ' STAT ' OK    ('
                  '70-char body excerpt below)'
                  DELIMITED BY SIZE INTO STATLN.
      *> Reference modification: copy the first 70 chars of the
      *> 8192-byte body into the 70-char ZEN field.
           MOVE DFH-WB-BODY(1:70) TO ZEN.
           EXEC CICS SEND MAP('WZEN1') FROM(SCR) ERASE END-EXEC.
           EXEC CICS RETURN END-EXEC.

       OPENERR.
           STRING 'WEB OPEN failed -- EIBRESP=' EIBRESP
                  DELIMITED BY SIZE INTO ERRMSG.
           EXEC CICS SEND MAP('WZEN1') FROM(SCR) ERASE END-EXEC.
           EXEC CICS RETURN END-EXEC.

       FETCHERR.
           STRING 'WEB CONVERSE failed -- EIBRESP=' EIBRESP
                  DELIMITED BY SIZE INTO ERRMSG.
           EXEC CICS WEB CLOSE SESSTOKEN(DFH-WB-SESS) END-EXEC.
           EXEC CICS SEND MAP('WZEN1') FROM(SCR) ERASE END-EXEC.
           EXEC CICS RETURN END-EXEC.

       HTTPERR.
           STRING 'HTTP error ' STAT
                  ' -- api.github.com/zen unreachable or rate-limited'
                  DELIMITED BY SIZE INTO ERRMSG.
           EXEC CICS SEND MAP('WZEN1') FROM(SCR) ERASE END-EXEC.
           EXEC CICS RETURN END-EXEC.
           STOP RUN.
