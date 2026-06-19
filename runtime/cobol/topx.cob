      *> TOPX -- read-only broswer for the  BBS topics database.
       *> Pseudo-convesational port of 3270BBSs topic.go (topics list +
      *> topic view) for Mod2  and Mod 4 terms
      *> Maps TOPL2/TOPL4 (list) and TOPV2/TOPV4 (view) reprduce the
      *> 3270BBS go3270 layout verbatim; write actions (reply, like, add
      *> topic) are intentionally absent and no INSERT/UPDATE/DELETE
       *> is issued anywhere -- not even 3270BBS view_count add, 
       *> so all the views from BRICKS go uncounted
      *>
      *> State machine: ST-SCREEN 'L' (topics list) / 'V' (topic
      *> view) / 'X' (exit). Two-phase MAIN per bank.cob: phase 1
      *> handles the prior screen's AID on a warm start, phase 2
      *> paints the (possibly new) screen and returns TRANSID.
       IDENTIFICATION DIVISION.
       PROGRAM-ID. TOPX.

       DATA DIVISION.
       WORKING-STORAGE SECTION.
       COPY DFHAID.
       COPY DFHRESP.
       COPY DFHCOLOR.
       COPY SQLCA.

      *> pseudo-conversational state (rides in COMMAREA)
      *> ST-MAGIC guards against a stale COMMAREA left by another
      *> transaction (see bank.cob). ST-TID remembers the topic_id
      *> behind every displayed list row so a selector hit maps to
      *> a topic without a refetch race.
           *> In my opinion every BRICKS programmer should use these
      *> safety checks to prevent bardak 
      
      
       01 STATE.
          05 ST-MAGIC   PIC X(4)  VALUE 'TOPX'.
             88 MAGIC-MATCHES VALUE 'TOPX'.
          05 ST-SCREEN  PIC X(1)  VALUE 'L'.
          05 ST-PAGE    PIC 9(4)  VALUE 1.
          05 ST-SORT    PIC X(1)  VALUE 'C'.
             88 SORT-CREATED  VALUE 'C'.
             88 SORT-ACTIVITY VALUE 'A'.
          05 ST-QUERY   PIC X(22) VALUE SPACES.
          05 ST-SRCH    PIC X(1)  VALUE 'N'.
             88 SEARCH-ACTIVE VALUE 'Y'.
          05 ST-HASNEXT PIC X(1)  VALUE 'N'.
          05 ST-TIDCNT  PIC 9(2)  VALUE 0.
          05 ST-TID     PIC 9(9)  OCCURS 37.
          05 ST-TOPIC   PIC 9(9)  VALUE 0.
           05 ST-OFF     PIC 9(5)  VALUE 0.
          05 ST-ORDER   PIC X(1)  VALUE 'O'.
             88 ORDER-OLDEST VALUE 'O'.
             88 ORDER-NEWEST VALUE 'N'.
          05 ST-TOTL    PIC 9(5)  VALUE 0.
          05 ST-MSG     PIC X(36) VALUE SPACES.
       01 WARM-FLAG     PIC X(1)  VALUE 'N'.
          88 WARM-START VALUE 'Y'.
          88 COLD-START VALUE 'N'.

      *> SQL health for the current task, plus the fatal-abort signal.
      *> A failed query trips QRY-BAD; PAINT-LIST / PAINT-VIEW then paint
      *> a one-line SEND TEXT and raise WS-FATAL so MAIN ends the task
      *> instead of shipping a map full of empty rows.
       01 WS-SQLOK      PIC X(1)  VALUE 'Y'.
          88 QRY-OK     VALUE 'Y'.
          88 QRY-BAD    VALUE 'N'.
       01 WS-FATAL      PIC X(1)  VALUE 'N'.
       01 WS-ERRSCR     PIC X(78) VALUE SPACES.

      *> what terminal model (recomputed every task)
       01 WS-SH    PIC 9(4) VALUE 0.
       01 WS-LMAP  PIC X(8) VALUE 'TOPL2'.
       01 WS-VMAP  PIC X(8) VALUE 'TOPV2'.
       01 WS-LNVIS PIC 9(2) VALUE 19.
       01 WS-VNVIS PIC 9(2) VALUE 19.
       01 WS-HALF  PIC 9(2) VALUE 9.

      *> LIST screen IO group (maps TOPL2 / TOPL4)
      *> Each column is a named <X>-AREA group (the SEND/RECEIVE MAP
      *> contract -- routing resolves SCRL.TIT01 etc. through storage)
      *> with a <X>-TAB REDEFINES overlay giving the fill loop one
      *> OCCURS view (T-*). TITnn-C / the T-TITROW colour cell are the
      *> per-row colour overrides driven by topics.color.
       01 SCRL.
          05 LTITLE  PIC X(58).
          05 LPAGE   PIC X(9).
          05 SEARCH  PIC X(22).
          05 ERRMSG  PIC X(36).
          05 FKEYS   PIC X(30).
          05 SEL-AREA.
             10 SEL01   PIC X(1).
             10 SEL02   PIC X(1).
             10 SEL03   PIC X(1).
             10 SEL04   PIC X(1).
             10 SEL05   PIC X(1).
             10 SEL06   PIC X(1).
             10 SEL07   PIC X(1).
             10 SEL08   PIC X(1).
             10 SEL09   PIC X(1).
             10 SEL10   PIC X(1).
             10 SEL11   PIC X(1).
             10 SEL12   PIC X(1).
             10 SEL13   PIC X(1).
             10 SEL14   PIC X(1).
             10 SEL15   PIC X(1).
             10 SEL16   PIC X(1).
             10 SEL17   PIC X(1).
             10 SEL18   PIC X(1).
             10 SEL19   PIC X(1).
             10 SEL20   PIC X(1).
             10 SEL21   PIC X(1).
             10 SEL22   PIC X(1).
             10 SEL23   PIC X(1).
             10 SEL24   PIC X(1).
             10 SEL25   PIC X(1).
             10 SEL26   PIC X(1).
             10 SEL27   PIC X(1).
             10 SEL28   PIC X(1).
             10 SEL29   PIC X(1).
             10 SEL30   PIC X(1).
             10 SEL31   PIC X(1).
             10 SEL32   PIC X(1).
             10 SEL33   PIC X(1).
             10 SEL34   PIC X(1).
             10 SEL35   PIC X(1).
             10 SEL36   PIC X(1).
             10 SEL37   PIC X(1).
          05 SEL-TAB REDEFINES SEL-AREA.
             10 T-SEL   PIC X(1) OCCURS 37.
          05 TIT-AREA.
             10 TIT01   PIC X(41).
             10 TIT01-C PIC X(9).
             10 TIT02   PIC X(41).
             10 TIT02-C PIC X(9).
             10 TIT03   PIC X(41).
             10 TIT03-C PIC X(9).
             10 TIT04   PIC X(41).
             10 TIT04-C PIC X(9).
             10 TIT05   PIC X(41).
             10 TIT05-C PIC X(9).
             10 TIT06   PIC X(41).
             10 TIT06-C PIC X(9).
             10 TIT07   PIC X(41).
             10 TIT07-C PIC X(9).
             10 TIT08   PIC X(41).
             10 TIT08-C PIC X(9).
             10 TIT09   PIC X(41).
             10 TIT09-C PIC X(9).
             10 TIT10   PIC X(41).
             10 TIT10-C PIC X(9).
             10 TIT11   PIC X(41).
             10 TIT11-C PIC X(9).
             10 TIT12   PIC X(41).
             10 TIT12-C PIC X(9).
             10 TIT13   PIC X(41).
             10 TIT13-C PIC X(9).
             10 TIT14   PIC X(41).
             10 TIT14-C PIC X(9).
             10 TIT15   PIC X(41).
             10 TIT15-C PIC X(9).
             10 TIT16   PIC X(41).
             10 TIT16-C PIC X(9).
             10 TIT17   PIC X(41).
             10 TIT17-C PIC X(9).
             10 TIT18   PIC X(41).
             10 TIT18-C PIC X(9).
             10 TIT19   PIC X(41).
             10 TIT19-C PIC X(9).
             10 TIT20   PIC X(41).
             10 TIT20-C PIC X(9).
             10 TIT21   PIC X(41).
             10 TIT21-C PIC X(9).
             10 TIT22   PIC X(41).
             10 TIT22-C PIC X(9).
             10 TIT23   PIC X(41).
             10 TIT23-C PIC X(9).
             10 TIT24   PIC X(41).
             10 TIT24-C PIC X(9).
             10 TIT25   PIC X(41).
             10 TIT25-C PIC X(9).
             10 TIT26   PIC X(41).
             10 TIT26-C PIC X(9).
             10 TIT27   PIC X(41).
             10 TIT27-C PIC X(9).
             10 TIT28   PIC X(41).
             10 TIT28-C PIC X(9).
             10 TIT29   PIC X(41).
             10 TIT29-C PIC X(9).
             10 TIT30   PIC X(41).
             10 TIT30-C PIC X(9).
             10 TIT31   PIC X(41).
             10 TIT31-C PIC X(9).
             10 TIT32   PIC X(41).
             10 TIT32-C PIC X(9).
             10 TIT33   PIC X(41).
             10 TIT33-C PIC X(9).
             10 TIT34   PIC X(41).
             10 TIT34-C PIC X(9).
             10 TIT35   PIC X(41).
             10 TIT35-C PIC X(9).
             10 TIT36   PIC X(41).
             10 TIT36-C PIC X(9).
             10 TIT37   PIC X(41).
             10 TIT37-C PIC X(9).
          05 TIT-TAB REDEFINES TIT-AREA.
             10 T-TITROW OCCURS 37.
                15 T-TIT  PIC X(41).
                15 T-TITC PIC X(9).
          05 AUT-AREA.
             10 AUT01   PIC X(7).
             10 AUT02   PIC X(7).
             10 AUT03   PIC X(7).
             10 AUT04   PIC X(7).
             10 AUT05   PIC X(7).
             10 AUT06   PIC X(7).
             10 AUT07   PIC X(7).
             10 AUT08   PIC X(7).
             10 AUT09   PIC X(7).
             10 AUT10   PIC X(7).
             10 AUT11   PIC X(7).
             10 AUT12   PIC X(7).
             10 AUT13   PIC X(7).
             10 AUT14   PIC X(7).
             10 AUT15   PIC X(7).
             10 AUT16   PIC X(7).
             10 AUT17   PIC X(7).
             10 AUT18   PIC X(7).
             10 AUT19   PIC X(7).
             10 AUT20   PIC X(7).
             10 AUT21   PIC X(7).
             10 AUT22   PIC X(7).
             10 AUT23   PIC X(7).
             10 AUT24   PIC X(7).
             10 AUT25   PIC X(7).
             10 AUT26   PIC X(7).
             10 AUT27   PIC X(7).
             10 AUT28   PIC X(7).
             10 AUT29   PIC X(7).
             10 AUT30   PIC X(7).
             10 AUT31   PIC X(7).
             10 AUT32   PIC X(7).
             10 AUT33   PIC X(7).
             10 AUT34   PIC X(7).
             10 AUT35   PIC X(7).
             10 AUT36   PIC X(7).
             10 AUT37   PIC X(7).
          05 AUT-TAB REDEFINES AUT-AREA.
             10 T-AUT   PIC X(7) OCCURS 37.
          05 PST-AREA.
             10 PST01   PIC X(5).
             10 PST02   PIC X(5).
             10 PST03   PIC X(5).
             10 PST04   PIC X(5).
             10 PST05   PIC X(5).
             10 PST06   PIC X(5).
             10 PST07   PIC X(5).
             10 PST08   PIC X(5).
             10 PST09   PIC X(5).
             10 PST10   PIC X(5).
             10 PST11   PIC X(5).
             10 PST12   PIC X(5).
             10 PST13   PIC X(5).
             10 PST14   PIC X(5).
             10 PST15   PIC X(5).
             10 PST16   PIC X(5).
             10 PST17   PIC X(5).
             10 PST18   PIC X(5).
             10 PST19   PIC X(5).
             10 PST20   PIC X(5).
             10 PST21   PIC X(5).
             10 PST22   PIC X(5).
             10 PST23   PIC X(5).
             10 PST24   PIC X(5).
             10 PST25   PIC X(5).
             10 PST26   PIC X(5).
             10 PST27   PIC X(5).
             10 PST28   PIC X(5).
             10 PST29   PIC X(5).
             10 PST30   PIC X(5).
             10 PST31   PIC X(5).
             10 PST32   PIC X(5).
             10 PST33   PIC X(5).
             10 PST34   PIC X(5).
             10 PST35   PIC X(5).
             10 PST36   PIC X(5).
             10 PST37   PIC X(5).
          05 PST-TAB REDEFINES PST-AREA.
             10 T-PST   PIC X(5) OCCURS 37.
          05 VWS-AREA.
             10 VWS01   PIC X(5).
             10 VWS02   PIC X(5).
             10 VWS03   PIC X(5).
             10 VWS04   PIC X(5).
             10 VWS05   PIC X(5).
             10 VWS06   PIC X(5).
             10 VWS07   PIC X(5).
             10 VWS08   PIC X(5).
             10 VWS09   PIC X(5).
             10 VWS10   PIC X(5).
             10 VWS11   PIC X(5).
             10 VWS12   PIC X(5).
             10 VWS13   PIC X(5).
             10 VWS14   PIC X(5).
             10 VWS15   PIC X(5).
             10 VWS16   PIC X(5).
             10 VWS17   PIC X(5).
             10 VWS18   PIC X(5).
             10 VWS19   PIC X(5).
             10 VWS20   PIC X(5).
             10 VWS21   PIC X(5).
             10 VWS22   PIC X(5).
             10 VWS23   PIC X(5).
             10 VWS24   PIC X(5).
             10 VWS25   PIC X(5).
             10 VWS26   PIC X(5).
             10 VWS27   PIC X(5).
             10 VWS28   PIC X(5).
             10 VWS29   PIC X(5).
             10 VWS30   PIC X(5).
             10 VWS31   PIC X(5).
             10 VWS32   PIC X(5).
             10 VWS33   PIC X(5).
             10 VWS34   PIC X(5).
             10 VWS35   PIC X(5).
             10 VWS36   PIC X(5).
             10 VWS37   PIC X(5).
          05 VWS-TAB REDEFINES VWS-AREA.
             10 T-VWS   PIC X(5) OCCURS 37.
          05 LIK-AREA.
             10 LIK01   PIC X(5).
             10 LIK02   PIC X(5).
             10 LIK03   PIC X(5).
             10 LIK04   PIC X(5).
             10 LIK05   PIC X(5).
             10 LIK06   PIC X(5).
             10 LIK07   PIC X(5).
             10 LIK08   PIC X(5).
             10 LIK09   PIC X(5).
             10 LIK10   PIC X(5).
             10 LIK11   PIC X(5).
             10 LIK12   PIC X(5).
             10 LIK13   PIC X(5).
             10 LIK14   PIC X(5).
             10 LIK15   PIC X(5).
             10 LIK16   PIC X(5).
             10 LIK17   PIC X(5).
             10 LIK18   PIC X(5).
             10 LIK19   PIC X(5).
             10 LIK20   PIC X(5).
             10 LIK21   PIC X(5).
             10 LIK22   PIC X(5).
             10 LIK23   PIC X(5).
             10 LIK24   PIC X(5).
             10 LIK25   PIC X(5).
             10 LIK26   PIC X(5).
             10 LIK27   PIC X(5).
             10 LIK28   PIC X(5).
             10 LIK29   PIC X(5).
             10 LIK30   PIC X(5).
             10 LIK31   PIC X(5).
             10 LIK32   PIC X(5).
             10 LIK33   PIC X(5).
             10 LIK34   PIC X(5).
             10 LIK35   PIC X(5).
             10 LIK36   PIC X(5).
             10 LIK37   PIC X(5).
          05 LIK-TAB REDEFINES LIK-AREA.
             10 T-LIK   PIC X(5) OCCURS 37.
          05 DAT-AREA.
             10 DAT01   PIC X(7).
             10 DAT02   PIC X(7).
             10 DAT03   PIC X(7).
             10 DAT04   PIC X(7).
             10 DAT05   PIC X(7).
             10 DAT06   PIC X(7).
             10 DAT07   PIC X(7).
             10 DAT08   PIC X(7).
             10 DAT09   PIC X(7).
             10 DAT10   PIC X(7).
             10 DAT11   PIC X(7).
             10 DAT12   PIC X(7).
             10 DAT13   PIC X(7).
             10 DAT14   PIC X(7).
             10 DAT15   PIC X(7).
             10 DAT16   PIC X(7).
             10 DAT17   PIC X(7).
             10 DAT18   PIC X(7).
             10 DAT19   PIC X(7).
             10 DAT20   PIC X(7).
             10 DAT21   PIC X(7).
             10 DAT22   PIC X(7).
             10 DAT23   PIC X(7).
             10 DAT24   PIC X(7).
             10 DAT25   PIC X(7).
             10 DAT26   PIC X(7).
             10 DAT27   PIC X(7).
             10 DAT28   PIC X(7).
             10 DAT29   PIC X(7).
             10 DAT30   PIC X(7).
             10 DAT31   PIC X(7).
             10 DAT32   PIC X(7).
             10 DAT33   PIC X(7).
             10 DAT34   PIC X(7).
             10 DAT35   PIC X(7).
             10 DAT36   PIC X(7).
             10 DAT37   PIC X(7).
          05 DAT-TAB REDEFINES DAT-AREA.
             10 T-DAT   PIC X(7) OCCURS 37.
      *>  wow, this was tedious and error prone... 


      *> VIEW screen IO group (maps TOPV2 / TOPV4) --
      *> RULER doubles as the error line: the column ruler is the
      *> normal content; 
      *> not mirroring 3270BBS painting errors over row 2.
       01 SCRV.
          05 VTITLE  PIC X(39).
          05 VCONF   PIC X(19).
          05 VAUTH   PIC X(7).
          05 VDATE   PIC X(16).
          05 VREPL   PIC X(12).
          05 VVIEWS  PIC X(11).
          05 VPAGE   PIC X(18).
          05 RULER   PIC X(78).
          05 RULER-C PIC X(9).
          05 ROW-AREA.
             10 ROW01   PIC X(78).
             10 ROW01-C PIC X(9).
             10 ROW02   PIC X(78).
             10 ROW02-C PIC X(9).
             10 ROW03   PIC X(78).
             10 ROW03-C PIC X(9).
             10 ROW04   PIC X(78).
             10 ROW04-C PIC X(9).
             10 ROW05   PIC X(78).
             10 ROW05-C PIC X(9).
             10 ROW06   PIC X(78).
             10 ROW06-C PIC X(9).
             10 ROW07   PIC X(78).
             10 ROW07-C PIC X(9).
             10 ROW08   PIC X(78).
             10 ROW08-C PIC X(9).
             10 ROW09   PIC X(78).
             10 ROW09-C PIC X(9).
             10 ROW10   PIC X(78).
             10 ROW10-C PIC X(9).
             10 ROW11   PIC X(78).
             10 ROW11-C PIC X(9).
             10 ROW12   PIC X(78).
             10 ROW12-C PIC X(9).
             10 ROW13   PIC X(78).
             10 ROW13-C PIC X(9).
             10 ROW14   PIC X(78).
             10 ROW14-C PIC X(9).
             10 ROW15   PIC X(78).
             10 ROW15-C PIC X(9).
             10 ROW16   PIC X(78).
             10 ROW16-C PIC X(9).
             10 ROW17   PIC X(78).
             10 ROW17-C PIC X(9).
             10 ROW18   PIC X(78).
             10 ROW18-C PIC X(9).
             10 ROW19   PIC X(78).
             10 ROW19-C PIC X(9).
             10 ROW20   PIC X(78).
             10 ROW20-C PIC X(9).
             10 ROW21   PIC X(78).
             10 ROW21-C PIC X(9).
             10 ROW22   PIC X(78).
             10 ROW22-C PIC X(9).
             10 ROW23   PIC X(78).
             10 ROW23-C PIC X(9).
             10 ROW24   PIC X(78).
             10 ROW24-C PIC X(9).
             10 ROW25   PIC X(78).
             10 ROW25-C PIC X(9).
             10 ROW26   PIC X(78).
             10 ROW26-C PIC X(9).
             10 ROW27   PIC X(78).
             10 ROW27-C PIC X(9).
             10 ROW28   PIC X(78).
             10 ROW28-C PIC X(9).
             10 ROW29   PIC X(78).
             10 ROW29-C PIC X(9).
             10 ROW30   PIC X(78).
             10 ROW30-C PIC X(9).
             10 ROW31   PIC X(78).
             10 ROW31-C PIC X(9).
             10 ROW32   PIC X(78).
             10 ROW32-C PIC X(9).
             10 ROW33   PIC X(78).
             10 ROW33-C PIC X(9).
             10 ROW34   PIC X(78).
             10 ROW34-C PIC X(9).
             10 ROW35   PIC X(78).
             10 ROW35-C PIC X(9).
             10 ROW36   PIC X(78).
             10 ROW36-C PIC X(9).
             10 ROW37   PIC X(78).
             10 ROW37-C PIC X(9).
             10 ROW38   PIC X(78).
             10 ROW38-C PIC X(9).
          05 ROW-TAB REDEFINES ROW-AREA.
             10 V-ROWGRP OCCURS 38.
                15 V-ROW  PIC X(78).
                15 V-ROWC PIC X(9).


      *> SQL host variables 
       01 WS-PAT     PIC X(26) VALUE '%'.
       01 WS-LIM     PIC 9(2)  VALUE 0.
       01 WS-OFFL    PIC 9(6)  VALUE 0.
       01 WS-TID     PIC 9(9)  VALUE 0.
       01 WS-TTIT    PIC X(41).
       01 WS-TAUT    PIC X(7).
       01 WS-TPST    PIC X(5).
       01 WS-TVWS    PIC X(5).
       01 WS-TLIK    PIC X(5).
       01 WS-TDAT    PIC X(7).
       01 WS-TCOL    PIC X(10).
       01 WS-TOPIC   PIC 9(9)  VALUE 0.
       01 WS-VTITLE  PIC X(39).
       01 WS-VAUTH   PIC X(7).
       01 WS-VCONF   PIC X(19).
       01 WS-VDATEH  PIC X(13).
       01 WS-PCNT    PIC 9(5)  VALUE 0.
       01 WS-VCNT    PIC 9(7)  VALUE 0.
       01 WS-FND     PIC 9(5)  VALUE 0.
       01 WS-PID     PIC 9(9)  VALUE 0.
       01 WS-PHDR    PIC X(40).
       01 WS-PLINE   PIC X(1560).
       01 WS-PLEN    PIC 9(4)  VALUE 0.

        *> scratch
       01 WS-HDROK   PIC X(1)  VALUE 'Y'.
       01 WS-I       PIC 9(4)  VALUE 0.
       01 WS-J       PIC 9(4)  VALUE 0.
       01 WS-K       PIC 9(4)  VALUE 0.
       01 WS-SLOT    PIC 9(2)  VALUE 0.
       01 WS-FOUND   PIC 9(2)  VALUE 0.
       01 WS-LINENO  PIC 9(5)  VALUE 0.
       01 WS-SHOWN   PIC 9(2)  VALUE 0.
       01 WS-PREVPID PIC 9(9)  VALUE 0.
       01 WS-POS     PIC 9(4)  VALUE 0.
       01 WS-REMAIN  PIC 9(4)  VALUE 0.
       01 WS-BRK     PIC 9(2)  VALUE 0.
       01 WS-TMP     PIC 9(6)  VALUE 0.
       01 WS-TMP2    PIC 9(5)  VALUE 0.
       01 WS-PAGEX   PIC 9(4)  VALUE 0.
       01 WS-PAGEY   PIC 9(4)  VALUE 0.
       01 WS-REPLN   PIC 9(5)  VALUE 0.
       01 WS-EMIT    PIC X(78).
       01 WS-EMITC   PIC X(9).
       01 WS-PNUM    PIC 9(5)  VALUE 0.
       01 WS-MARK    PIC X(19) VALUE SPACES.
       01 WS-ISFIRST PIC X(1)  VALUE 'N'.
       01 WS-ISLAST  PIC X(1)  VALUE 'N'.
       01 WS-RULER   PIC X(78).
       01 ED-Z4      PIC Z(3)9.
       01 ED-Z4B     PIC Z(3)9.
       01 ED-Z5      PIC Z(4)9.
       01 ED-Z7      PIC Z(6)9.

       PROCEDURE DIVISION.
       MAIN.
           MOVE 'N' TO WARM-FLAG.
           IF EIBCALEN IS POSITIVE THEN
               MOVE DFHCOMMAREA TO STATE
               IF MAGIC-MATCHES THEN
                   MOVE 'Y' TO WARM-FLAG
               END-IF
           END-IF.

      *> Cold start (or a stale COMMAREA from another transaction)
      *> -> reinitialise STATE to a clean, magic-tagged snapshot.
           IF COLD-START THEN
               MOVE 'TOPX' TO ST-MAGIC
               MOVE 'L'    TO ST-SCREEN
               MOVE 1      TO ST-PAGE
               MOVE 'C'    TO ST-SORT
               MOVE SPACES TO ST-QUERY
               MOVE 'N'    TO ST-SRCH
               MOVE 'N'    TO ST-HASNEXT
               MOVE 0      TO ST-TIDCNT
               MOVE 0      TO ST-TOPIC
               MOVE 0      TO ST-OFF
               MOVE 'O'    TO ST-ORDER
               MOVE 0      TO ST-TOTL
               MOVE SPACES TO ST-MSG
           END-IF.

           EXEC SQL WHENEVER SQLERROR CONTINUE END-EXEC.
           PERFORM DETECT-MODEL.

       *> Phase 1: consume the prior screen's input (warm only --
        *> on a cold start there is no map on the terminal yet).
           IF WARM-START THEN
               EVALUATE ST-SCREEN
                   WHEN 'L' PERFORM HANDLE-LIST
                   WHEN 'V' PERFORM HANDLE-VIEW
                   WHEN OTHER MOVE 'L' TO ST-SCREEN
               END-EVALUATE
           END-IF.

      *> Phase 2: paint the next screen. 'X' = operator exited.
           EVALUATE ST-SCREEN
               WHEN 'L' PERFORM PAINT-LIST
               WHEN 'V' PERFORM PAINT-VIEW
               WHEN 'X'
      *> Clear DFHCOMMAREA so that the nxt unrelated transaction
      *> doesn't inherit TOPX state bytes.
                   MOVE SPACES TO DFHCOMMAREA
                   EXEC CICS RETURN END-EXEC
                   STOP RUN
               WHEN OTHER PERFORM PAINT-LIST
           END-EVALUATE.

      *> A failed query already painted its SEND TEXT message and waited
      *> for an AID; end the pseudo-conversation (drop to CICS) instead
      *> of re-driving TOPX straight back into the same error.
           IF WS-FATAL = 'Y' THEN
               MOVE SPACES TO DFHCOMMAREA
               EXEC CICS RETURN END-EXEC
               STOP RUN
           END-IF.

           MOVE STATE TO DFHCOMMAREA.
           EXEC CICS RETURN TRANSID('TOPX')
                            COMMAREA(STATE) END-EXEC.
           STOP RUN.


      *> DETECT-MODEL -- pick the map pair and visible-row budget
      *> from the live terminal height (book.rexx / esdc.cob idiom).

       DETECT-MODEL.
           EXEC CICS ASSIGN SCREENHT(WS-SH) END-EXEC.
           IF WS-SH >= 43 THEN
               MOVE 'TOPL4' TO WS-LMAP
               MOVE 'TOPV4' TO WS-VMAP
               MOVE 37 TO WS-LNVIS
               MOVE 38 TO WS-VNVIS
               MOVE 19 TO WS-HALF
           ELSE
               MOVE 'TOPL2' TO WS-LMAP
               MOVE 'TOPV2' TO WS-VMAP
               MOVE 19 TO WS-LNVIS
               MOVE 19 TO WS-VNVIS
               MOVE 9  TO WS-HALF
           END-IF.


      *> HANDLE-LIST -- consume the topics-list screen's AID.

       HANDLE-LIST.
           EXEC CICS RECEIVE MAP(WS-LMAP) INTO(SCRL) END-EXEC.
           EVALUATE EIBAID
               WHEN DFHPF3
                   MOVE 'X' TO ST-SCREEN
               WHEN DFHPF7
                   IF ST-PAGE > 1 THEN
                       SUBTRACT 1 FROM ST-PAGE
                   END-IF
               WHEN DFHPF8
                   IF ST-HASNEXT = 'Y' THEN
                       ADD 1 TO ST-PAGE
                   END-IF
               WHEN DFHPF10
                   IF SORT-CREATED THEN
                       MOVE 'A' TO ST-SORT
                   ELSE
                       MOVE 'C' TO ST-SORT
                   END-IF
                   MOVE 1 TO ST-PAGE
               WHEN DFHENTER
                   PERFORM PROCESS-LIST-ENTER
               WHEN OTHER
                   CONTINUE
           END-EVALUATE.

      *> A changed search field takes preedence over a selector;
      *> matches 3270BBS, whre typing a query and pressing ENTER
      *> re-runs the list from page 1.
       PROCESS-LIST-ENTER.
           IF SEARCH NOT = ST-QUERY THEN
               MOVE SEARCH TO ST-QUERY
               MOVE 1 TO ST-PAGE
               IF ST-QUERY = SPACES THEN
                   MOVE 'N' TO ST-SRCH
               ELSE
                   MOVE 'Y' TO ST-SRCH
               END-IF
           ELSE
               PERFORM GATHER-SELECTORS
           END-IF.

      *> GATHER-SELECTORS -- first non-blank selector wins. T-SEL is the
      *> OCCURS overlay REDEFINES'd onto SEL01..SEL37, so the RECEIVE MAP
      *> bytes are already subscriptable -- no fan-in copy needed.
       GATHER-SELECTORS.
           MOVE 0 TO WS-FOUND.
           PERFORM SCAN-ONE-SEL VARYING WS-I FROM 1 BY 1
               UNTIL WS-I > WS-LNVIS OR WS-FOUND > 0.
           IF WS-FOUND > 0 THEN
               IF WS-FOUND <= ST-TIDCNT THEN
                   MOVE ST-TID(WS-FOUND) TO ST-TOPIC
                   MOVE 'V' TO ST-SCREEN
                   MOVE 0   TO ST-OFF
                   MOVE 0   TO ST-TOTL
                   MOVE 'O' TO ST-ORDER
               ELSE
                   MOVE 'Invalid selection' TO ST-MSG
               END-IF
           END-IF.

       SCAN-ONE-SEL.
           IF T-SEL(WS-I) NOT = SPACES THEN
               MOVE WS-I TO WS-FOUND
           END-IF.

       CLEAR-TID.
           MOVE 0 TO ST-TID(WS-I).


        *> HANDLE-VIEW -- consume the topic-view screen's AID.
      *> F7/F8 scroll a full screen of lines, F14/F15 half a
      *> screen, F2/F12 flip the post order and rewind to the top.

       HANDLE-VIEW.
           EXEC CICS RECEIVE MAP(WS-VMAP) INTO(SCRV) END-EXEC.
           EVALUATE EIBAID
               WHEN DFHPF3
                   MOVE 'L' TO ST-SCREEN
               WHEN DFHPF7
                   IF ST-OFF >= WS-VNVIS THEN
                       SUBTRACT WS-VNVIS FROM ST-OFF
                   ELSE
                       MOVE 0 TO ST-OFF
                   END-IF
               WHEN DFHPF8
                   COMPUTE WS-TMP = ST-OFF + WS-VNVIS
                   IF WS-TMP < ST-TOTL THEN
                       MOVE WS-TMP TO ST-OFF
                   END-IF
               WHEN DFHPF14
                    IF ST-OFF >= WS-HALF THEN
                       SUBTRACT WS-HALF FROM ST-OFF
                   ELSE
                       MOVE 0 TO ST-OFF
                     END-IF
               WHEN DFHPF15
                   COMPUTE WS-TMP = ST-OFF + WS-HALF
                   IF WS-TMP < ST-TOTL THEN
                       MOVE WS-TMP TO ST-OFF
                   END-IF
               WHEN DFHPF2
                   MOVE 'O' TO ST-ORDER
                   MOVE 0 TO ST-OFF
               WHEN DFHPF12
                   MOVE 'N' TO ST-ORDER
                   MOVE 0 TO ST-OFF
               WHEN OTHER
                   CONTINUE
           END-EVALUATE.


      *> PAINT-LIST  qureis  one page of topics and SEND the list
      *> map. Fetches LNVIS+1 rows; the probe row only proves a
      *> next page exists (tsu hasNextPage).
      *> 
       PAINT-LIST.
           MOVE 'Y' TO WS-SQLOK.
           MOVE SPACES TO SCRL.
           PERFORM CLEAR-TID VARYING WS-I FROM 1 BY 1
               UNTIL WS-I > 37.
           MOVE 0   TO ST-TIDCNT.
           MOVE 'N' TO ST-HASNEXT.
           MOVE 0   TO WS-SLOT.
           COMPUTE WS-LIM = WS-LNVIS + 1.
           COMPUTE WS-OFFL = (ST-PAGE - 1) * WS-LNVIS.
           IF SEARCH-ACTIVE THEN
               MOVE SPACES TO WS-PAT
               STRING '%' DELIMITED BY SIZE
                      FUNCTION TRIM(ST-QUERY) DELIMITED BY SIZE
                      '%' DELIMITED BY SIZE
                   INTO WS-PAT
               END-STRING
           ELSE
               MOVE '%' TO WS-PAT
           END-IF.
           IF SORT-CREATED THEN
               PERFORM RUN-LIST-CREATED
           ELSE
               PERFORM RUN-LIST-ACTIVITY
           END-IF.
      *> ADD-TOPIC-ROW wrote each fetched row straight through the
      *> T-* OCCURS overlay, which shares storage with TIT01..DAT37 --
      *> so the map fields are already populated, no fan-out copy.
           IF QRY-BAD THEN
               PERFORM SEND-SQL-ERROR
           ELSE
               PERFORM COMPOSE-LIST-CHROME
               EXEC CICS SEND MAP(WS-LMAP) FROM(SCRL) ERASE END-EXEC
           END-IF.

       RUN-LIST-CREATED.
           EXEC SQL DECLARE TLC CURSOR FOR
               SELECT t.topic_id,
                      CASE WHEN LENGTH(t.title) > 41
                           THEN CONCAT(SUBSTR(t.title, 1, 38),
                                       '...')
                           ELSE t.title END,
                      RPAD(SUBSTR(u.username, 1, 7), 7),
                      CAST((SELECT COUNT(*) FROM posts
                             WHERE topic_id = t.topic_id)
                           AS TEXT),
                      CAST(COALESCE(t.view_count, 0) AS TEXT),
                      CAST((SELECT COALESCE(SUM(
                                CASE WHEN l.is_like = 1
                                     THEN 1 ELSE 0 END), 0)
                              FROM posts p
                              LEFT JOIN likes l
                                ON p.post_id = l.post_id
                             WHERE p.topic_id = t.topic_id)
                           AS TEXT),
                      TO_CHAR(t.created_at, 'DDMonYY'),
                      LOWER(COALESCE(t.color, ''))
                 FROM topics t
                 JOIN users u ON t.user_id = u.user_id
                WHERE t.title ILIKE :WS-PAT
                ORDER BY t.created_at DESC
                LIMIT CAST(:WS-LIM AS INTEGER)
               OFFSET CAST(:WS-OFFL AS INTEGER)
           END-EXEC.
           EXEC SQL OPEN TLC END-EXEC.
           IF SQLCODE < 0 THEN
               PERFORM MARK-SQL-ERROR
           END-IF.
           PERFORM FETCH-TLC UNTIL SQLCODE NOT = 0.
           EXEC SQL CLOSE TLC END-EXEC.

       FETCH-TLC.
           EXEC SQL FETCH TLC INTO :WS-TID, :WS-TTIT,
                :WS-TAUT, :WS-TPST, :WS-TVWS, :WS-TLIK,
                :WS-TDAT, :WS-TCOL END-EXEC.
           IF SQLCODE = 0 THEN
               PERFORM ADD-TOPIC-ROW
           END-IF.
           IF SQLCODE < 0 THEN
               PERFORM MARK-SQL-ERROR
           END-IF.

       RUN-LIST-ACTIVITY.
           EXEC SQL DECLARE TLA CURSOR FOR
               SELECT t.topic_id,
                      CASE WHEN LENGTH(t.title) > 41
                           THEN CONCAT(SUBSTR(t.title, 1, 38),
                                       '...')
                           ELSE t.title END,
                      RPAD(SUBSTR(u.username, 1, 7), 7),
                      CAST((SELECT COUNT(*) FROM posts
                             WHERE topic_id = t.topic_id)
                           AS TEXT),
                      CAST(COALESCE(t.view_count, 0) AS TEXT),
                      CAST((SELECT COALESCE(SUM(
                                CASE WHEN l.is_like = 1
                                     THEN 1 ELSE 0 END), 0)
                              FROM posts p
                              LEFT JOIN likes l
                                ON p.post_id = l.post_id
                             WHERE p.topic_id = t.topic_id)
                           AS TEXT),
                      TO_CHAR(t.created_at, 'DDMonYY'),
                      LOWER(COALESCE(t.color, ''))
                 FROM topics t
                 JOIN users u ON t.user_id = u.user_id
                WHERE t.title ILIKE :WS-PAT
                ORDER BY (SELECT MAX(created_at)
                            FROM posts
                           WHERE topic_id = t.topic_id)
                         DESC NULLS LAST,
                         t.created_at DESC
                LIMIT CAST(:WS-LIM AS INTEGER)
               OFFSET CAST(:WS-OFFL AS INTEGER)
           END-EXEC.
           EXEC SQL OPEN TLA END-EXEC.
           IF SQLCODE < 0 THEN
               PERFORM MARK-SQL-ERROR
           END-IF.
           PERFORM FETCH-TLA UNTIL SQLCODE NOT = 0.
           EXEC SQL CLOSE TLA END-EXEC.

       FETCH-TLA.
           EXEC SQL FETCH TLA INTO :WS-TID, :WS-TTIT,
                :WS-TAUT, :WS-TPST, :WS-TVWS, :WS-TLIK,
                :WS-TDAT, :WS-TCOL END-EXEC.
           IF SQLCODE = 0 THEN
               PERFORM ADD-TOPIC-ROW
           END-IF.
           IF SQLCODE < 0 THEN
               PERFORM MARK-SQL-ERROR
           END-IF.

      *> ADD-TOPIC-ROW -- slot a fetched topic into the shadow
      *> tables; row LNVIS+1 is the has-next-page probe only.
       ADD-TOPIC-ROW.
           IF WS-SLOT >= WS-LNVIS THEN
               MOVE 'Y' TO ST-HASNEXT
           ELSE
               ADD 1 TO WS-SLOT
               MOVE WS-TID  TO ST-TID(WS-SLOT)
               MOVE WS-SLOT TO ST-TIDCNT
               MOVE WS-TTIT TO T-TIT(WS-SLOT)
               PERFORM MAP-TOPIC-COLOR
               MOVE WS-TAUT TO T-AUT(WS-SLOT)
               MOVE WS-TPST TO T-PST(WS-SLOT)
               MOVE WS-TVWS TO T-VWS(WS-SLOT)
               MOVE WS-TLIK TO T-LIK(WS-SLOT)
               MOVE WS-TDAT TO T-DAT(WS-SLOT)
           END-IF.

      *> MAP-TOPIC-COLOR -- tsu getTopicTitleColor: known colour
      *> names pass through, anything else (incl white / empty)
      *> renders WHITE. Not NEUTRAL: bricks' colorOf maps NEUTRAL
      *> to the 3270 default colour, which paints non-intense
      *> protected fields blue -- 'WHITE' is the literal that
      *> reproduces tsu's go3270.White.
       MAP-TOPIC-COLOR.
           EVALUATE WS-TCOL
               WHEN 'green'
                   MOVE DFHGREEN TO T-TITC(WS-SLOT)
               WHEN 'red'
                   MOVE DFHRED TO T-TITC(WS-SLOT)
               WHEN 'yellow'
                   MOVE DFHYELLO TO T-TITC(WS-SLOT)
               WHEN 'blue'
                   MOVE DFHBLUE TO T-TITC(WS-SLOT)
               WHEN OTHER
                   MOVE 'WHITE' TO T-TITC(WS-SLOT)
           END-EVALUATE.


      *> COMPOSE-LIST-CHROME -- title, page number, legend, search
      *> echo and message line (verbatim tsu literals).
       COMPOSE-LIST-CHROME.
           IF SEARCH-ACTIVE THEN
               MOVE SPACES TO LTITLE
               STRING "Topics matching '" DELIMITED BY SIZE
                      FUNCTION TRIM(ST-QUERY) DELIMITED BY SIZE
                      "'" DELIMITED BY SIZE
                   INTO LTITLE
               END-STRING
           ELSE
               IF SORT-CREATED THEN
                   MOVE 'Topic Listings - Sorted by Topic Creation Date' TO LTITLE
               ELSE
                   MOVE 'Topic Listings - Sorted by Activity'
                       TO LTITLE
               END-IF
           END-IF.
           MOVE ST-PAGE TO ED-Z4.
           MOVE SPACES TO LPAGE.
           STRING 'Page ' DELIMITED BY SIZE
                  FUNCTION TRIM(ED-Z4) DELIMITED BY SIZE
               INTO LPAGE
           END-STRING.
           IF SORT-CREATED THEN
               MOVE '  F7=Up F8=Dn F10=SortActive' TO FKEYS
           ELSE
               MOVE '  F7=Up F8=Dn F10=SortCreated' TO FKEYS
           END-IF.
           MOVE ST-QUERY TO SEARCH.
           IF ST-MSG NOT = SPACES THEN
               MOVE ST-MSG TO ERRMSG
               MOVE SPACES TO ST-MSG
           ELSE
               IF SEARCH-ACTIVE THEN
                   PERFORM COUNT-MATCHES
               END-IF
           END-IF.

      *> COUNT-MATCHES -- total titles matching the live search
      *> (tsu shows 'Found: n' next to the search field; folded
      *> into the message line here, see topl2.map header).
       COUNT-MATCHES.
           EXEC SQL
               SELECT COUNT(*) INTO :WS-FND
                 FROM topics t
                WHERE t.title ILIKE :WS-PAT
           END-EXEC.
           IF SQLCODE = 0 THEN
               MOVE WS-FND TO ED-Z5
               MOVE SPACES TO ERRMSG
               STRING 'Found: ' DELIMITED BY SIZE
                      FUNCTION TRIM(ED-Z5) DELIMITED BY SIZE
                      ' topics' DELIMITED BY SIZE
                   INTO ERRMSG
               END-STRING
           END-IF.

      *> MARK-SQL-ERROR -- a query came back with a negative SQLCODE.
      *> Trip QRY-BAD so the caller skips the map, and keep a short
      *> ST-MSG for the log. The detail is already in the bricks log.
       MARK-SQL-ERROR.
           MOVE 'N' TO WS-SQLOK.
           MOVE 'SQL error - see bricks log' TO ST-MSG.

      *> SEND-SQL-ERROR -- paint a single free-form line (no map, so no
      *> empty rows) and arm WS-FATAL. SEND TEXT waits for an AID, so
      *> the operator reads the error before MAIN drops them to CICS.
       SEND-SQL-ERROR.
           MOVE 'TOPX - database error. See bricks log. Press ENTER.'
               TO WS-ERRSCR.
           EXEC CICS SEND TEXT FROM(WS-ERRSCR) ERASE END-EXEC.
           MOVE 'Y' TO WS-FATAL.

      *> ===========================================================
      *> PAINT-VIEW -- header SELECT INTO, then the flat-line model:
      *> every post contributes a header line, wrapped body lines
      *> and one blank separator; ST-OFF indexes the first visible
      *> line. A vanished topic bounces back to the list.
      *> ===========================================================
       PAINT-VIEW.
           MOVE 'Y' TO WS-SQLOK.
           MOVE SPACES TO SCRV.
           MOVE ST-TOPIC TO WS-TOPIC.
           PERFORM GET-TOPIC-HEADER.
      *> A negative SQLCODE in the header is a real failure, not an
      *> empty result: message and bail before painting empty rows.
           IF QRY-BAD THEN
               PERFORM SEND-SQL-ERROR
           ELSE
               IF WS-HDROK = 'N' THEN
                   MOVE 'L' TO ST-SCREEN
      *> SQLCODE 100 -> the topic vanished (not an error); bounce to
      *> the list with a note rather than a blank view.
                   IF ST-MSG = SPACES THEN
                       MOVE 'Topic not found' TO ST-MSG
                   END-IF
                   PERFORM PAINT-LIST
               ELSE
                   PERFORM BUILD-PASS
                   IF QRY-BAD THEN
                       PERFORM SEND-SQL-ERROR
                   ELSE
      *> Posts shrank since the last task and the offset now
      *> points past the end: clamp to the last page, rebuild.
                       IF ST-OFF >= ST-TOTL AND ST-TOTL > 0 THEN
                           COMPUTE WS-TMP = ST-TOTL - 1
                           DIVIDE WS-TMP BY WS-VNVIS GIVING WS-TMP2
                           COMPUTE ST-OFF = WS-TMP2 * WS-VNVIS
                           PERFORM BUILD-PASS
                       END-IF
      *> EMIT-LINE wrote each visible row through the V-ROW OCCURS
      *> overlay onto ROW01..ROW38, so the map is already filled.
                       PERFORM COMPOSE-VIEW-CHROME
                       EXEC CICS SEND MAP(WS-VMAP) FROM(SCRV) ERASE
                            END-EXEC
                   END-IF
               END-IF
           END-IF.

       GET-TOPIC-HEADER.
           MOVE 'Y' TO WS-HDROK.
           EXEC SQL
               SELECT CASE WHEN LENGTH(t.title) > 39
                           THEN CONCAT(SUBSTR(t.title, 1, 36),
                                       '...')
                           ELSE t.title END,
                      RPAD(SUBSTR(u.username, 1, 7), 7),
                      COALESCE(c.conference_name, 'General'),
                      TO_CHAR(t.created_at, 'FMDD Mon YYYY'),
                      (SELECT COUNT(*) FROM posts
                        WHERE topic_id = t.topic_id),
                      COALESCE(t.view_count, 0)
                 INTO :WS-VTITLE, :WS-VAUTH, :WS-VCONF,
                      :WS-VDATEH, :WS-PCNT, :WS-VCNT
                 FROM topics t
                 JOIN users u ON t.user_id = u.user_id
                 LEFT JOIN conferences c
                   ON t.conference_id = c.conference_id
                WHERE t.topic_id = CAST(:WS-TOPIC AS INTEGER)
           END-EXEC.
           IF SQLCODE NOT = 0 THEN
               MOVE 'N' TO WS-HDROK
           END-IF.
           IF SQLCODE < 0 THEN
               PERFORM MARK-SQL-ERROR
           END-IF.

      *> BUILD-PASS -- walk every post line of the topic through
      *> the wrap/window pipeline. Cheap to run twice when the
      *> offset needs clamping.
       BUILD-PASS.
           MOVE 0 TO WS-LINENO.
           MOVE 0 TO WS-SHOWN.
           MOVE 0 TO WS-PREVPID.
           MOVE 0 TO WS-PNUM.
           MOVE SPACES TO ROW-AREA.
           IF ORDER-OLDEST THEN
               PERFORM SCAN-POSTS-OLD
           ELSE
               PERFORM SCAN-POSTS-NEW
           END-IF.
           MOVE WS-LINENO TO ST-TOTL.

       SCAN-POSTS-OLD.
           EXEC SQL DECLARE PLO CURSOR FOR
               SELECT p.post_id,
                      CONCAT(RPAD(SUBSTR(u.username, 1, 7), 7),
                             ' wrote on ',
                             TO_CHAR(p.created_at,
                                     'FMDD Mon YYYY'),
                             ':'),
                      RTRIM(s.line),
                      LEAST(OCTET_LENGTH(RTRIM(s.line)), 1560)
                 FROM posts p
                 JOIN users u ON p.user_id = u.user_id,
                      LATERAL regexp_split_to_table(
                        replace(replace(
                          COALESCE(p.content, ''),
                          chr(13), ''),
                          chr(9), '    '),
                        chr(10))
                      WITH ORDINALITY AS s(line, ord)
                WHERE p.topic_id = CAST(:WS-TOPIC AS INTEGER)
                ORDER BY p.created_at ASC, p.post_id ASC,
                         s.ord ASC
           END-EXEC.
           EXEC SQL OPEN PLO END-EXEC.
           IF SQLCODE < 0 THEN
               PERFORM MARK-SQL-ERROR
           END-IF.
           PERFORM FETCH-PLO UNTIL SQLCODE NOT = 0.
           EXEC SQL CLOSE PLO END-EXEC.

       FETCH-PLO.
           EXEC SQL FETCH PLO INTO :WS-PID, :WS-PHDR,
                :WS-PLINE, :WS-PLEN END-EXEC.
           IF SQLCODE = 0 THEN
               PERFORM PROCESS-POST-LINE
           END-IF.
           IF SQLCODE < 0 THEN
               PERFORM MARK-SQL-ERROR
           END-IF.

       SCAN-POSTS-NEW.
           EXEC SQL DECLARE PLN CURSOR FOR
               SELECT p.post_id,
                      CONCAT(RPAD(SUBSTR(u.username, 1, 7), 7),
                             ' wrote on ',
                             TO_CHAR(p.created_at,
                                     'FMDD Mon YYYY'),
                             ':'),
                      RTRIM(s.line),
                      LEAST(OCTET_LENGTH(RTRIM(s.line)), 1560)
                 FROM posts p
                 JOIN users u ON p.user_id = u.user_id,
                      LATERAL regexp_split_to_table(
                        replace(replace(
                          COALESCE(p.content, ''),
                          chr(13), ''),
                          chr(9), '    '),
                        chr(10))
                      WITH ORDINALITY AS s(line, ord)
                WHERE p.topic_id = CAST(:WS-TOPIC AS INTEGER)
                ORDER BY p.created_at DESC, p.post_id DESC,
                         s.ord ASC
           END-EXEC.
           EXEC SQL OPEN PLN END-EXEC.
           IF SQLCODE < 0 THEN
               PERFORM MARK-SQL-ERROR
           END-IF.
           PERFORM FETCH-PLN UNTIL SQLCODE NOT = 0.
           EXEC SQL CLOSE PLN END-EXEC.

       FETCH-PLN.
           EXEC SQL FETCH PLN INTO :WS-PID, :WS-PHDR,
                :WS-PLINE, :WS-PLEN END-EXEC.
           IF SQLCODE = 0 THEN
               PERFORM PROCESS-POST-LINE
           END-IF.
           IF SQLCODE < 0 THEN
               PERFORM MARK-SQL-ERROR
           END-IF.

      *> PROCESS-POST-LINE -- emit the author header (YELLOW) and a
      *> blank separator at each post boundary, then wrap the body
      *> line. tsu paints 'USERNAM wrote on D Mon YYYY:' in blue;
      *> bricks deviates on purpose: yellow makes each new post's
      *> start easy to spot when scrolling. The BRIGHT half of
      *> tsu's styling is a per-map-field attribute bricks cannot
      *> flip at runtime (noted in topv2.map).
       PROCESS-POST-LINE.
           IF WS-PID NOT = WS-PREVPID THEN
               IF WS-PREVPID NOT = 0 THEN
                   MOVE SPACES TO WS-EMIT
                   MOVE SPACES TO WS-EMITC
                   PERFORM EMIT-LINE
               END-IF
               ADD 1 TO WS-PNUM
               PERFORM COMPOSE-POST-HEADER
               PERFORM EMIT-LINE
               MOVE WS-PID TO WS-PREVPID
           END-IF.
           PERFORM WRAP-EMIT.

      *> COMPOSE-POST-HEADER -- headers are yellow, except the
      *> earliest and latest posts of the topic, which get a
      *> 'FIRST POST' / 'LAST POST' tag appended and the whole
      *> line painted white (a map field holds a single colour,
      *> so the tag cannot be white on an otherwise yellow row).
      *> WS-PNUM counts post boundaries within the scan; against
      *> WS-PCNT (post count from GET-TOPIC-HEADER) it flags the
      *> ends in both F2/F12 scan orders.
       COMPOSE-POST-HEADER.
           MOVE 'N' TO WS-ISFIRST.
           MOVE 'N' TO WS-ISLAST.
           IF ORDER-OLDEST THEN
               IF WS-PNUM = 1 THEN
                   MOVE 'Y' TO WS-ISFIRST
               END-IF
               IF WS-PNUM = WS-PCNT THEN
                   MOVE 'Y' TO WS-ISLAST
               END-IF
           ELSE
               IF WS-PNUM = 1 THEN
                   MOVE 'Y' TO WS-ISLAST
               END-IF
               IF WS-PNUM = WS-PCNT THEN
                   MOVE 'Y' TO WS-ISFIRST
               END-IF
           END-IF.
           MOVE SPACES TO WS-MARK.
           IF WS-ISFIRST = 'Y' AND WS-ISLAST = 'Y' THEN
               MOVE 'FIRST AND LAST POST' TO WS-MARK
           ELSE
               IF WS-ISFIRST = 'Y' THEN
                   MOVE 'FIRST POST' TO WS-MARK
               END-IF
               IF WS-ISLAST = 'Y' THEN
                   MOVE 'LAST POST' TO WS-MARK
               END-IF
           END-IF.
           IF WS-MARK = SPACES THEN
               MOVE WS-PHDR TO WS-EMIT
               MOVE DFHYELLO TO WS-EMITC
           ELSE
               MOVE SPACES TO WS-EMIT
               STRING FUNCTION TRIM(WS-PHDR) DELIMITED BY SIZE
                      '   ' DELIMITED BY SIZE
                      FUNCTION TRIM(WS-MARK) DELIMITED BY SIZE
                   INTO WS-EMIT
               END-STRING
               MOVE 'WHITE' TO WS-EMITC
           END-IF.

      *> WRAP-EMIT -- tsu wrapText at width 78: break each segment
      *> at the last space before col 78 (a space at position 1
      *> does not count, matching strings.LastIndex == 0), hard
      *> break when a word exceeds the width. WS-PLEN arrives from
      *> SQL as the rtrimmed byte length, capped at 1560.
       WRAP-EMIT.
           MOVE DFHGREEN TO WS-EMITC.
           IF WS-PLEN = 0 THEN
               MOVE SPACES TO WS-EMIT
               PERFORM EMIT-LINE
           ELSE
               MOVE 1 TO WS-POS
               PERFORM WRAP-SEGMENT UNTIL WS-POS > WS-PLEN
           END-IF.

      *> WRAP-SEGMENT -- emit the next visible row of the current
      *> physical line, advancing WS-POS past what was consumed.
       WRAP-SEGMENT.
           COMPUTE WS-REMAIN = WS-PLEN - WS-POS + 1.
           MOVE SPACES TO WS-EMIT.
           IF WS-REMAIN <= 78 THEN
               MOVE WS-PLINE(WS-POS:WS-REMAIN) TO WS-EMIT
               COMPUTE WS-POS = WS-PLEN + 1
           ELSE
               MOVE 0 TO WS-BRK
               PERFORM FIND-BREAK VARYING WS-J FROM 78 BY -1
                   UNTIL WS-J < 2 OR WS-BRK > 0
               IF WS-BRK = 0 THEN
                   MOVE WS-PLINE(WS-POS:78) TO WS-EMIT
                   ADD 78 TO WS-POS
               ELSE
                   COMPUTE WS-K = WS-BRK - 1
                   MOVE WS-PLINE(WS-POS:WS-K) TO WS-EMIT
                   ADD WS-BRK TO WS-POS
               END-IF
           END-IF.
           PERFORM EMIT-LINE.

      *> FIND-BREAK -- backward scan for the last space at or before
      *> col 78 of the current segment (position 1 never counts,
      *> matching tsu's strings.LastIndex == 0 hard-break rule).
       FIND-BREAK.
           COMPUTE WS-K = WS-POS + WS-J - 1.
           IF WS-PLINE(WS-K:1) = SPACE THEN
               MOVE WS-J TO WS-BRK
           END-IF.

      *> EMIT-LINE -- count every virtual line; copy only those
      *> inside the visible window into the shadow rows.
       EMIT-LINE.
           ADD 1 TO WS-LINENO.
           IF WS-LINENO > ST-OFF AND WS-SHOWN < WS-VNVIS THEN
               ADD 1 TO WS-SHOWN
               MOVE WS-EMIT TO V-ROW(WS-SHOWN)
               MOVE WS-EMITC TO V-ROWC(WS-SHOWN)
           END-IF.


      *> COMPOSE-VIEW-CHROME -- header strip, ruler / error line
      *> and 'Page X of Y' (verbatim tsu literals and formats).
       COMPOSE-VIEW-CHROME.
           MOVE WS-VTITLE TO VTITLE.
           MOVE WS-VCONF TO VCONF.
           MOVE WS-VAUTH TO VAUTH.
           MOVE SPACES TO VDATE.
           STRING 'on ' DELIMITED BY SIZE
                  FUNCTION TRIM(WS-VDATEH) DELIMITED BY SIZE
               INTO VDATE
           END-STRING.
           IF WS-PCNT > 0 THEN
               COMPUTE WS-REPLN = WS-PCNT - 1
           ELSE
               MOVE 0 TO WS-REPLN
           END-IF.
           MOVE WS-REPLN TO ED-Z5.
           MOVE SPACES TO VREPL.
           STRING 'Replies: ' DELIMITED BY SIZE
                  FUNCTION TRIM(ED-Z5) DELIMITED BY SIZE
               INTO VREPL
           END-STRING.
           MOVE WS-VCNT TO ED-Z7.
           MOVE SPACES TO VVIEWS.
           STRING 'Views: ' DELIMITED BY SIZE
                  FUNCTION TRIM(ED-Z7) DELIMITED BY SIZE
               INTO VVIEWS
           END-STRING.
           DIVIDE ST-OFF BY WS-VNVIS GIVING WS-PAGEX.
           ADD 1 TO WS-PAGEX.
           COMPUTE WS-TMP = ST-TOTL + WS-VNVIS - 1.
           DIVIDE WS-TMP BY WS-VNVIS GIVING WS-PAGEY.
           IF WS-PAGEY < 1 THEN
               MOVE 1 TO WS-PAGEY
           END-IF.
           MOVE WS-PAGEX TO ED-Z4.
           MOVE WS-PAGEY TO ED-Z4B.
           MOVE SPACES TO VPAGE.
           STRING 'Page ' DELIMITED BY SIZE
                  FUNCTION TRIM(ED-Z4) DELIMITED BY SIZE
                  ' of ' DELIMITED BY SIZE
                  FUNCTION TRIM(ED-Z4B) DELIMITED BY SIZE
               INTO VPAGE
           END-STRING.
      *>      78-char ruler, assembled from two halves to keep source
      *> lines short (3270BBSs is 79; col 79 stays untouched).
           MOVE SPACES TO WS-RULER.
           STRING '----+----1----+----2----+----3----+----4'
                      DELIMITED BY SIZE
                  '----+----5----+----6----+----7----+---'
                      DELIMITED BY SIZE
               INTO WS-RULER
           END-STRING.
           IF ST-MSG NOT = SPACES THEN
               MOVE ST-MSG TO RULER
               MOVE DFHRED TO RULER-C
               MOVE SPACES TO ST-MSG
           ELSE
               MOVE WS-RULER TO RULER
               MOVE SPACES TO RULER-C
           END-IF.
