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

      *> what terminal model (recomputed every task)
       01 WS-SH    PIC 9(4) VALUE 0.
       01 WS-LMAP  PIC X(8) VALUE 'TOPL2'.
       01 WS-VMAP  PIC X(8) VALUE 'TOPV2'.
       01 WS-LNVIS PIC 9(2) VALUE 19.
       01 WS-VNVIS PIC 9(2) VALUE 19.
       01 WS-HALF  PIC 9(2) VALUE 9.

      *> LIST screen IO group (maps TOPL2 / TOPL4)
      *> Flat on purpose: bricks routes MAP fields to direct 05
      *> children of the FROM/INTO group by name. TITnn-C are the
      *> per-row colour overrides driven by topics.color.
       01 SCRL.
          05 LTITLE  PIC X(58).
          05 LPAGE   PIC X(9).
          05 SEARCH  PIC X(22).
          05 ERRMSG  PIC X(36).
          05 FKEYS   PIC X(30).
          05 SEL01   PIC X(1).
          05 SEL02   PIC X(1).
          05 SEL03   PIC X(1).
          05 SEL04   PIC X(1).
          05 SEL05   PIC X(1).
          05 SEL06   PIC X(1).
          05 SEL07   PIC X(1).
          05 SEL08   PIC X(1).
          05 SEL09   PIC X(1).
          05 SEL10   PIC X(1).
          05 SEL11   PIC X(1).
          05 SEL12   PIC X(1).
          05 SEL13   PIC X(1).
          05 SEL14   PIC X(1).
          05 SEL15   PIC X(1).
          05 SEL16   PIC X(1).
          05 SEL17   PIC X(1).
          05 SEL18   PIC X(1).
          05 SEL19   PIC X(1).
          05 SEL20   PIC X(1).
          05 SEL21   PIC X(1).
          05 SEL22   PIC X(1).
          05 SEL23   PIC X(1).
           05 SEL24   PIC X(1).
          05 SEL25   PIC X(1).
          05 SEL26   PIC X(1).
          05 SEL27   PIC X(1).
          05 SEL28   PIC X(1).
          05 SEL29   PIC X(1).
          05 SEL30   PIC X(1).
          05 SEL31   PIC X(1).
          05 SEL32   PIC X(1).
          05 SEL33   PIC X(1).
          05 SEL34   PIC X(1).
            05 SEL35   PIC X(1).
          05 SEL36   PIC X(1).
          05 SEL37   PIC X(1).
          05 TIT01   PIC X(41).
          05 TIT01-C PIC X(9).
          05 TIT02   PIC X(41).
          05 TIT02-C PIC X(9).
          05 TIT03   PIC X(41).
          05 TIT03-C PIC X(9).
          05 TIT04   PIC X(41).
          05 TIT04-C PIC X(9).
          05 TIT05   PIC X(41).
          05 TIT05-C PIC X(9).
          05 TIT06   PIC X(41).
          05 TIT06-C PIC X(9).
          05 TIT07   PIC X(41).
          05 TIT07-C PIC X(9).
          05 TIT08   PIC X(41).
          05 TIT08-C PIC X(9).
          05 TIT09   PIC X(41).
          05 TIT09-C PIC X(9).
          05 TIT10   PIC X(41).
          05 TIT10-C PIC X(9).
          05 TIT11   PIC X(41).
          05 TIT11-C PIC X(9).
          05 TIT12   PIC X(41).
          05 TIT12-C PIC X(9).
          05 TIT13   PIC X(41).
          05 TIT13-C PIC X(9).
          05 TIT14   PIC X(41).
          05 TIT14-C PIC X(9).
          05 TIT15   PIC X(41).
          05 TIT15-C PIC X(9).
          05 TIT16   PIC X(41).
          05 TIT16-C PIC X(9).
          05 TIT17   PIC X(41).
          05 TIT17-C PIC X(9).
          05 TIT18   PIC X(41).
          05 TIT18-C PIC X(9).
          05 TIT19   PIC X(41).
          05 TIT19-C PIC X(9).
          05 TIT20   PIC X(41).
          05 TIT20-C PIC X(9).
          05 TIT21   PIC X(41).
          05 TIT21-C PIC X(9).
          05 TIT22   PIC X(41).
          05 TIT22-C PIC X(9).
          05 TIT23   PIC X(41).
          05 TIT23-C PIC X(9).
          05 TIT24   PIC X(41).
          05 TIT24-C PIC X(9).
          05 TIT25   PIC X(41).
          05 TIT25-C PIC X(9).
          05 TIT26   PIC X(41).
          05 TIT26-C PIC X(9).
          05 TIT27   PIC X(41).
          05 TIT27-C PIC X(9).
          05 TIT28   PIC X(41).
          05 TIT28-C PIC X(9).
          05 TIT29   PIC X(41).
          05 TIT29-C PIC X(9).
          05 TIT30   PIC X(41).
          05 TIT30-C PIC X(9).
          05 TIT31   PIC X(41).
          05 TIT31-C PIC X(9).
          05 TIT32   PIC X(41).
          05 TIT32-C PIC X(9).
          05 TIT33   PIC X(41).
          05 TIT33-C PIC X(9).
          05 TIT34   PIC X(41).
          05 TIT34-C PIC X(9).
          05 TIT35   PIC X(41).
          05 TIT35-C PIC X(9).
          05 TIT36   PIC X(41).
          05 TIT36-C PIC X(9).
          05 TIT37   PIC X(41).
          05 TIT37-C PIC X(9).
          05 AUT01   PIC X(7).
          05 AUT02   PIC X(7).
          05 AUT03   PIC X(7).
          05 AUT04   PIC X(7).
          05 AUT05   PIC X(7).
          05 AUT06   PIC X(7).
          05 AUT07   PIC X(7).
          05 AUT08   PIC X(7).
          05 AUT09   PIC X(7).
          05 AUT10   PIC X(7).
          05 AUT11   PIC X(7).
          05 AUT12   PIC X(7).
          05 AUT13   PIC X(7).
          05 AUT14   PIC X(7).
          05 AUT15   PIC X(7).
          05 AUT16   PIC X(7).
          05 AUT17   PIC X(7).
          05 AUT18   PIC X(7).
          05 AUT19   PIC X(7).
          05 AUT20   PIC X(7).
          05 AUT21   PIC X(7).
          05 AUT22   PIC X(7).
          05 AUT23   PIC X(7).
          05 AUT24   PIC X(7).
          05 AUT25   PIC X(7).
          05 AUT26   PIC X(7).
          05 AUT27   PIC X(7).
          05 AUT28   PIC X(7).
          05 AUT29   PIC X(7).
          05 AUT30   PIC X(7).
          05 AUT31   PIC X(7).
          05 AUT32   PIC X(7).
          05 AUT33   PIC X(7).
          05 AUT34   PIC X(7).
          05 AUT35   PIC X(7).
          05 AUT36   PIC X(7).
          05 AUT37   PIC X(7).
          05 PST01   PIC X(5).
          05 PST02   PIC X(5).
          05 PST03   PIC X(5).
          05 PST04   PIC X(5).
          05 PST05   PIC X(5).
          05 PST06   PIC X(5).
          05 PST07   PIC X(5).
          05 PST08   PIC X(5).
          05 PST09   PIC X(5).
          05 PST10   PIC X(5).
          05 PST11   PIC X(5).
          05 PST12   PIC X(5).
          05 PST13   PIC X(5).
          05 PST14   PIC X(5).
          05 PST15   PIC X(5).
          05 PST16   PIC X(5).
          05 PST17   PIC X(5).
          05 PST18   PIC X(5).
          05 PST19   PIC X(5).
          05 PST20   PIC X(5).
          05 PST21   PIC X(5).
          05 PST22   PIC X(5).
          05 PST23   PIC X(5).
          05 PST24   PIC X(5).
          05 PST25   PIC X(5).
          05 PST26   PIC X(5).
          05 PST27   PIC X(5).
          05 PST28   PIC X(5).
          05 PST29   PIC X(5).
          05 PST30   PIC X(5).
          05 PST31   PIC X(5).
          05 PST32   PIC X(5).
          05 PST33   PIC X(5).
          05 PST34   PIC X(5).
          05 PST35   PIC X(5).
          05 PST36   PIC X(5).
          05 PST37   PIC X(5).
          05 VWS01   PIC X(5).
          05 VWS02   PIC X(5).
          05 VWS03   PIC X(5).
          05 VWS04   PIC X(5).
          05 VWS05   PIC X(5).
          05 VWS06   PIC X(5).
          05 VWS07   PIC X(5).
          05 VWS08   PIC X(5).
          05 VWS09   PIC X(5).
          05 VWS10   PIC X(5).
          05 VWS11   PIC X(5).
          05 VWS12   PIC X(5).
          05 VWS13   PIC X(5).
          05 VWS14   PIC X(5).
          05 VWS15   PIC X(5).
          05 VWS16   PIC X(5).
          05 VWS17   PIC X(5).
          05 VWS18   PIC X(5).
          05 VWS19   PIC X(5).
          05 VWS20   PIC X(5).
          05 VWS21   PIC X(5).
          05 VWS22   PIC X(5).
          05 VWS23   PIC X(5).
          05 VWS24   PIC X(5).
          05 VWS25   PIC X(5).
          05 VWS26   PIC X(5).
          05 VWS27   PIC X(5).
          05 VWS28   PIC X(5).
          05 VWS29   PIC X(5).
          05 VWS30   PIC X(5).
          05 VWS31   PIC X(5).
          05 VWS32   PIC X(5).
          05 VWS33   PIC X(5).
          05 VWS34   PIC X(5).
          05 VWS35   PIC X(5).
          05 VWS36   PIC X(5).
          05 VWS37   PIC X(5).
          05 LIK01   PIC X(5).
          05 LIK02   PIC X(5).
          05 LIK03   PIC X(5).
          05 LIK04   PIC X(5).
          05 LIK05   PIC X(5).
          05 LIK06   PIC X(5).
          05 LIK07   PIC X(5).
          05 LIK08   PIC X(5).
          05 LIK09   PIC X(5).
          05 LIK10   PIC X(5).
          05 LIK11   PIC X(5).
          05 LIK12   PIC X(5).
          05 LIK13   PIC X(5).
          05 LIK14   PIC X(5).
          05 LIK15   PIC X(5).
          05 LIK16   PIC X(5).
          05 LIK17   PIC X(5).
          05 LIK18   PIC X(5).
          05 LIK19   PIC X(5).
          05 LIK20   PIC X(5).
          05 LIK21   PIC X(5).
          05 LIK22   PIC X(5).
          05 LIK23   PIC X(5).
          05 LIK24   PIC X(5).
          05 LIK25   PIC X(5).
          05 LIK26   PIC X(5).
          05 LIK27   PIC X(5).
          05 LIK28   PIC X(5).
          05 LIK29   PIC X(5).
          05 LIK30   PIC X(5).
          05 LIK31   PIC X(5).
          05 LIK32   PIC X(5).
          05 LIK33   PIC X(5).
          05 LIK34   PIC X(5).
          05 LIK35   PIC X(5).
          05 LIK36   PIC X(5).
          05 LIK37   PIC X(5).
          05 DAT01   PIC X(7).
          05 DAT02   PIC X(7).
          05 DAT03   PIC X(7).
          05 DAT04   PIC X(7).
          05 DAT05   PIC X(7).
          05 DAT06   PIC X(7).
          05 DAT07   PIC X(7).
          05 DAT08   PIC X(7).
          05 DAT09   PIC X(7).
          05 DAT10   PIC X(7).
          05 DAT11   PIC X(7).
          05 DAT12   PIC X(7).
          05 DAT13   PIC X(7).
          05 DAT14   PIC X(7).
          05 DAT15   PIC X(7).
          05 DAT16   PIC X(7).
          05 DAT17   PIC X(7).
          05 DAT18   PIC X(7).
          05 DAT19   PIC X(7).
          05 DAT20   PIC X(7).
          05 DAT21   PIC X(7).
          05 DAT22   PIC X(7).
          05 DAT23   PIC X(7).
          05 DAT24   PIC X(7).
          05 DAT25   PIC X(7).
          05 DAT26   PIC X(7).
          05 DAT27   PIC X(7).
          05 DAT28   PIC X(7).
          05 DAT29   PIC X(7).
          05 DAT30   PIC X(7).
          05 DAT31   PIC X(7).
          05 DAT32   PIC X(7).
          05 DAT33   PIC X(7).
          05 DAT34   PIC X(7).
          05 DAT35   PIC X(7).
          05 DAT36   PIC X(7).
          05 DAT37   PIC X(7).
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
          05 ROW01   PIC X(78).
          05 ROW01-C PIC X(9).
          05 ROW02   PIC X(78).
          05 ROW02-C PIC X(9).
          05 ROW03   PIC X(78).
          05 ROW03-C PIC X(9).
          05 ROW04   PIC X(78).
          05 ROW04-C PIC X(9).
          05 ROW05   PIC X(78).
          05 ROW05-C PIC X(9).
          05 ROW06   PIC X(78).
          05 ROW06-C PIC X(9).
          05 ROW07   PIC X(78).
          05 ROW07-C PIC X(9).
          05 ROW08   PIC X(78).
          05 ROW08-C PIC X(9).
          05 ROW09   PIC X(78).
          05 ROW09-C PIC X(9).
          05 ROW10   PIC X(78).
          05 ROW10-C PIC X(9).
          05 ROW11   PIC X(78).
          05 ROW11-C PIC X(9).
          05 ROW12   PIC X(78).
          05 ROW12-C PIC X(9).
          05 ROW13   PIC X(78).
          05 ROW13-C PIC X(9).
          05 ROW14   PIC X(78).
          05 ROW14-C PIC X(9).
          05 ROW15   PIC X(78).
          05 ROW15-C PIC X(9).
          05 ROW16   PIC X(78).
          05 ROW16-C PIC X(9).
          05 ROW17   PIC X(78).
          05 ROW17-C PIC X(9).
          05 ROW18   PIC X(78).
          05 ROW18-C PIC X(9).
          05 ROW19   PIC X(78).
          05 ROW19-C PIC X(9).
          05 ROW20   PIC X(78).
          05 ROW20-C PIC X(9).
          05 ROW21   PIC X(78).
          05 ROW21-C PIC X(9).
          05 ROW22   PIC X(78).
          05 ROW22-C PIC X(9).
          05 ROW23   PIC X(78).
          05 ROW23-C PIC X(9).
          05 ROW24   PIC X(78).
          05 ROW24-C PIC X(9).
          05 ROW25   PIC X(78).
          05 ROW25-C PIC X(9).
          05 ROW26   PIC X(78).
          05 ROW26-C PIC X(9).
          05 ROW27   PIC X(78).
          05 ROW27-C PIC X(9).
          05 ROW28   PIC X(78).
          05 ROW28-C PIC X(9).
          05 ROW29   PIC X(78).
          05 ROW29-C PIC X(9).
          05 ROW30   PIC X(78).
          05 ROW30-C PIC X(9).
          05 ROW31   PIC X(78).
          05 ROW31-C PIC X(9).
          05 ROW32   PIC X(78).
          05 ROW32-C PIC X(9).
          05 ROW33   PIC X(78).
          05 ROW33-C PIC X(9).
          05 ROW34   PIC X(78).
          05 ROW34-C PIC X(9).
          05 ROW35   PIC X(78).
          05 ROW35-C PIC X(9).
          05 ROW36   PIC X(78).
          05 ROW36-C PIC X(9).
          05 ROW37   PIC X(78).
          05 ROW37-C PIC X(9).
          05 ROW38   PIC X(78).
          05 ROW38-C PIC X(9).

      *>shdow OCCURS tables
      *> FETCH loops fill these
      *> by subscript and an unrolled fan-out copies slot n into
      *> the individually-named map field (esdc.cob idiom).
       01 SHL.
          05 T-SEL  PIC X(1)  OCCURS 37.
       01 SHT.
          05 T-TIT  PIC X(41) OCCURS 37.
       01 SHTC.
          05 T-TITC PIC X(9)  OCCURS 37.
       01 SHA.
          05 T-AUT  PIC X(7)  OCCURS 37.
       01 SHP.
          05 T-PST  PIC X(5)  OCCURS 37.
       01 SHV.
          05 T-VWS  PIC X(5)  OCCURS 37.
       01 SHK.
          05 T-LIK  PIC X(5)  OCCURS 37.
       01 SHD.
          05 T-DAT  PIC X(7)  OCCURS 37.
       01 SHR.
          05 V-ROW  PIC X(78) OCCURS 38.
       01 SHRC.
          05 V-ROWC PIC X(9)  OCCURS 38.

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

      *> GATHER-SELECTORS -- first non-blank selector wins.
      *> took me a minute to remember that. The
      *> SELnn fan-in is unrolled because bricks has no REDEFINES.
       GATHER-SELECTORS.
           MOVE SEL01 TO T-SEL(1).
           MOVE SEL02 TO T-SEL(2).
           MOVE SEL03 TO T-SEL(3).
           MOVE SEL04 TO T-SEL(4).
           MOVE SEL05 TO T-SEL(5).
           MOVE SEL06 TO T-SEL(6).
           MOVE SEL07 TO T-SEL(7).
           MOVE SEL08 TO T-SEL(8).
           MOVE SEL09 TO T-SEL(9).
           MOVE SEL10 TO T-SEL(10).
           MOVE SEL11 TO T-SEL(11).
           MOVE SEL12 TO T-SEL(12).
           MOVE SEL13 TO T-SEL(13).
           MOVE SEL14 TO T-SEL(14).
           MOVE SEL15 TO T-SEL(15).
           MOVE SEL16 TO T-SEL(16).
           MOVE SEL17 TO T-SEL(17).
           MOVE SEL18 TO T-SEL(18).
           MOVE SEL19 TO T-SEL(19).
           MOVE SEL20 TO T-SEL(20).
           MOVE SEL21 TO T-SEL(21).
           MOVE SEL22 TO T-SEL(22).
           MOVE SEL23 TO T-SEL(23).
           MOVE SEL24 TO T-SEL(24).
           MOVE SEL25 TO T-SEL(25).
           MOVE SEL26 TO T-SEL(26).
           MOVE SEL27 TO T-SEL(27).
           MOVE SEL28 TO T-SEL(28).
           MOVE SEL29 TO T-SEL(29).
           MOVE SEL30 TO T-SEL(30).
           MOVE SEL31 TO T-SEL(31).
           MOVE SEL32 TO T-SEL(32).
           MOVE SEL33 TO T-SEL(33).
           MOVE SEL34 TO T-SEL(34).
           MOVE SEL35 TO T-SEL(35).
           MOVE SEL36 TO T-SEL(36).
           MOVE SEL37 TO T-SEL(37).
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
           MOVE SPACES TO SCRL.
           MOVE SPACES TO SHL SHT SHTC SHA SHP SHV SHK SHD.
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
           PERFORM FAN-OUT-LIST.
           PERFORM COMPOSE-LIST-CHROME.
           EXEC CICS SEND MAP(WS-LMAP) FROM(SCRL) ERASE END-EXEC.

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
               MOVE 'SQL error - see bricks log' TO ST-MSG
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
               MOVE 'SQL error - see bricks log' TO ST-MSG
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
               MOVE 'SQL error - see bricks log' TO ST-MSG
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
               MOVE 'SQL error - see bricks log' TO ST-MSG
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

      *> FAN-OUT-LIST -- unrolled shadow-to-map copy (no REDEFINES
      *> in bricks COBOL; see esdc.cob PLACE-ROW for the idiom).
       FAN-OUT-LIST.
           MOVE T-TIT(1) TO TIT01.
           MOVE T-TITC(1) TO TIT01-C.
           MOVE T-AUT(1) TO AUT01.
           MOVE T-PST(1) TO PST01.
           MOVE T-VWS(1) TO VWS01.
           MOVE T-LIK(1) TO LIK01.
           MOVE T-DAT(1) TO DAT01.
           MOVE T-TIT(2) TO TIT02.
           MOVE T-TITC(2) TO TIT02-C.
           MOVE T-AUT(2) TO AUT02.
           MOVE T-PST(2) TO PST02.
           MOVE T-VWS(2) TO VWS02.
           MOVE T-LIK(2) TO LIK02.
           MOVE T-DAT(2) TO DAT02.
           MOVE T-TIT(3) TO TIT03.
           MOVE T-TITC(3) TO TIT03-C.
           MOVE T-AUT(3) TO AUT03.
           MOVE T-PST(3) TO PST03.
           MOVE T-VWS(3) TO VWS03.
           MOVE T-LIK(3) TO LIK03.
           MOVE T-DAT(3) TO DAT03.
           MOVE T-TIT(4) TO TIT04.
           MOVE T-TITC(4) TO TIT04-C.
           MOVE T-AUT(4) TO AUT04.
           MOVE T-PST(4) TO PST04.
           MOVE T-VWS(4) TO VWS04.
           MOVE T-LIK(4) TO LIK04.
           MOVE T-DAT(4) TO DAT04.
           MOVE T-TIT(5) TO TIT05.
           MOVE T-TITC(5) TO TIT05-C.
           MOVE T-AUT(5) TO AUT05.
           MOVE T-PST(5) TO PST05.
           MOVE T-VWS(5) TO VWS05.
           MOVE T-LIK(5) TO LIK05.
           MOVE T-DAT(5) TO DAT05.
           MOVE T-TIT(6) TO TIT06.
           MOVE T-TITC(6) TO TIT06-C.
           MOVE T-AUT(6) TO AUT06.
           MOVE T-PST(6) TO PST06.
           MOVE T-VWS(6) TO VWS06.
           MOVE T-LIK(6) TO LIK06.
           MOVE T-DAT(6) TO DAT06.
           MOVE T-TIT(7) TO TIT07.
           MOVE T-TITC(7) TO TIT07-C.
           MOVE T-AUT(7) TO AUT07.
           MOVE T-PST(7) TO PST07.
           MOVE T-VWS(7) TO VWS07.
           MOVE T-LIK(7) TO LIK07.
           MOVE T-DAT(7) TO DAT07.
           MOVE T-TIT(8) TO TIT08.
           MOVE T-TITC(8) TO TIT08-C.
           MOVE T-AUT(8) TO AUT08.
           MOVE T-PST(8) TO PST08.
           MOVE T-VWS(8) TO VWS08.
           MOVE T-LIK(8) TO LIK08.
           MOVE T-DAT(8) TO DAT08.
           MOVE T-TIT(9) TO TIT09.
           MOVE T-TITC(9) TO TIT09-C.
           MOVE T-AUT(9) TO AUT09.
           MOVE T-PST(9) TO PST09.
           MOVE T-VWS(9) TO VWS09.
           MOVE T-LIK(9) TO LIK09.
           MOVE T-DAT(9) TO DAT09.
           MOVE T-TIT(10) TO TIT10.
           MOVE T-TITC(10) TO TIT10-C.
           MOVE T-AUT(10) TO AUT10.
           MOVE T-PST(10) TO PST10.
           MOVE T-VWS(10) TO VWS10.
           MOVE T-LIK(10) TO LIK10.
           MOVE T-DAT(10) TO DAT10.
           MOVE T-TIT(11) TO TIT11.
           MOVE T-TITC(11) TO TIT11-C.
           MOVE T-AUT(11) TO AUT11.
           MOVE T-PST(11) TO PST11.
           MOVE T-VWS(11) TO VWS11.
           MOVE T-LIK(11) TO LIK11.
           MOVE T-DAT(11) TO DAT11.
           MOVE T-TIT(12) TO TIT12.
           MOVE T-TITC(12) TO TIT12-C.
           MOVE T-AUT(12) TO AUT12.
           MOVE T-PST(12) TO PST12.
           MOVE T-VWS(12) TO VWS12.
           MOVE T-LIK(12) TO LIK12.
           MOVE T-DAT(12) TO DAT12.
           MOVE T-TIT(13) TO TIT13.
           MOVE T-TITC(13) TO TIT13-C.
           MOVE T-AUT(13) TO AUT13.
           MOVE T-PST(13) TO PST13.
           MOVE T-VWS(13) TO VWS13.
           MOVE T-LIK(13) TO LIK13.
           MOVE T-DAT(13) TO DAT13.
           MOVE T-TIT(14) TO TIT14.
           MOVE T-TITC(14) TO TIT14-C.
           MOVE T-AUT(14) TO AUT14.
           MOVE T-PST(14) TO PST14.
           MOVE T-VWS(14) TO VWS14.
           MOVE T-LIK(14) TO LIK14.
           MOVE T-DAT(14) TO DAT14.
           MOVE T-TIT(15) TO TIT15.
           MOVE T-TITC(15) TO TIT15-C.
           MOVE T-AUT(15) TO AUT15.
           MOVE T-PST(15) TO PST15.
           MOVE T-VWS(15) TO VWS15.
           MOVE T-LIK(15) TO LIK15.
           MOVE T-DAT(15) TO DAT15.
           MOVE T-TIT(16) TO TIT16.
           MOVE T-TITC(16) TO TIT16-C.
           MOVE T-AUT(16) TO AUT16.
           MOVE T-PST(16) TO PST16.
           MOVE T-VWS(16) TO VWS16.
           MOVE T-LIK(16) TO LIK16.
           MOVE T-DAT(16) TO DAT16.
           MOVE T-TIT(17) TO TIT17.
           MOVE T-TITC(17) TO TIT17-C.
           MOVE T-AUT(17) TO AUT17.
           MOVE T-PST(17) TO PST17.
           MOVE T-VWS(17) TO VWS17.
           MOVE T-LIK(17) TO LIK17.
           MOVE T-DAT(17) TO DAT17.
           MOVE T-TIT(18) TO TIT18.
           MOVE T-TITC(18) TO TIT18-C.
           MOVE T-AUT(18) TO AUT18.
           MOVE T-PST(18) TO PST18.
           MOVE T-VWS(18) TO VWS18.
           MOVE T-LIK(18) TO LIK18.
           MOVE T-DAT(18) TO DAT18.
           MOVE T-TIT(19) TO TIT19.
           MOVE T-TITC(19) TO TIT19-C.
           MOVE T-AUT(19) TO AUT19.
           MOVE T-PST(19) TO PST19.
           MOVE T-VWS(19) TO VWS19.
           MOVE T-LIK(19) TO LIK19.
           MOVE T-DAT(19) TO DAT19.
           MOVE T-TIT(20) TO TIT20.
           MOVE T-TITC(20) TO TIT20-C.
           MOVE T-AUT(20) TO AUT20.
           MOVE T-PST(20) TO PST20.
           MOVE T-VWS(20) TO VWS20.
           MOVE T-LIK(20) TO LIK20.
           MOVE T-DAT(20) TO DAT20.
           MOVE T-TIT(21) TO TIT21.
           MOVE T-TITC(21) TO TIT21-C.
           MOVE T-AUT(21) TO AUT21.
           MOVE T-PST(21) TO PST21.
           MOVE T-VWS(21) TO VWS21.
           MOVE T-LIK(21) TO LIK21.
           MOVE T-DAT(21) TO DAT21.
           MOVE T-TIT(22) TO TIT22.
           MOVE T-TITC(22) TO TIT22-C.
           MOVE T-AUT(22) TO AUT22.
           MOVE T-PST(22) TO PST22.
           MOVE T-VWS(22) TO VWS22.
           MOVE T-LIK(22) TO LIK22.
           MOVE T-DAT(22) TO DAT22.
           MOVE T-TIT(23) TO TIT23.
           MOVE T-TITC(23) TO TIT23-C.
           MOVE T-AUT(23) TO AUT23.
           MOVE T-PST(23) TO PST23.
           MOVE T-VWS(23) TO VWS23.
           MOVE T-LIK(23) TO LIK23.
           MOVE T-DAT(23) TO DAT23.
           MOVE T-TIT(24) TO TIT24.
           MOVE T-TITC(24) TO TIT24-C.
           MOVE T-AUT(24) TO AUT24.
           MOVE T-PST(24) TO PST24.
           MOVE T-VWS(24) TO VWS24.
           MOVE T-LIK(24) TO LIK24.
           MOVE T-DAT(24) TO DAT24.
           MOVE T-TIT(25) TO TIT25.
           MOVE T-TITC(25) TO TIT25-C.
           MOVE T-AUT(25) TO AUT25.
           MOVE T-PST(25) TO PST25.
           MOVE T-VWS(25) TO VWS25.
           MOVE T-LIK(25) TO LIK25.
           MOVE T-DAT(25) TO DAT25.
           MOVE T-TIT(26) TO TIT26.
           MOVE T-TITC(26) TO TIT26-C.
           MOVE T-AUT(26) TO AUT26.
           MOVE T-PST(26) TO PST26.
           MOVE T-VWS(26) TO VWS26.
           MOVE T-LIK(26) TO LIK26.
           MOVE T-DAT(26) TO DAT26.
           MOVE T-TIT(27) TO TIT27.
           MOVE T-TITC(27) TO TIT27-C.
           MOVE T-AUT(27) TO AUT27.
           MOVE T-PST(27) TO PST27.
           MOVE T-VWS(27) TO VWS27.
           MOVE T-LIK(27) TO LIK27.
           MOVE T-DAT(27) TO DAT27.
           MOVE T-TIT(28) TO TIT28.
           MOVE T-TITC(28) TO TIT28-C.
           MOVE T-AUT(28) TO AUT28.
           MOVE T-PST(28) TO PST28.
           MOVE T-VWS(28) TO VWS28.
           MOVE T-LIK(28) TO LIK28.
           MOVE T-DAT(28) TO DAT28.
           MOVE T-TIT(29) TO TIT29.
           MOVE T-TITC(29) TO TIT29-C.
           MOVE T-AUT(29) TO AUT29.
           MOVE T-PST(29) TO PST29.
           MOVE T-VWS(29) TO VWS29.
           MOVE T-LIK(29) TO LIK29.
           MOVE T-DAT(29) TO DAT29.
           MOVE T-TIT(30) TO TIT30.
           MOVE T-TITC(30) TO TIT30-C.
           MOVE T-AUT(30) TO AUT30.
           MOVE T-PST(30) TO PST30.
           MOVE T-VWS(30) TO VWS30.
           MOVE T-LIK(30) TO LIK30.
           MOVE T-DAT(30) TO DAT30.
           MOVE T-TIT(31) TO TIT31.
           MOVE T-TITC(31) TO TIT31-C.
           MOVE T-AUT(31) TO AUT31.
           MOVE T-PST(31) TO PST31.
           MOVE T-VWS(31) TO VWS31.
           MOVE T-LIK(31) TO LIK31.
           MOVE T-DAT(31) TO DAT31.
           MOVE T-TIT(32) TO TIT32.
           MOVE T-TITC(32) TO TIT32-C.
           MOVE T-AUT(32) TO AUT32.
           MOVE T-PST(32) TO PST32.
           MOVE T-VWS(32) TO VWS32.
           MOVE T-LIK(32) TO LIK32.
           MOVE T-DAT(32) TO DAT32.
           MOVE T-TIT(33) TO TIT33.
           MOVE T-TITC(33) TO TIT33-C.
           MOVE T-AUT(33) TO AUT33.
           MOVE T-PST(33) TO PST33.
           MOVE T-VWS(33) TO VWS33.
           MOVE T-LIK(33) TO LIK33.
           MOVE T-DAT(33) TO DAT33.
           MOVE T-TIT(34) TO TIT34.
           MOVE T-TITC(34) TO TIT34-C.
           MOVE T-AUT(34) TO AUT34.
           MOVE T-PST(34) TO PST34.
           MOVE T-VWS(34) TO VWS34.
           MOVE T-LIK(34) TO LIK34.
           MOVE T-DAT(34) TO DAT34.
           MOVE T-TIT(35) TO TIT35.
           MOVE T-TITC(35) TO TIT35-C.
           MOVE T-AUT(35) TO AUT35.
           MOVE T-PST(35) TO PST35.
           MOVE T-VWS(35) TO VWS35.
           MOVE T-LIK(35) TO LIK35.
           MOVE T-DAT(35) TO DAT35.
           MOVE T-TIT(36) TO TIT36.
           MOVE T-TITC(36) TO TIT36-C.
           MOVE T-AUT(36) TO AUT36.
           MOVE T-PST(36) TO PST36.
           MOVE T-VWS(36) TO VWS36.
           MOVE T-LIK(36) TO LIK36.
           MOVE T-DAT(36) TO DAT36.
           MOVE T-TIT(37) TO TIT37.
           MOVE T-TITC(37) TO TIT37-C.
           MOVE T-AUT(37) TO AUT37.
           MOVE T-PST(37) TO PST37.
           MOVE T-VWS(37) TO VWS37.
           MOVE T-LIK(37) TO LIK37.
           MOVE T-DAT(37) TO DAT37.

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

      *> ===========================================================
      *> PAINT-VIEW -- header SELECT INTO, then the flat-line model:
      *> every post contributes a header line, wrapped body lines
      *> and one blank separator; ST-OFF indexes the first visible
      *> line. A vanished topic bounces back to the list.
      *> ===========================================================
       PAINT-VIEW.
           MOVE SPACES TO SCRV.
           MOVE ST-TOPIC TO WS-TOPIC.
           PERFORM GET-TOPIC-HEADER.
           IF WS-HDROK = 'N' THEN
               MOVE 'L' TO ST-SCREEN
      *> SQLCODE 100 -> the topic vanished; a negative SQLCODE
      *> already left its own message in ST-MSG above.
               IF ST-MSG = SPACES THEN
                   MOVE 'Topic not found' TO ST-MSG
               END-IF
               PERFORM PAINT-LIST
           ELSE
               PERFORM BUILD-PASS
      *> Posts shrank since the last task and the offset now
      *> points past the end: clamp to the last page, rebuild.
               IF ST-OFF >= ST-TOTL AND ST-TOTL > 0 THEN
                   COMPUTE WS-TMP = ST-TOTL - 1
                   DIVIDE WS-TMP BY WS-VNVIS GIVING WS-TMP2
                   COMPUTE ST-OFF = WS-TMP2 * WS-VNVIS
                   PERFORM BUILD-PASS
               END-IF
               PERFORM FAN-OUT-VIEW
               PERFORM COMPOSE-VIEW-CHROME
               EXEC CICS SEND MAP(WS-VMAP) FROM(SCRV) ERASE
                    END-EXEC
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
               MOVE 'SQL error - see bricks log' TO ST-MSG
           END-IF.

      *> BUILD-PASS -- walk every post line of the topic through
      *> the wrap/window pipeline. Cheap to run twice when the
      *> offset needs clamping.
       BUILD-PASS.
           MOVE 0 TO WS-LINENO.
           MOVE 0 TO WS-SHOWN.
           MOVE 0 TO WS-PREVPID.
           MOVE 0 TO WS-PNUM.
           MOVE SPACES TO SHR SHRC.
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
               MOVE 'SQL error - see bricks log' TO ST-MSG
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
               MOVE 'SQL error - see bricks log' TO ST-MSG
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
               MOVE 'SQL error - see bricks log' TO ST-MSG
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
               MOVE 'SQL error - see bricks log' TO ST-MSG
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

       FAN-OUT-VIEW.
           MOVE V-ROW(1) TO ROW01.
           MOVE V-ROWC(1) TO ROW01-C.
           MOVE V-ROW(2) TO ROW02.
           MOVE V-ROWC(2) TO ROW02-C.
           MOVE V-ROW(3) TO ROW03.
           MOVE V-ROWC(3) TO ROW03-C.
           MOVE V-ROW(4) TO ROW04.
           MOVE V-ROWC(4) TO ROW04-C.
           MOVE V-ROW(5) TO ROW05.
           MOVE V-ROWC(5) TO ROW05-C.
           MOVE V-ROW(6) TO ROW06.
           MOVE V-ROWC(6) TO ROW06-C.
           MOVE V-ROW(7) TO ROW07.
           MOVE V-ROWC(7) TO ROW07-C.
           MOVE V-ROW(8) TO ROW08.
           MOVE V-ROWC(8) TO ROW08-C.
           MOVE V-ROW(9) TO ROW09.
           MOVE V-ROWC(9) TO ROW09-C.
           MOVE V-ROW(10) TO ROW10.
           MOVE V-ROWC(10) TO ROW10-C.
           MOVE V-ROW(11) TO ROW11.
           MOVE V-ROWC(11) TO ROW11-C.
           MOVE V-ROW(12) TO ROW12.
           MOVE V-ROWC(12) TO ROW12-C.
           MOVE V-ROW(13) TO ROW13.
           MOVE V-ROWC(13) TO ROW13-C.
           MOVE V-ROW(14) TO ROW14.
           MOVE V-ROWC(14) TO ROW14-C.
           MOVE V-ROW(15) TO ROW15.
           MOVE V-ROWC(15) TO ROW15-C.
           MOVE V-ROW(16) TO ROW16.
           MOVE V-ROWC(16) TO ROW16-C.
           MOVE V-ROW(17) TO ROW17.
           MOVE V-ROWC(17) TO ROW17-C.
           MOVE V-ROW(18) TO ROW18.
           MOVE V-ROWC(18) TO ROW18-C.
           MOVE V-ROW(19) TO ROW19.
           MOVE V-ROWC(19) TO ROW19-C.
           MOVE V-ROW(20) TO ROW20.
           MOVE V-ROWC(20) TO ROW20-C.
           MOVE V-ROW(21) TO ROW21.
           MOVE V-ROWC(21) TO ROW21-C.
           MOVE V-ROW(22) TO ROW22.
           MOVE V-ROWC(22) TO ROW22-C.
           MOVE V-ROW(23) TO ROW23.
           MOVE V-ROWC(23) TO ROW23-C.
           MOVE V-ROW(24) TO ROW24.
           MOVE V-ROWC(24) TO ROW24-C.
           MOVE V-ROW(25) TO ROW25.
           MOVE V-ROWC(25) TO ROW25-C.
           MOVE V-ROW(26) TO ROW26.
           MOVE V-ROWC(26) TO ROW26-C.
           MOVE V-ROW(27) TO ROW27.
           MOVE V-ROWC(27) TO ROW27-C.
           MOVE V-ROW(28) TO ROW28.
           MOVE V-ROWC(28) TO ROW28-C.
           MOVE V-ROW(29) TO ROW29.
           MOVE V-ROWC(29) TO ROW29-C.
           MOVE V-ROW(30) TO ROW30.
           MOVE V-ROWC(30) TO ROW30-C.
           MOVE V-ROW(31) TO ROW31.
           MOVE V-ROWC(31) TO ROW31-C.
           MOVE V-ROW(32) TO ROW32.
           MOVE V-ROWC(32) TO ROW32-C.
           MOVE V-ROW(33) TO ROW33.
           MOVE V-ROWC(33) TO ROW33-C.
           MOVE V-ROW(34) TO ROW34.
           MOVE V-ROWC(34) TO ROW34-C.
           MOVE V-ROW(35) TO ROW35.
           MOVE V-ROWC(35) TO ROW35-C.
           MOVE V-ROW(36) TO ROW36.
           MOVE V-ROWC(36) TO ROW36-C.
           MOVE V-ROW(37) TO ROW37.
           MOVE V-ROWC(37) TO ROW37-C.
           MOVE V-ROW(38) TO ROW38.
           MOVE V-ROWC(38) TO ROW38-C.

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
