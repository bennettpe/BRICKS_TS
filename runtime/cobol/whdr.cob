      *> WHDR -- demonstration of EXEC CICS WEB WRITE HTTPHEADER /
      *> WEB READ HTTPHEADER on a client session (Phase 2b additions).
      *> Fetches GitHub's public /zen endpoint over HTTPS, attaches
      *> two custom request headers via WEB WRITE HTTPHEADER, then
      *> inspects three response headers via WEB READ HTTPHEADER.
      *>
      *>     1. WEB OPEN URIMAP('GITHUB') -- same URIMAP WZEN uses.
      *>     2. WEB WRITE HTTPHEADER('User-Agent') VALUE(...)
      *>     3. WEB WRITE HTTPHEADER('Accept') VALUE(...)
      *>     4. WEB CONVERSE -- GET /zen, one-shot send + receive.
      *>     5. WEB READ HTTPHEADER('Content-Type') -- always present.
      *>     6. WEB READ HTTPHEADER('Server') -- always present on
      *>        GitHub's CDN ("github.com").
      *>     7. WEB READ HTTPHEADER('X-No-Such-Header') -- returns
      *>        NOTFND so the program demonstrates that branch.
      *>     8. WEB CLOSE -- release the session.
      *>     9. SEND MAP -- render request + response headers + body.
      *>
      *> Showcases the round-trip: a program sets outbound headers
      *> via WRITE and inspects inbound headers via READ, branching
      *> on NOTFND for headers a particular response didn't emit.
      *>
      *> bricks.cnf: no extra knobs -- inherits web_client_timeout,
      *> the system CA bundle, and the GITHUB URIMAP row already in
      *> runtime/web_routes.conf.

       IDENTIFICATION DIVISION.
       PROGRAM-ID. WHDR.
       DATA DIVISION.
       WORKING-STORAGE SECTION.
       COPY DFHRESP.       *> RESP-NORMAL, RESP-NOTFND, ...
       COPY DFHWBSC.       *> DFHRESP-WB-OK, ...
       COPY DFHWBMETH.     *> WB-GET, WB-POST, ...
       COPY DFHWBSI.       *> DFH-WB-SESS, DFH-WB-BODY
       COPY DFHWBUH.       *> WB-CONTENT-TYPE, WB-USER-AGENT, ...

       01 STAT     PIC 9(4).
       01 CT       PIC X(64).
       01 SRV      PIC X(64).
       01 NONE     PIC X(64).
       01 SCR.
          05 HEADER   PIC X(78).
          05 URLLINE  PIC X(78).
          05 STATLN   PIC X(78).
          05 REQHDR   PIC X(78).
          05 REQH1    PIC X(78).
          05 REQH2    PIC X(78).
          05 RESHDR   PIC X(78).
          05 RESH1    PIC X(78).
          05 RESH2    PIC X(78).
          05 RESH3    PIC X(78).
          05 ZEN      PIC X(70).
          05 ERRMSG   PIC X(70).
          05 FOOTER   PIC X(60).

       PROCEDURE DIVISION.
       MAIN.
           MOVE SPACES TO HEADER.
           MOVE SPACES TO URLLINE.
           MOVE SPACES TO STATLN.
           MOVE SPACES TO REQHDR.
           MOVE SPACES TO REQH1.
           MOVE SPACES TO REQH2.
           MOVE SPACES TO RESHDR.
           MOVE SPACES TO RESH1.
           MOVE SPACES TO RESH2.
           MOVE SPACES TO RESH3.
           MOVE SPACES TO ZEN.
           MOVE SPACES TO ERRMSG.
           MOVE SPACES TO FOOTER.
           MOVE 'WHDR -- WEB WRITE/READ HTTPHEADER SESSTOKEN demo'
                                                          TO HEADER.
           MOVE 'GET https://api.github.com/zen (custom headers)'
                                                          TO URLLINE.
           MOVE 'Request headers sent:'                   TO REQHDR.
           MOVE 'Response headers read:'                  TO RESHDR.
           MOVE 'ENTER=Continue'                          TO FOOTER.

      *> ---- 1. Open the outbound session ----------------------
           EXEC CICS WEB OPEN URIMAP('GITHUB')
                              SESSTOKEN(DFH-WB-SESS) END-EXEC.
           IF EIBRESP NOT = DFHRESP-NORMAL GO TO OPENERR.

      *> ---- 2. Attach a custom User-Agent ----------------------
      *> Without this WRITE bricks would default to
      *> `bricks-cics/1.0`; the WRITE overrides that for this one
      *> session. Real APIs often require a non-default UA, and
      *> some (like GitHub's) reject the default with 403.
           EXEC CICS WEB WRITE HTTPHEADER('User-Agent')
                               VALUE('bricks-whdr/1.0')
                               SESSTOKEN(DFH-WB-SESS) END-EXEC.
           IF EIBRESP NOT = DFHRESP-NORMAL GO TO WRITEERR.
           MOVE '  User-Agent: bricks-whdr/1.0'           TO REQH1.

      *> ---- 3. Attach a content-negotiation Accept header ------
           EXEC CICS WEB WRITE HTTPHEADER('Accept')
                               VALUE('text/plain')
                               SESSTOKEN(DFH-WB-SESS) END-EXEC.
           IF EIBRESP NOT = DFHRESP-NORMAL GO TO WRITEERR.
           MOVE '  Accept: text/plain'                    TO REQH2.

      *> ---- 4. One-shot SEND + RECEIVE -------------------------
           EXEC CICS WEB CONVERSE SESSTOKEN(DFH-WB-SESS)
                                  METHOD(WB-GET)
                                  PATH('/zen')
                                  INTO(DFH-WB-BODY)
                                  STATUSCODE(STAT) END-EXEC.
           IF EIBRESP NOT = DFHRESP-NORMAL GO TO FETCHERR.

      *> ---- 5. Read Content-Type off the response --------------
           EXEC CICS WEB READ HTTPHEADER('Content-Type')
                              VALUE(CT)
                              SESSTOKEN(DFH-WB-SESS) END-EXEC.
           IF EIBRESP = DFHRESP-NORMAL THEN
               STRING '  Content-Type: ' CT DELIMITED BY SIZE
                      INTO RESH1
           ELSE
               MOVE '  Content-Type: (not present)'       TO RESH1
           END-IF.

      *> ---- 6. Read Server (always present on GitHub) ----------
           EXEC CICS WEB READ HTTPHEADER('Server')
                              VALUE(SRV)
                              SESSTOKEN(DFH-WB-SESS) END-EXEC.
           IF EIBRESP = DFHRESP-NORMAL THEN
               STRING '  Server: ' SRV DELIMITED BY SIZE
                      INTO RESH2
           ELSE
               MOVE '  Server: (not present)'             TO RESH2
           END-IF.

      *> ---- 7. Read a known-absent header (NOTFND branch) ------
           EXEC CICS WEB READ HTTPHEADER('X-No-Such-Header')
                              VALUE(NONE)
                              SESSTOKEN(DFH-WB-SESS) END-EXEC.
           IF EIBRESP = DFHRESP-NOTFND THEN
               MOVE '  X-No-Such-Header: NOTFND (as expected)'
                                                          TO RESH3
           ELSE
               STRING '  X-No-Such-Header: ' NONE DELIMITED BY SIZE
                      INTO RESH3
           END-IF.

      *> ---- 8. Release the session ----------------------------
           EXEC CICS WEB CLOSE SESSTOKEN(DFH-WB-SESS) END-EXEC.

      *> ---- 9. Render -----------------------------------------
           IF STAT NOT = DFHRESP-WB-OK GO TO HTTPERR.
           STRING 'HTTP ' STAT ' OK -- body excerpt:'
                  DELIMITED BY SIZE INTO STATLN.
           MOVE DFH-WB-BODY(1:70) TO ZEN.
           EXEC CICS SEND MAP('WHDR1') FROM(SCR) ERASE END-EXEC.
           EXEC CICS RETURN END-EXEC.

       OPENERR.
           STRING 'WEB OPEN failed -- EIBRESP=' EIBRESP
                  DELIMITED BY SIZE INTO ERRMSG.
           EXEC CICS SEND MAP('WHDR1') FROM(SCR) ERASE END-EXEC.
           EXEC CICS RETURN END-EXEC.

       WRITEERR.
           STRING 'WEB WRITE HTTPHEADER failed -- EIBRESP=' EIBRESP
                  DELIMITED BY SIZE INTO ERRMSG.
           EXEC CICS WEB CLOSE SESSTOKEN(DFH-WB-SESS) END-EXEC.
           EXEC CICS SEND MAP('WHDR1') FROM(SCR) ERASE END-EXEC.
           EXEC CICS RETURN END-EXEC.

       FETCHERR.
           STRING 'WEB CONVERSE failed -- EIBRESP=' EIBRESP
                  DELIMITED BY SIZE INTO ERRMSG.
           EXEC CICS WEB CLOSE SESSTOKEN(DFH-WB-SESS) END-EXEC.
           EXEC CICS SEND MAP('WHDR1') FROM(SCR) ERASE END-EXEC.
           EXEC CICS RETURN END-EXEC.

       HTTPERR.
           STRING 'HTTP ' STAT
                  ' -- api.github.com/zen unreachable or rate-limited'
                  DELIMITED BY SIZE INTO ERRMSG.
           EXEC CICS SEND MAP('WHDR1') FROM(SCR) ERASE END-EXEC.
           EXEC CICS RETURN END-EXEC.
           STOP RUN.
