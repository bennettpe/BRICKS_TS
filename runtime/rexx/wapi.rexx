/* WAPI -- minimal REST API demo. Dispatched by the inbound HTTP   */
/* listener via runtime/web_routes.conf:                            */
/*                                                                  */
/*     GET /api/customer/{id}  WAPI  public                         */
/*                                                                  */
/* The {id} placeholder is captured into the same query-parameter   */
/* namespace as a `?id=...` query string, so WEB READ QUERYPARM     */
/* reads either form. Returns a JSON document; the response builder */
/* is hand-rolled string concatenation (REXX has no JSON library —  */
/* the standard idiom in bricks samples).                           */
/*                                                                  */
/* On a missing/blank id  -> 400 with a JSON error body.            */
/* On EIBRESP from READ FILE -> 404 (record not found).             */
/*                                                                  */
/* Note on EXEC CICS line layout: do NOT use REXX `,` continuation  */
/* inside EXEC CICS … END-EXEC. The REXX interpreter collects the   */
/* command body verbatim until END-EXEC, so a trailing comma slips  */
/* through to the CICS command parser as a literal token. Wrap      */
/* options across multiple lines with plain whitespace instead.     */

ADDRESS CICS

/* ---- 1. Read the path / query parameter ---- */
EXEC CICS WEB READ QUERYPARM('id') VALUE(CID) END-EXEC
IF EIBRESP = 13 | LENGTH(STRIP(CID)) = 0 THEN DO
  ERR = '{"error":"missing id"}'
  EXEC CICS WEB SEND STATUSCODE(400) FROM(ERR) MEDIATYPE('application/json') END-EXEC
  EXEC CICS RETURN END-EXEC
END

/* ---- 2. Pull the customer record from the VSAM file ---- */
/* The CUSTOMERS file is the same one CUST / GUST samples drive.   */
/* Record format: NM|AD|CY|PH (pipe-delimited).                    */
EXEC CICS READ FILE('CUSTOMERS') INTO(REC) RIDFLD(CID) END-EXEC
IF EIBRESP \= 0 THEN DO
  ERR = '{"error":"customer not found"}'
  EXEC CICS WEB SEND STATUSCODE(404) FROM(ERR) MEDIATYPE('application/json') END-EXEC
  EXEC CICS RETURN END-EXEC
END

/* ---- 3. Build the JSON response body ---- */
PARSE VAR REC NM '|' AD '|' CY '|' PH
NM = STRIP(NM)
CY = STRIP(CY)
PH = STRIP(PH)
BODY = '{"id":"' || CID || '","name":"' || NM || '","city":"' || CY || '","phone":"' || PH || '"}'

/* ---- 4. Emit. WRITE HTTPHEADER sets an outbound header; SEND   */
/*       writes status + body. The handler appends any subsequent */
/*       SEND in the same task, but a single SEND is the norm.    */
EXEC CICS WEB WRITE HTTPHEADER('Cache-Control') VALUE('no-cache') END-EXEC
EXEC CICS WEB SEND FROM(BODY) MEDIATYPE('application/json') END-EXEC

EXEC CICS RETURN END-EXEC
EXIT
