      *> ESDC -- ESDS browse demo (COBOL twin of ESDR).
      *>
      *> Walks runtime/tmp/audit.log forward with READNEXT and
      *> backward with READPREV against the bricks tmp_dir sequential
      *> backend (PROGRAMMING.md Chapter 8a). PF8 pages down, PF7
      *> pages up, PF3 ends the browse and exits. Each ROW slot on
      *> the ESDS map carries one record formatted as:
      *>
      *>     <10-char zero-padded decimal RBA><two spaces><record>
      *>
      *> Two bricks deviations from real CICS ESDS are demonstrated:
      *>
      *>   1. Decimal-text RBA. On z/OS the canonical declaration is
      *>      PIC S9(8) COMP -- a 4-byte fullword. Bricks resolves
      *>      EXEC CICS host-variable references through the COBOL
      *>      frame as DISPLAY text, so RIDFLD must be a numeric
      *>      DISPLAY field (PIC 9(n)) rather than COMP -- the raw
      *>      binary fullword bytes do not parse as a non-negative
      *>      integer at the cics layer (startBrowseTmp calls
      *>      strconv.ParseInt on the resolved text). WS-RBA is
      *>      declared PIC 9(10) below so the canonical zero-padded
      *>      RBA text flows through STARTBR / READNEXT / READPREV /
      *>      RESETBR / READ FILE RIDFLD with no extra conversion.
      *>
      *>   2. LENGTH-as-buffer-capacity. On the tmp_dir backend
      *>      LENGTH(var) is INPUT (the program's buffer cap) +
      *>      OUTPUT (the ACTUAL record length, NOT the truncated
      *>      length). When a record exceeds WS-LEN, EIBRESP =
      *>      RESP-LENGERR, INTO is truncated to WS-LEN bytes, and
      *>      WS-LEN is overwritten with the untruncated record
      *>      length so the operator sees how much was lost. This
      *>      diverges from the KSDS LENGTH-output-only rule
      *>      (Chapter 8); see Chapter 8a "LENGTH semantics".
      *>
      *> ESDR (REXX) is the parallel twin against the same map; the
      *> TYPE field on the screen advertises which language is on
      *> screen so an operator alternating between them can tell at
      *> a glance.
       IDENTIFICATION DIVISION.
       PROGRAM-ID. ESDC.

       DATA DIVISION.
       WORKING-STORAGE SECTION.
       COPY DFHAID.
       COPY DFHRESP.

      *> ---- map IO group (matches esds.map field names) --------------
      *> Field names line up 1:1 with esds.map: INFOLINE banner,
      *> TYPE language tag, ROW1..ROW15 record slots. The map locks
      *> ROW count at 15, so PAGESIZE is fixed at 15 -- see the
      *> ASSIGN SCREENHT note in MAIN-PARA.
       01 SCR.
          05 INFOLINE PIC X(78).
          05 TYPE     PIC X(18).
          05 ROW1     PIC X(76).
          05 ROW2     PIC X(76).
          05 ROW3     PIC X(76).
          05 ROW4     PIC X(76).
          05 ROW5     PIC X(76).
          05 ROW6     PIC X(76).
          05 ROW7     PIC X(76).
          05 ROW8     PIC X(76).
          05 ROW9     PIC X(76).
          05 ROW10    PIC X(76).
          05 ROW11    PIC X(76).
          05 ROW12    PIC X(76).
          05 ROW13    PIC X(76).
          05 ROW14    PIC X(76).
          05 ROW15    PIC X(76).

      *> ---- RBA host variable ----------------------------------------
      *> WS-RBA is the bricks-flavoured decimal RBA. Bricks resolves
      *> EXEC CICS host-variable references through the COBOL frame
      *> as DISPLAY text, so RIDFLD targets must be `PIC 9(n)` (not
      *> `PIC S9(8) COMP`) -- the binary fullword bytes do not parse
      *> as a non-negative integer at the cics layer. PROGRAMMING.md
      *> Chapter 8a documents the deviation.
       01 WS-RBA      PIC 9(10)      VALUE ZEROS.

      *> WS-RBA written into each ROW slot. MOVE from one numeric to
      *> another right-aligns and zero-pads per IBM canonical rules
      *> -- same wire format the shared esds.map ROW layout expects.

      *> ---- READNEXT / READPREV scratch ------------------------------
      *> WS-LEN starts at 64 (the buffer cap = PIC X(64) of WS-REC)
      *> and bricks overwrites it on return with the ACTUAL record
      *> length. On LENGERR the INTO has been truncated to 64 bytes
      *> and WS-LEN holds the original record length -- see the
      *> LENGERR branch in READ-ONE. Display-form for the same
      *> reason as WS-RBA: bricks reads LENGTH as decimal text.
       01 WS-LEN      PIC 9(4)       VALUE 64.
       01 WS-REC      PIC X(64)      VALUE SPACES.

      *> ---- paging / page-state --------------------------------------
      *> WS-SH receives ASSIGN SCREENHT. WS-PAGESIZE stays at 15
      *> because the esds.map shared layout only owns ROW1..ROW15;
      *> mod-4 painting of 32 rows can't fit. The ASSIGN call is
      *> still made so the program teaches the verb and the value
      *> is reported in INFOLINE -- see the deviation note in
      *> MAIN-PARA.
       01 WS-SH       PIC 9(4)       VALUE 24.
       01 WS-PAGESIZE PIC 9(4)       VALUE 15.
       01 WS-SLOT     PIC 9(4)       VALUE ZERO.
       01 WS-COUNT    PIC 9(4)       VALUE ZERO.
       01 WS-I        PIC 9(4)       VALUE ZERO.

      *> ---- exit / state flags ---------------------------------------
       01 WS-EXIT     PIC X(1)       VALUE 'N'.
          88 EXITING                 VALUE 'Y'.
          88 RUNNING                 VALUE 'N'.

      *> END-OF-PAGE breaks the inner READNEXT/READPREV loop on
      *> ENDFILE, LENGERR-not-continuable, or SLOT=PAGESIZE.
       01 WS-EOP      PIC X(1)       VALUE 'N'.

      *> ---- formatting scratch ---------------------------------------
       01 WS-INFO     PIC X(78)      VALUE SPACES.
       01 WS-LINE     PIC X(76)      VALUE SPACES.
       01 WS-RESP     PIC 9(8)       VALUE ZERO.

       PROCEDURE DIVISION.

      *> ===============================================================
      *> MAIN-PARA -- open the browse, paint the first page, dispatch on
      *> AID until PF3.
      *> ===============================================================
       MAIN-PARA.
           MOVE 'COBOL' TO TYPE.

      *> ASSIGN SCREENHT is the IBM-canonical "tell me the terminal
      *> rows" verb. Bricks returns Sess.Rows (cics/handler.go's
      *> AssignField switch). A mod-4 (43-row) terminal would let a
      *> program paint 32 records per page; here the shared esds.map
      *> caps us at 15 ROW slots, so PAGESIZE stays at 15. The verb
      *> is preserved as the teaching example.
           EXEC CICS ASSIGN SCREENHT(WS-SH) END-EXEC.

      *> Open the browse at BOF (WS-RBA = 0). RIDFLD takes the
      *> resolved decimal text and bricks's tmp_dir backend
      *> ParseInts it -- see the header comment for the deviation
      *> from the z/OS-canonical PIC S9(8) COMP declaration.
           EXEC CICS STARTBR FILE('audit.log')
                             RIDFLD(WS-RBA) END-EXEC.
           IF EIBRESP NOT = RESP-NORMAL THEN
               GO TO STARTBR-FAILED
           END-IF.

           PERFORM PAINT-FORWARD.

      *> Pseudo-conversational shape would RETURN TRANSID after each
      *> SEND MAP; for a single-task browse demo we stay
      *> conversational so the STARTBR cursor lives for the whole
      *> session. The dispatcher's per-task ENDBR-on-cleanup would
      *> tidy up even if the operator aborts.
           PERFORM AID-LOOP UNTIL EXITING.

           EXEC CICS ENDBR FILE('audit.log') END-EXEC.
           EXEC CICS RETURN END-EXEC.
           STOP RUN.

      *> ===============================================================
      *> STARTBR-FAILED -- can't open the browse. Paint a single-page
      *> message with the RESP code and exit cleanly. No ENDBR because
      *> the cursor was never opened.
      *> ===============================================================
       STARTBR-FAILED.
           MOVE EIBRESP TO WS-RESP.
           MOVE SPACES  TO SCR.
           MOVE 'COBOL' TO TYPE.
           MOVE SPACES  TO WS-INFO.
           STRING 'STARTBR audit.log failed -- EIBRESP='
                                          DELIMITED BY SIZE
                  WS-RESP                 DELIMITED BY SIZE
                  ' (file missing? check runtime/tmp/)'
                                          DELIMITED BY SIZE
               INTO WS-INFO
           END-STRING.
           MOVE WS-INFO TO INFOLINE.
           EXEC CICS SEND MAP('ESDS') FROM(SCR) ERASE END-EXEC.
           EXEC CICS RECEIVE MAP('ESDS') INTO(SCR) END-EXEC.
           EXEC CICS RETURN END-EXEC.
           STOP RUN.

      *> ===============================================================
      *> AID-LOOP -- one round-trip per ENTER/PFn. Each pass: RECEIVE
      *> the current screen, decide direction, repaint or exit.
      *> ===============================================================
       AID-LOOP.
           EXEC CICS RECEIVE MAP('ESDS') INTO(SCR) END-EXEC.
      *> Per the bricks COBOL idiom (see gusl.cob), EVALUATE EIBAID
      *> dispatches on the AID byte using the DFHAID mnemonics --
      *> PF03 / PF07 / PF08 are the bricks short names; DFHPF3 /
      *> DFHPF7 / DFHPF8 are the IBM-traditional aliases for the
      *> same bytes (cobol_copybook_dual_names memory).
           EVALUATE EIBAID
               WHEN DFHPF3
                   MOVE 'Y' TO WS-EXIT
               WHEN DFHPF8
                   PERFORM PAINT-FORWARD
               WHEN DFHPF7
                   PERFORM PAINT-BACKWARD
               WHEN OTHER
                   PERFORM PAINT-FORWARD
           END-EVALUATE.

      *> ===============================================================
      *> PAINT-FORWARD -- read up to PAGESIZE records via READNEXT and
      *> SEND the map. INFOLINE is set by READ-ONE to either the
      *> running status, ENDFILE notice, or LENGERR detail.
      *> ===============================================================
       PAINT-FORWARD.
           PERFORM CLEAR-ROWS.
           MOVE 0    TO WS-SLOT.
           MOVE 0    TO WS-COUNT.
           MOVE 'N'  TO WS-EOP.
           MOVE SPACES TO WS-INFO.
           STRING 'ESDC -- audit.log  PF7=PageUp  PF8=PageDown  PF3=Exit'
                  DELIMITED BY SIZE
               INTO WS-INFO
           END-STRING.

           PERFORM READ-NEXT-ONE UNTIL WS-EOP = 'Y'
               OR WS-SLOT >= WS-PAGESIZE.

           MOVE WS-INFO TO INFOLINE.
           MOVE 'COBOL' TO TYPE.
           EXEC CICS SEND MAP('ESDS') FROM(SCR) ERASE END-EXEC.

      *> ===============================================================
      *> PAINT-BACKWARD -- step PAGESIZE records back via READPREV,
      *> then re-paint the new page with the forward orientation.
      *>
      *> The two-pass shape (READPREV PAGESIZE times to reposition;
      *> then READNEXT PAGESIZE times to render top-to-bottom) keeps
      *> ROW1 = oldest-on-page even when we arrive via PF7, matching
      *> the real-CICS convention. After the rewind the inline
      *> READNEXT block does the painting.
      *> ===============================================================
       PAINT-BACKWARD.
           MOVE 0   TO WS-I.
           MOVE 'N' TO WS-EOP.
           PERFORM READ-PREV-ONE UNTIL WS-EOP = 'Y'
               OR WS-I >= WS-PAGESIZE.

      *> If we hit BOF during the rewind, the cursor now sits at the
      *> first record and the next READNEXT will return record 1.
      *> Flag the BOF state for the painter's INFOLINE.
           IF WS-EOP = 'Y' THEN
               MOVE SPACES TO WS-INFO
               STRING 'TOP OF FILE -- PF8 to scroll forward'
                      DELIMITED BY SIZE
                   INTO WS-INFO
               END-STRING
           ELSE
               MOVE SPACES TO WS-INFO
               STRING 'ESDC -- audit.log  PF7=PageUp  PF8=PageDown  PF3=Exit'
                      DELIMITED BY SIZE
                   INTO WS-INFO
               END-STRING
           END-IF.

      *> Re-paint forward from the new position. Reuse PAINT-FORWARD's
      *> READNEXT-loop body but keep our INFOLINE -- so reset slot
      *> state and call READ-NEXT-ONE directly (PAINT-FORWARD would
      *> overwrite WS-INFO).
           PERFORM CLEAR-ROWS.
           MOVE 0   TO WS-SLOT.
           MOVE 0   TO WS-COUNT.
           MOVE 'N' TO WS-EOP.
           PERFORM READ-NEXT-ONE UNTIL WS-EOP = 'Y'
               OR WS-SLOT >= WS-PAGESIZE.

           MOVE WS-INFO TO INFOLINE.
           MOVE 'COBOL' TO TYPE.
           EXEC CICS SEND MAP('ESDS') FROM(SCR) ERASE END-EXEC.

      *> ===============================================================
      *> READ-NEXT-ONE -- one READNEXT iteration. Refreshes WS-LEN to
      *> the buffer cap before every call (bricks overwrites it on
      *> return) and handles NORMAL / LENGERR / ENDFILE / other RESPs.
      *> ===============================================================
       READ-NEXT-ONE.
      *> Refresh the input bound. Bricks writes the ACTUAL record
      *> length back into WS-LEN on every NORMAL / LENGERR return,
      *> so a stale (very large) value would suppress the LENGERR
      *> on the next read. Resetting to 64 every iteration keeps the
      *> contract honest.
           MOVE 64     TO WS-LEN.
           MOVE SPACES TO WS-REC.

           EXEC CICS READNEXT FILE('audit.log')
                              INTO(WS-REC)
                              RIDFLD(WS-RBA)
                              LENGTH(WS-LEN) END-EXEC.

           EVALUATE EIBRESP
               WHEN RESP-NORMAL
                   PERFORM PLACE-ROW
               WHEN RESP-LENGERR
      *> Truncation. WS-REC holds the first 64 bytes; WS-LEN now
      *> holds the actual (untruncated) record length -- a value
      *> larger than 64. Surface the truncation in INFOLINE and
      *> still paint the truncated row so the operator can see
      *> the leading bytes of the oversized record.
                   MOVE EIBRESP TO WS-RESP
                   MOVE SPACES  TO WS-INFO
                   STRING 'LENGERR -- record at RBA '
                                              DELIMITED BY SIZE
                          WS-RBA              DELIMITED BY SIZE
                          ' is '              DELIMITED BY SIZE
                          WS-LEN              DELIMITED BY SIZE
                          ' bytes (buffer 64); truncated'
                                              DELIMITED BY SIZE
                       INTO WS-INFO
                   END-STRING
                   PERFORM PLACE-ROW
               WHEN RESP-ENDFILE
                   MOVE 'Y' TO WS-EOP
                   MOVE SPACES TO WS-INFO
                   STRING 'END OF FILE -- PF7 to scroll back'
                          DELIMITED BY SIZE
                       INTO WS-INFO
                   END-STRING
               WHEN OTHER
      *> Surface the RESP value so an operator hitting a NOTFND /
      *> INVREQ / IOERR sees a numeric breadcrumb. Continue the
      *> loop -- the next iteration will hit the same RESP and
      *> bounce out via the SLOT cap.
                   MOVE EIBRESP TO WS-RESP
                   MOVE 'Y'     TO WS-EOP
                   MOVE SPACES  TO WS-INFO
                   STRING 'READNEXT failed -- EIBRESP='
                                              DELIMITED BY SIZE
                          WS-RESP             DELIMITED BY SIZE
                       INTO WS-INFO
                   END-STRING
           END-EVALUATE.

      *> ===============================================================
      *> READ-PREV-ONE -- one READPREV iteration used by PAINT-BACKWARD
      *> to step the cursor back PAGESIZE records. We don't paint the
      *> rewound rows -- the follow-up READNEXT pass does that.
      *> ===============================================================
       READ-PREV-ONE.
           MOVE 64     TO WS-LEN.
           MOVE SPACES TO WS-REC.

           EXEC CICS READPREV FILE('audit.log')
                              INTO(WS-REC)
                              RIDFLD(WS-RBA)
                              LENGTH(WS-LEN) END-EXEC.

           IF EIBRESP = RESP-NORMAL THEN
               ADD 1 TO WS-I
           END-IF.
           IF EIBRESP = RESP-LENGERR THEN
      *> A LENGERR on the rewind doesn't stop the rewind itself --
      *> we're only counting positions, not displaying. Still
      *> advance WS-I so PAGESIZE positions of motion are honoured.
               ADD 1 TO WS-I
           END-IF.
           IF EIBRESP = RESP-ENDFILE THEN
      *> Bricks reuses ENDFILE for both READNEXT-past-EOF and
      *> READPREV-past-BOF (PROGRAMMING.md Chapter 8a). Stop the
      *> rewind and let PAINT-BACKWARD render the BOF message.
               MOVE 'Y' TO WS-EOP
           END-IF.
           IF EIBRESP NOT = RESP-NORMAL
              AND EIBRESP NOT = RESP-LENGERR
              AND EIBRESP NOT = RESP-ENDFILE THEN
               MOVE 'Y' TO WS-EOP
           END-IF.

      *> ===============================================================
      *> PLACE-ROW -- format the current record into the next ROW slot.
      *> Layout per esds.map: 10-char zero-padded RBA, two spaces,
      *> then up to 64 bytes of record text. WS-RBA is already a
      *> 10-char DISPLAY field (right-aligned, zero-padded per IBM
      *> numeric-MOVE rules), so we can STRING it directly into the
      *> row buffer -- no intermediate redefinition needed.
      *> ===============================================================
       PLACE-ROW.
           ADD 1 TO WS-SLOT.
           ADD 1 TO WS-COUNT.
           MOVE SPACES  TO WS-LINE.
           STRING WS-RBA      DELIMITED BY SIZE
                  '  '        DELIMITED BY SIZE
                  WS-REC      DELIMITED BY SIZE
               INTO WS-LINE
           END-STRING.

      *> Fan-out the row into the matching ROWn slot. Without OCCURS
      *> on the SCR group (matches gusl.cob's shape so the parser is
      *> exercised the same way), the dispatch is an unrolled
      *> EVALUATE -- 15 WHEN branches, one per ROW field.
           EVALUATE WS-SLOT
               WHEN 1  MOVE WS-LINE TO ROW1
               WHEN 2  MOVE WS-LINE TO ROW2
               WHEN 3  MOVE WS-LINE TO ROW3
               WHEN 4  MOVE WS-LINE TO ROW4
               WHEN 5  MOVE WS-LINE TO ROW5
               WHEN 6  MOVE WS-LINE TO ROW6
               WHEN 7  MOVE WS-LINE TO ROW7
               WHEN 8  MOVE WS-LINE TO ROW8
               WHEN 9  MOVE WS-LINE TO ROW9
               WHEN 10 MOVE WS-LINE TO ROW10
               WHEN 11 MOVE WS-LINE TO ROW11
               WHEN 12 MOVE WS-LINE TO ROW12
               WHEN 13 MOVE WS-LINE TO ROW13
               WHEN 14 MOVE WS-LINE TO ROW14
               WHEN 15 MOVE WS-LINE TO ROW15
               WHEN OTHER CONTINUE
           END-EVALUATE.

      *> ===============================================================
      *> CLEAR-ROWS -- blank the 15 ROW slots before painting a new
      *> page. INFOLINE / TYPE are set by the caller.
      *> ===============================================================
       CLEAR-ROWS.
           MOVE SPACES TO ROW1.
           MOVE SPACES TO ROW2.
           MOVE SPACES TO ROW3.
           MOVE SPACES TO ROW4.
           MOVE SPACES TO ROW5.
           MOVE SPACES TO ROW6.
           MOVE SPACES TO ROW7.
           MOVE SPACES TO ROW8.
           MOVE SPACES TO ROW9.
           MOVE SPACES TO ROW10.
           MOVE SPACES TO ROW11.
           MOVE SPACES TO ROW12.
           MOVE SPACES TO ROW13.
           MOVE SPACES TO ROW14.
           MOVE SPACES TO ROW15.
