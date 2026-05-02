       *> copyright 2026 by moshix
       IDENTIFICATION DIVISION.
       PROGRAM-ID. GUSL.

       DATA DIVISION.
       WORKING-STORAGE SECTION.
       01 SCR.
          05 INFOLINE PIC X(78).
          05 ROW1.
             10 K1   PIC X(8).
             10 SP1A PIC X(1).
             10 N1   PIC X(28).
             10 SP1B PIC X(1).
             10 C1   PIC X(18).
             10 SP1C PIC X(1).
             10 P1   PIC X(13).
          05 ROW2.
             10 K2   PIC X(8).
             10 SP2A PIC X(1).
             10 N2   PIC X(28).
             10 SP2B PIC X(1).
             10 C2   PIC X(18).
             10 SP2C PIC X(1).
             10 P2   PIC X(13).
          05 ROW3.
             10 K3   PIC X(8).
             10 SP3A PIC X(1).
             10 N3   PIC X(28).
             10 SP3B PIC X(1).
             10 C3   PIC X(18).
             10 SP3C PIC X(1).
             10 P3   PIC X(13).
          05 ROW4.
             10 K4   PIC X(8).
             10 SP4A PIC X(1).
             10 N4   PIC X(28).
             10 SP4B PIC X(1).
             10 C4   PIC X(18).
             10 SP4C PIC X(1).
             10 P4   PIC X(13).
          05 ROW5.
             10 K5   PIC X(8).
             10 SP5A PIC X(1).
             10 N5   PIC X(28).
             10 SP5B PIC X(1).
             10 C5   PIC X(18).
             10 SP5C PIC X(1).
             10 P5   PIC X(13).
          05 ROW6.
             10 K6   PIC X(8).
             10 SP6A PIC X(1).
             10 N6   PIC X(28).
             10 SP6B PIC X(1).
             10 C6   PIC X(18).
             10 SP6C PIC X(1).
             10 P6   PIC X(13).
          05 ROW7.
             10 K7   PIC X(8).
             10 SP7A PIC X(1).
             10 N7   PIC X(28).
             10 SP7B PIC X(1).
             10 C7   PIC X(18).
             10 SP7C PIC X(1).
             10 P7   PIC X(13).
          05 ROW8.
             10 K8   PIC X(8).
             10 SP8A PIC X(1).
             10 N8   PIC X(28).
             10 SP8B PIC X(1).
             10 C8   PIC X(18).
             10 SP8C PIC X(1).
             10 P8   PIC X(13).
          05 ROW9.
             10 K9   PIC X(8).
             10 SP9A PIC X(1).
             10 N9   PIC X(28).
             10 SP9B PIC X(1).
             10 C9   PIC X(18).
             10 SP9C PIC X(1).
             10 P9   PIC X(13).
          05 ROW10.
             10 K10   PIC X(8).
             10 SP10A PIC X(1).
             10 N10   PIC X(28).
             10 SP10B PIC X(1).
             10 C10   PIC X(18).
             10 SP10C PIC X(1).
             10 P10   PIC X(13).
          05 ROW11.
             10 K11   PIC X(8).
             10 SP11A PIC X(1).
             10 N11   PIC X(28).
             10 SP11B PIC X(1).
             10 C11   PIC X(18).
             10 SP11C PIC X(1).
             10 P11   PIC X(13).
          05 ROW12.
             10 K12   PIC X(8).
             10 SP12A PIC X(1).
             10 N12   PIC X(28).
             10 SP12B PIC X(1).
             10 C12   PIC X(18).
             10 SP12C PIC X(1).
             10 P12   PIC X(13).
          05 ROW13.
             10 K13   PIC X(8).
             10 SP13A PIC X(1).
             10 N13   PIC X(28).
             10 SP13B PIC X(1).
             10 C13   PIC X(18).
             10 SP13C PIC X(1).
             10 P13   PIC X(13).
          05 ROW14.
             10 K14   PIC X(8).
             10 SP14A PIC X(1).
             10 N14   PIC X(28).
             10 SP14B PIC X(1).
             10 C14   PIC X(18).
             10 SP14C PIC X(1).
             10 P14   PIC X(13).
          05 ROW15.
             10 K15   PIC X(8).
             10 SP15A PIC X(1).
             10 N15   PIC X(28).
             10 SP15B PIC X(1).
             10 C15   PIC X(18).
             10 SP15C PIC X(1).
             10 P15   PIC X(13).

       01 KEY-IN PIC X(8).
       01 REC    PIC X(120).
       01 NCOUNT PIC 9(4) VALUE 0.

       01 PAGE-NO  PIC 9(4) VALUE 1.
       01 SKIPCNT  PIC 9(8).
       01 SKIPGOAL PIC 9(8).
       01 EXIT-FLAG PIC X(1) VALUE 'N'.

      *> Scratch UNSTRING targets, overwritten per row.
       01 SNAME    PIC X(28).
       01 SADDR    PIC X(40).
       01 SCITY    PIC X(18).
       01 SPHONE   PIC X(13).

       PROCEDURE DIVISION.
       MAIN.
           PERFORM PAGE-LOOP UNTIL EXIT-FLAG = 'Y'.

           MOVE NCOUNT TO DFHCOMMAREA.
           EXEC CICS RETURN END-EXEC.
           STOP RUN.

       PAGE-LOOP.
      *> Reset per-page state. Each page restarts the browse and
      *> recomputes the count visible on this page.
           PERFORM CLEAR-ROWS.
           MOVE 0 TO NCOUNT.
           MOVE SPACES TO INFOLINE.
           MOVE 'GUSL -- customers (PF7=Prev PF8=Next PF3=Exit).' TO INFOLINE.

           EXEC CICS STARTBR FILE('customers') END-EXEC.

      *> Skip past prior pages -- PERFORM SKIP-ONE in a UNTIL loop
      *> until the skip counter reaches (PAGE-1)*15. SKIP-ONE bumps
      *> SKIPCNT past SKIPGOAL on EOF so the loop terminates even when
      *> the operator paged past the end.
           COMPUTE SKIPGOAL = (PAGE-NO - 1) * 15.
           MOVE 0 TO SKIPCNT.
           PERFORM SKIP-ONE UNTIL SKIPCNT >= SKIPGOAL.

           PERFORM ONE-ROW.
           IF EIBRESP = 0 THEN PERFORM SPLIT
              MOVE KEY-IN TO K1 MOVE SNAME TO N1
              MOVE SCITY TO C1 MOVE SPHONE TO P1 END-IF.
           PERFORM ONE-ROW.
           IF EIBRESP = 0 THEN PERFORM SPLIT
              MOVE KEY-IN TO K2 MOVE SNAME TO N2
              MOVE SCITY TO C2 MOVE SPHONE TO P2 END-IF.
           PERFORM ONE-ROW.
           IF EIBRESP = 0 THEN PERFORM SPLIT
              MOVE KEY-IN TO K3 MOVE SNAME TO N3
              MOVE SCITY TO C3 MOVE SPHONE TO P3 END-IF.
           PERFORM ONE-ROW.
           IF EIBRESP = 0 THEN PERFORM SPLIT
              MOVE KEY-IN TO K4 MOVE SNAME TO N4
              MOVE SCITY TO C4 MOVE SPHONE TO P4 END-IF.
           PERFORM ONE-ROW.
           IF EIBRESP = 0 THEN PERFORM SPLIT
              MOVE KEY-IN TO K5 MOVE SNAME TO N5
              MOVE SCITY TO C5 MOVE SPHONE TO P5 END-IF.
           PERFORM ONE-ROW.
           IF EIBRESP = 0 THEN PERFORM SPLIT
              MOVE KEY-IN TO K6 MOVE SNAME TO N6
              MOVE SCITY TO C6 MOVE SPHONE TO P6 END-IF.
           PERFORM ONE-ROW.
           IF EIBRESP = 0 THEN PERFORM SPLIT
              MOVE KEY-IN TO K7 MOVE SNAME TO N7
              MOVE SCITY TO C7 MOVE SPHONE TO P7 END-IF.
           PERFORM ONE-ROW.
           IF EIBRESP = 0 THEN PERFORM SPLIT
              MOVE KEY-IN TO K8 MOVE SNAME TO N8
              MOVE SCITY TO C8 MOVE SPHONE TO P8 END-IF.
           PERFORM ONE-ROW.
           IF EIBRESP = 0 THEN PERFORM SPLIT
              MOVE KEY-IN TO K9 MOVE SNAME TO N9
              MOVE SCITY TO C9 MOVE SPHONE TO P9 END-IF.
           PERFORM ONE-ROW.
           IF EIBRESP = 0 THEN PERFORM SPLIT
              MOVE KEY-IN TO K10 MOVE SNAME TO N10
              MOVE SCITY TO C10 MOVE SPHONE TO P10 END-IF.
           PERFORM ONE-ROW.
           IF EIBRESP = 0 THEN PERFORM SPLIT
              MOVE KEY-IN TO K11 MOVE SNAME TO N11
              MOVE SCITY TO C11 MOVE SPHONE TO P11 END-IF.
           PERFORM ONE-ROW.
           IF EIBRESP = 0 THEN PERFORM SPLIT
              MOVE KEY-IN TO K12 MOVE SNAME TO N12
              MOVE SCITY TO C12 MOVE SPHONE TO P12 END-IF.
           PERFORM ONE-ROW.
           IF EIBRESP = 0 THEN PERFORM SPLIT
              MOVE KEY-IN TO K13 MOVE SNAME TO N13
              MOVE SCITY TO C13 MOVE SPHONE TO P13 END-IF.
           PERFORM ONE-ROW.
           IF EIBRESP = 0 THEN PERFORM SPLIT
              MOVE KEY-IN TO K14 MOVE SNAME TO N14
              MOVE SCITY TO C14 MOVE SPHONE TO P14 END-IF.
           PERFORM ONE-ROW.
           IF EIBRESP = 0 THEN PERFORM SPLIT
              MOVE KEY-IN TO K15 MOVE SNAME TO N15
              MOVE SCITY TO C15 MOVE SPHONE TO P15 END-IF.

           EXEC CICS ENDBR FILE('customers') END-EXEC.

           EXEC CICS SEND MAP('CUSTL') FROM(SCR) ERASE END-EXEC.
           EXEC CICS RECEIVE MAP('CUSTL') END-EXEC.

      *> AID dispatch. PF3 / PF12 / unmapped keys exit; PF7 pages back
      *> (clamping at page 1); PF8 advances. The hex literals match the
      *> 3270 AID byte values (PF3=0xF3, PF7=0xF7, PF8=0xF8, PF12=0x7C).
      *> AID dispatch matches cusl.rexx: PF3 / PF12 exit; PF7/PF8 page;
      *> any other key (including ENTER) is a no-op so the operator
      *> stays in the list view. PF8 always advances even on an empty
      *> next page -- PF7 takes the operator back if they overshoot.
           EVALUATE EIBAID
               WHEN X'F3'
                   MOVE 'Y' TO EXIT-FLAG
               WHEN X'7C'
                   MOVE 'Y' TO EXIT-FLAG
               WHEN X'F7'
                   IF PAGE-NO > 1 THEN
                       COMPUTE PAGE-NO = PAGE-NO - 1
                   END-IF
               WHEN X'F8'
                   COMPUTE PAGE-NO = PAGE-NO + 1
               WHEN OTHER
                   CONTINUE
           END-EVALUATE.

       SKIP-ONE.
           MOVE SPACES TO REC.
           MOVE SPACES TO KEY-IN.
           EXEC CICS READNEXT FILE('customers') INTO(REC)
                              RIDFLD(KEY-IN) END-EXEC.
           IF EIBRESP = 0 THEN
               COMPUTE SKIPCNT = SKIPCNT + 1
           END-IF.
           IF EIBRESP NOT = 0 THEN
               MOVE SKIPGOAL TO SKIPCNT
           END-IF.

       ONE-ROW.
           MOVE SPACES TO REC.
           MOVE SPACES TO KEY-IN.
           EXEC CICS READNEXT FILE('customers') INTO(REC)
                              RIDFLD(KEY-IN) END-EXEC.
           IF EIBRESP = 0 THEN
               COMPUTE NCOUNT = NCOUNT + 1
           END-IF.

       SPLIT.
           MOVE SPACES TO SNAME.
           MOVE SPACES TO SADDR.
           MOVE SPACES TO SCITY.
           MOVE SPACES TO SPHONE.
           UNSTRING REC DELIMITED BY '|'
               INTO SNAME SADDR SCITY SPHONE
           END-UNSTRING.

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
