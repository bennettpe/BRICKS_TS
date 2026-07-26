      *> STAR -- SPACE INVADERS, a full-screen 3270 arcade game for the
      *> Copyright 2026 by moshix. All rights reserved
      *> bricks BBS. COBOL twin of the Go implementation tsu/spaceinvaders.
      *> Mod 2 (24x80) is the single supported layout. Map: STAR1.
      *> ====================================================================
      *> TIMING ARCHITECTURE -- single real-time loop (~10 fps)
      *> --------------------------------------------------------------------
      *>
      *> GAME-LOOP each frame:
      *>   1. Build the board / status / hi-score panel.
      *>   2. SEND MAP('STAR1') FROM(SCR) [ERASE first frame] TIMEOUT(100)
      *>      -- paints, then waits <=100 ms for an AID.
      *>   3. If EIBAID is a real key, apply the player input; if it is
      *>      LOW-VALUE (timeout) there was no key this frame.
      *>   4. STEP-GAME advances the WHOLE simulation one frame either way.
      *> No   bakcground task, no self-START, no TS-queue state sharing:
      *> it's one long-running task, so all state stays live in WORKING-STORAGE
      *> The first frame ERASE-paints; later frames repaint the full-width
      *> ROW fields WITHOUT erase, so the scren never blanks -> no flicker.
      *>
       IDENTIFICATION DIVISION.
       PROGRAM-ID. STAR.

       DATA DIVISION.
       WORKING-STORAGE SECTION.
       COPY DFHAID.

       COPY DFHRESP.
       *> DFHRESP has the EIB response codes
       
       COPY DFHCOLOR.

       01 WS-TRM        PIC X(4).
       01 WS-DONE       PIC X(1)  VALUE 'N'.
       01 WS-FIRST      PIC X(1)  VALUE 'Y'.
       01 WS-YES        PIC X(1)  VALUE 'Y'.
       01 WS-DUMMY      PIC X(1).
       01 WS-RBUF       PIC X(8).
       01 WS-RLEN       PIC 9(4).
         01 WS-STQ        PIC X(16).
       01 WS-ACTQ       PIC X(16).

      *>  We basically format a map with empty rows whcih then the game populates
       01 SCR.
          05 ROW02      PIC X(60).
          05 ROW02-C    PIC X(9).
          05 ROW03      PIC X(60).
          05 ROW03-C    PIC X(9).
          05 ROW04      PIC X(60).
          05 ROW04-C    PIC X(9).
          05 ROW05      PIC X(60).
          05 ROW05-C    PIC X(9).
          05 ROW06      PIC X(60).
          05 ROW06-C    PIC X(9).
          05 ROW07      PIC X(60).
          05 ROW07-C    PIC X(9).
          05 ROW08      PIC X(60).
          05 ROW08-C    PIC X(9).
          05 ROW09      PIC X(60).
          05 ROW09-C    PIC X(9).
          05 ROW10      PIC X(60).
          05 ROW10-C    PIC X(9).
          05 ROW11      PIC X(60).
          05 ROW11-C    PIC X(9).
          05 ROW12      PIC X(60).
          05 ROW12-C    PIC X(9).
          05 ROW13      PIC X(60).
          05 ROW13-C    PIC X(9).
          05 ROW14      PIC X(60).
          05 ROW14-C    PIC X(9).
          05 ROW15      PIC X(60).
          05 ROW15-C    PIC X(9).
          05 ROW16      PIC X(60).
          05 ROW16-C    PIC X(9).
          05 ROW17      PIC X(60).
          05 ROW17-C    PIC X(9).
          05 ROW18      PIC X(60).
          05 ROW18-C    PIC X(9).
          05 ROW19      PIC X(60).
          05 ROW19-C    PIC X(9).
          05 ROW20      PIC X(60).
          05 ROW20-C    PIC X(9).
          05 STATUS     PIC X(60).
          05 PLNAME     PIC X(20).
          05 HS1        PIC X(15).
          05 HS2        PIC X(15).
          05 HS3        PIC X(15).
          05 CMD        PIC X(1).

      *>  The board is 60 cells for all the objects 
       01 WS-BOARD.
          05 WS-CELL    OCCURS 60 TIMES PIC X(1).
       01 WS-RC         PIC X(9).

      *> this is the game state kept in WORKING STORAGE
      *> This is  not a pseudo-conversational program, so it always just loops
      *> until soemthing happens (like an AID key or something)
       01 GAMESTATE.
          05 WS-USR       PIC X(8)  VALUE SPACES.
          05 WS-SCORE     PIC 9(6)  VALUE 0.
          05 WS-LIVES     PIC 9(2)  VALUE 3.
          05 WS-WAVE      PIC 9(2)  VALUE 1.
          05 WS-CANNON    PIC 9(2)  VALUE 29.
          05 WS-DIR       PIC S9(1) VALUE 1.
          05 WS-DROP      PIC 9(2)  VALUE 0.
          05 WS-BOUNCE    PIC 9(2)  VALUE 0.
          05 WS-HOFF      PIC S9(2) VALUE 0.
          05 WS-ANIM      PIC 9(1)  VALUE 0.
          05 WS-TICK      PIC 9(9)  VALUE 0.
          05 WS-MARCHCTR  PIC 9(2)  VALUE 0.
          05 WS-COUNTDOWN PIC 9(2)  VALUE 5.
          05 WS-CDCTR     PIC 9(2)  VALUE 0.
          05 WS-SHIPFLASH PIC 9(2)  VALUE 0.
          05 WS-ALIVECT   PIC 9(2)  VALUE 55.
          05 WS-PAUSED    PIC X(1)  VALUE 'N'.
          05 WS-GAMEOVER  PIC X(1)  VALUE 'N'.
          05 WS-DEATHBOMB PIC X(1)  VALUE 'N'.
          05 WS-SAVED     PIC X(1)  VALUE 'N'.
          05 WS-SEED      PIC 9(9)  VALUE 12345.
          05 WS-BULACT    PIC X(1)  VALUE 'N'.
          05 WS-BROW      PIC 9(2)  VALUE 0.
          05 WS-BCOL      PIC 9(2)  VALUE 0.
      *>    Alien flet: 5 rows x 11 cols, index k = r*11 + c + 1.
          05 WS-FLEET.
             10 WS-ALIVE  OCCURS 55 TIMES PIC 9(1).
      *>    enemy Bombs: at most 2 on screen.
          05 WS-BOMBS.
             10 WS-BOMB   OCCURS 2 TIMES.
                15 WS-BOMB-ACT PIC 9(1).
                15 WS-BOMB-ROW PIC 9(2).
                15 WS-BOMB-COL PIC 9(2).
      *>    Walls (also called Bunkers): 4 x 2 rows x 5 cols = 40 cells, index
      *>    k = b*10 + rr*5 + cc + 1. HP 3/2/1/0 -> # / + / . / blank.
            05 WS-BUNKERS.
               10 WS-BUNK-HP OCCURS 40 TIMES PIC 9(1).

      *> Shooter-candidates list
       01 WS-CANDS.
          05 WS-CAND    OCCURS 11 TIMES.
             10 WS-CAND-C  PIC 9(2).
             10 WS-CAND-R  PIC 9(2).
       01 WS-NCAND      PIC 9(2)  VALUE 0.
       01 WS-LEADR      PIC S9(2) VALUE 0.

      *> We keep the High-score table (top 3) persisted in the STARHISC VSAM db
       01 WS-HSREC.
          05 WS-HS-ENT  OCCURS 3 TIMES.
             10 WS-HS-NAME   PIC X(8).
             10 WS-HS-SCORE  PIC 9(6).
      *> Fixed KSDS key for the single top-3 record. we create the VSAM cluster 
      *> woth the first EXEC CICS WRITE
      *> a READ before it exists returns NOTFND -> empty board.
         01 WS-HS-KEY     PIC X(4)  VALUE 'HISC'.
         01 WS-HS-DUMMY   PIC X(42).
        01 WS-HSQ        PIC X(8)  VALUE 'STARHISC'.

      *> general variables 
       01 WS-R          PIC S9(2).
       01 WS-AR         PIC S9(2).
       01 WS-AC         PIC S9(2).
       01 WS-K          PIC 9(4).
       01 WS-CI         PIC 9(2).
       01 WS-J          PIC 9(2).
       01 WS-VIS        PIC S9(4).
       01 WS-VP1        PIC S9(4).
       01 WS-VP2        PIC S9(4).
       01 WS-SR         PIC S9(4).
       01 WS-MINC       PIC S9(2).
       01 WS-MAXC       PIC S9(2).
       01 WS-MLEFT      PIC S9(4).
       01 WS-MRIGHT     PIC S9(4).
       01 WS-MARCHTH    PIC 9(3).
       01 WS-BIDX       PIC 9(2).
       01 WS-FB         PIC S9(2).
       01 WS-RR         PIC 9(1).
       01 WS-CC         PIC S9(2).
       01 WS-LEFTV      PIC S9(2).
       01 WS-ALEFT      PIC S9(4).
       01 WS-BHIT       PIC X(1).
      *> WS-GLYPH is a 3-cell tabl, NOT an elementary PIC X(3).  
      *> read it one character at a time (WS-GC(1..3)); source reference-
      *> modification (WS-GLYPH(2:1)) is dropped by the interpreter
      *> (>>> ||| \\\).  A plain OCCURS group + subscipt avoids both the
      *> broken ref-mod and REDEFINES.  `MOVE '<M>' TO WS-GLYPH` is a group
      *> move    (byte copy), so WS-GC(1)/'<' WS-GC(2)/'M' WS-GC(3)/'>'.
        01 WS-GLYPH.
          05 WS-GC      OCCURS 3 TIMES PIC X(1).
       01 WS-ACOL       PIC X(9).
       01 WS-ACTIVE     PIC 9(2).
       01 WS-MOD        PIC 9(9).
       01 WS-DIV        PIC 9(9).
       01 WS-RN         PIC 9(9).
       01 WS-RND        PIC 9(9).
       01 WS-ETIME      PIC 9(6).
       01 WS-RESP       PIC S9(8).
       01 WS-SPCOL      PIC S9(4).

      *> centered overlay strings into WS-BOARD.
       01 WS-PT-STR     PIC X(60).
       01 WS-PT-TBL.
          05 WS-PT-CH   OCCURS 60 TIMES PIC X(1).
       01 WS-PT-COL     PIC 9(2).
       01 WS-PT-LEN     PIC 9(2).
       01 WS-PTI        PIC 9(2).
       01 WS-PTD        PIC S9(4).

      *> High-score 
       01 WS-SW-NAME    PIC X(8).
       01 WS-SW-SCORE   PIC 9(6).
       01 WS-MINIDX     PIC 9(2).
       01 WS-MINSC      PIC 9(6).
       01 WS-FOUND      PIC X(1).

       PROCEDURE DIVISION.
      *> ANON when the operator never signed on (ASSIGN USERID blank).
        MAIN.
           EXEC CICS ASSIGN USERID(WS-USR) TERMID(WS-TRM) END-EXEC.
           IF WS-USR = SPACES
               MOVE 'ANON    ' TO WS-USR
           END-IF.
           PERFORM INIT-SEED.
           PERFORM NEW-GAME.
           PERFORM LOAD-HISCORES.
           MOVE 'Y' TO WS-FIRST.
           MOVE 'N' TO WS-DONE.
           PERFORM GAME-LOOP UNTIL WS-DONE = 'Y'.
           EXEC CICS RETURN END-EXEC.
           GOBACK.

      *> GAME LOOP 
      *> waits up to 100 ms for an AID: a real key returns its AID; no
      *> key returns EIBAID = LOW-VALUE (X'00').
       GAME-LOOP.
           PERFORM BUILD-BOARD.
           PERFORM BUILD-STATUS.
           PERFORM BUILD-HSPANEL.
           IF WS-FIRST = 'Y'
               EXEC CICS SEND MAP('STAR1') FROM(SCR) ERASE
                              TIMEOUT(100) END-EXEC
               MOVE 'N' TO WS-FIRST
           ELSE
               EXEC CICS SEND MAP('STAR1') FROM(SCR)
                              TIMEOUT(100) END-EXEC
           END-IF.
           IF EIBAID NOT = LOW-VALUE
               PERFORM HANDLE-INPUT
           END-IF.
           PERFORM STEP-GAME.
           PERFORM CHECK-SAVE.

      *> Persists the score onc, at a safe top level point, not inside a
      *> simulation loop !!!
       CHECK-SAVE.
           IF WS-GAMEOVER = 'Y' AND WS-SAVED = 'N'
               PERFORM SAVE-HISCORES
               MOVE 'Y' TO WS-SAVED
           END-IF.

      *> Seed the LCG from the wal clock EIBTIME = HHMMSS
       INIT-SEED.
           EXEC CICS ASKTIME END-EXEC.
           MOVE EIBTIME TO WS-ETIME.
           MOVE WS-ETIME TO WS-SEED.
           IF WS-SEED = 0
               MOVE 54321 TO WS-SEED
           END-IF.

      *> INPUT
       HANDLE-INPUT.
           EVALUATE EIBAID
               WHEN PF12
                   MOVE 'Y' TO WS-DONE
               WHEN PF10
                   IF WS-GAMEOVER = 'N'
                       IF WS-PAUSED = 'Y'
                           MOVE 'N' TO WS-PAUSED
                       ELSE
                           MOVE 'Y' TO WS-PAUSED
                       END-IF
                   END-IF
               WHEN ENTER
                   IF WS-GAMEOVER = 'Y'
                       PERFORM NEW-GAME
                    END-IF
               WHEN PF01
                     PERFORM MOVE-LEFT
               WHEN PF03
                   PERFORM MOVE-RIGHT
               WHEN PF02
                   PERFORM DO-FIRE
               WHEN OTHER
                       CONTINUE
           END-EVALUATE.
        *>  ws-cannon must be over 3 moshix!
        MOVE-LEFT.
           IF WS-COUNTDOWN = 0 AND WS-PAUSED = 'N' AND WS-GAMEOVER = 'N'
               IF WS-CANNON > 3
                   SUBTRACT 2 FROM WS-CANNON
               ELSE
                   MOVE 1 TO WS-CANNON
               END-IF
           END-IF.

       MOVE-RIGHT.
           IF WS-COUNTDOWN = 0 AND WS-PAUSED = 'N' AND WS-GAMEOVER = 'N'
               IF WS-CANNON < 56
                   ADD 2 TO WS-CANNON
               ELSE
                   MOVE 58 TO WS-CANNON
               END-IF
           END-IF.

      *> just arm the bulet 1 at a time.  STEP-BULLET called
      *> from STEP-GAME advance and resolves it each frame
      *> move 18 or 19 ?? find out moshix
      
       DO-FIRE.
           IF WS-COUNTDOWN = 0 AND WS-PAUSED = 'N' AND WS-GAMEOVER = 'N'
               IF WS-BULACT = 'N'
                   MOVE 'Y' TO WS-BULACT
                   COMPUTE WS-BCOL = WS-CANNON + 1
                   MOVE 18 TO WS-BROW
               END-IF
           END-IF.

      *> STEP-GAME, advance the simulatonby 1 tick!!
       STEP-GAME.
           IF WS-COUNTDOWN > 0
               ADD 1 TO WS-CDCTR
               IF WS-CDCTR >= 10
                   MOVE 0 TO WS-CDCTR
                   SUBTRACT 1 FROM WS-COUNTDOWN
               END-IF
           ELSE
               IF WS-GAMEOVER = 'N' AND WS-PAUSED = 'N'
                   ADD 1 TO WS-TICK
                   IF WS-SHIPFLASH > 0
                       SUBTRACT 1 FROM WS-SHIPFLASH
                   END-IF
                   PERFORM STEP-BULLET
                   IF WS-ALIVECT = 0
                       PERFORM NEXT-WAVE
                   ELSE
                       PERFORM MAYBE-MARCH
                       IF WS-GAMEOVER = 'N'
                           PERFORM STEP-BOMBS
                           PERFORM SPAWN-BOMB
                       END-IF
                   END-IF
               END-IF
           END-IF.

       NEXT-WAVE.
           ADD 1 TO WS-WAVE.
           COMPUTE WS-MOD = WS-WAVE - (WS-WAVE / 2) * 2.
           IF WS-MOD = 1
               ADD 1 TO WS-LIVES
           END-IF.
           PERFORM INIT-WAVE.
           PERFORM INIT-BUNKERS.
           MOVE 3 TO WS-COUNTDOWN.
           MOVE 0 TO WS-CDCTR.

      *> v        Player bullet
       STEP-BULLET.
           IF WS-BULACT = 'Y'
               PERFORM BULLET-STEP-1
           END-IF.
           IF WS-BULACT = 'Y'
               PERFORM BULLET-STEP-1
           END-IF.

       BULLET-STEP-1.
           PERFORM RESOLVE-BULLET.
           IF WS-BHIT = 'Y'
               MOVE 'N' TO WS-BULACT
           ELSE
               SUBTRACT 1 FROM WS-BROW
               IF WS-BROW < 2
                   MOVE 'N' TO WS-BULACT
               END-IF
           END-IF.

      *> Resolve the bullet at WS-BROW, WS-BCOL: bunker first, then alien
      *> ecuase bunkers are below aliens... duh
      
       RESOLVE-BULLET.
           MOVE 'N' TO WS-BHIT.
           PERFORM RB-BUNKER.
           IF WS-BHIT = 'N'
               PERFORM RB-ALIENS
           END-IF.

       RB-BUNKER.
           IF WS-BROW = 17 OR WS-BROW = 18
               MOVE WS-BROW TO WS-SR
               MOVE WS-BCOL TO WS-VIS
               PERFORM FIND-BUNKER-CELL-SR
               IF WS-BIDX > 0
                   IF WS-BUNK-HP(WS-BIDX) > 0
                       SUBTRACT 1 FROM WS-BUNK-HP(WS-BIDX)
                       MOVE 'Y' TO WS-BHIT
                   END-IF
               END-IF
           END-IF.

       RB-ALIENS.
           PERFORM RB-AROW VARYING WS-AR FROM 0 BY 1 UNTIL WS-AR > 4.

       RB-AROW.
           COMPUTE WS-SR = 2 + 2 * WS-AR + WS-DROP.
           IF WS-SR = WS-BROW
               PERFORM RB-ACOL VARYING WS-AC FROM 0 BY 1 UNTIL WS-AC > 10
           END-IF.

       RB-ACOL.
           COMPUTE WS-K = WS-AR * 11 + WS-AC + 1.
           IF WS-ALIVE(WS-K) = 1 AND WS-BHIT = 'N'
               COMPUTE WS-VIS = 9 + 4 * WS-AC + WS-HOFF
               COMPUTE WS-VP2 = WS-VIS + 2
               IF WS-BCOL >= WS-VIS AND WS-BCOL <= WS-VP2
                   MOVE 0 TO WS-ALIVE(WS-K)
                   SUBTRACT 1 FROM WS-ALIVECT
                   PERFORM ADD-POINTS
                   MOVE 'Y' TO WS-BHIT
               END-IF
           END-IF.

       ADD-POINTS.
           EVALUATE WS-AR
               WHEN 0 ADD 30 TO WS-SCORE
               WHEN 1 ADD 20 TO WS-SCORE
               WHEN 2 ADD 20 TO WS-SCORE
               WHEN 3 ADD 10 TO WS-SCORE
               WHEN 4 ADD 10 TO WS-SCORE
           END-EVALUATE.

      *> march the enemies...
       MAYBE-MARCH.
           COMPUTE WS-MARCHTH = 12 + WS-ALIVECT * 6 / 55.
           ADD 5 TO WS-MARCHCTR.
           IF WS-MARCHCTR >= WS-MARCHTH
               SUBTRACT WS-MARCHTH FROM WS-MARCHCTR
               PERFORM DO-MARCH
           END-IF.

       DO-MARCH.
           PERFORM CALC-MINMAX.
             COMPUTE WS-MLEFT  = 9 + 4 * WS-MINC + WS-HOFF.
           COMPUTE WS-MRIGHT = 9 + 4 * WS-MAXC + WS-HOFF + 2.
           IF WS-DIR > 0 AND WS-MRIGHT + 1 > 60
               COMPUTE WS-DIR = 0 - 1
               PERFORM BOUNCE-DROP
           ELSE
               IF WS-DIR < 0 AND WS-MLEFT - 1 < 1
                   MOVE 1 TO WS-DIR
                   PERFORM BOUNCE-DROP
               ELSE
                   ADD WS-DIR TO WS-HOFF
               END-IF
           END-IF.
             IF WS-ANIM = 0
                 MOVE 1 TO WS-ANIM
             ELSE
                 MOVE 0 TO WS-ANIM
             END-IF.
           PERFORM CRUSH-BUNKERS.
           PERFORM CHECK-INVASION.

      *> The flet reverse at each wall but only DROPS a row after two
       BOUNCE-DROP.
           ADD 1 TO WS-BOUNCE.
           IF WS-BOUNCE >= 4
               MOVE 0 TO WS-BOUNCE
               ADD 1 TO WS-DROP
           END-IF.

       CALC-MINMAX.
           MOVE 99 TO WS-MINC.
           COMPUTE WS-MAXC = 0 - 1.
           PERFORM CM-AR VARYING WS-AR FROM 0 BY 1 UNTIL WS-AR > 4.

       CM-AR.
           PERFORM CM-AC VARYING WS-AC FROM 0 BY 1 UNTIL WS-AC > 10.

       CM-AC.
           COMPUTE WS-K = WS-AR * 11 + WS-AC + 1.
           IF WS-ALIVE(WS-K) = 1
               IF WS-AC < WS-MINC
                   MOVE WS-AC TO WS-MINC
               END-IF
               IF WS-AC > WS-MAXC
                   MOVE WS-AC TO WS-MAXC
               END-IF
           END-IF.

       CRUSH-BUNKERS.
           PERFORM CR-AR VARYING WS-AR FROM 0 BY 1 UNTIL WS-AR > 4.

       CR-AR.
           COMPUTE WS-SR = 2 + 2 * WS-AR + WS-DROP.
           IF WS-SR = 17 OR WS-SR = 18
               PERFORM CR-AC VARYING WS-AC FROM 0 BY 1 UNTIL WS-AC > 10
           END-IF.

       CR-AC.
           COMPUTE WS-K = WS-AR * 11 + WS-AC + 1.
           IF WS-ALIVE(WS-K) = 1
               COMPUTE WS-ALEFT = 9 + 4 * WS-AC + WS-HOFF
               PERFORM CR-SPAN VARYING WS-SPCOL FROM 0 BY 1
                   UNTIL WS-SPCOL > 2
           END-IF.

       CR-SPAN.
           COMPUTE WS-VIS = WS-ALEFT + WS-SPCOL.
           PERFORM FIND-BUNKER-CELL-SR.
           IF WS-BIDX > 0
               MOVE 0 TO WS-BUNK-HP(WS-BIDX)
           END-IF.

       CHECK-INVASION.
           PERFORM CI-AR VARYING WS-AR FROM 0 BY 1 UNTIL WS-AR > 4.

       CI-AR.
           COMPUTE WS-SR = 2 + 2 * WS-AR + WS-DROP.
           IF WS-SR >= 17
               PERFORM CI-AC VARYING WS-AC FROM 0 BY 1 UNTIL WS-AC > 10
           END-IF.

       CI-AC.
           COMPUTE WS-K = WS-AR * 11 + WS-AC + 1.
           IF WS-ALIVE(WS-K) = 1
               MOVE 'N' TO WS-DEATHBOMB
               PERFORM REGISTER-GAMEOVER
           END-IF.

      *> BOMBS as the label says...
       STEP-BOMBS.
           PERFORM SB-ONE VARYING WS-J FROM 1 BY 1 UNTIL WS-J > 2.

       SB-ONE.
           IF WS-BOMB-ACT(WS-J) = 1
               MOVE WS-BOMB-ROW(WS-J) TO WS-SR
               MOVE WS-BOMB-COL(WS-J) TO WS-VIS
                   PERFORM RESOLVE-BOMB
               IF WS-BOMB-ACT(WS-J) = 1
                   ADD 1 TO WS-BOMB-ROW(WS-J)
                   IF WS-BOMB-ROW(WS-J) >= 21
                       MOVE 0 TO WS-BOMB-ACT(WS-J)
                   ELSE
                       MOVE WS-BOMB-ROW(WS-J) TO WS-SR
                       MOVE WS-BOMB-COL(WS-J) TO WS-VIS
                       PERFORM RESOLVE-BOMB
                   END-IF
               END-IF
           END-IF.

       RESOLVE-BOMB.
           IF WS-SR = 17 OR WS-SR = 18
               PERFORM FIND-BUNKER-CELL-SR
               IF WS-BIDX > 0
                   IF WS-BUNK-HP(WS-BIDX) > 0
                       SUBTRACT 1 FROM WS-BUNK-HP(WS-BIDX)
                       MOVE 0 TO WS-BOMB-ACT(WS-J)
                   END-IF
               END-IF
           ELSE
               IF WS-SR = 20
                   COMPUTE WS-VP2 = WS-CANNON + 2
                   IF WS-VIS >= WS-CANNON AND WS-VIS <= WS-VP2
                       PERFORM SHIP-HIT
                       MOVE 0 TO WS-BOMB-ACT(WS-J)
                   END-IF
               END-IF
           END-IF.

       SHIP-HIT.
           SUBTRACT 1 FROM WS-LIVES
           MOVE 8 TO WS-SHIPFLASH.
           IF WS-LIVES <= 0
               MOVE 0 TO WS-LIVES
               MOVE 'Y' TO WS-DEATHBOMB
               PERFORM REGISTER-GAMEOVER
           END-IF.

      *> launch a bomb from a random leader
       SPAWN-BOMB.
           PERFORM COUNT-ACTIVE.
           IF WS-ACTIVE < 2
               COMPUTE WS-MOD = WS-TICK - (WS-TICK / 9) * 9
               IF WS-MOD = 0
                   MOVE 3 TO WS-RN
                   PERFORM RAND-MOD
                   IF WS-RND = 0
                       PERFORM PICK-SHOOTER
                   END-IF
               END-IF
           END-IF.

       COUNT-ACTIVE.
           MOVE 0 TO WS-ACTIVE.
           PERFORM CA-ONE VARYING WS-J FROM 1 BY 1 UNTIL WS-J > 2.

       CA-ONE.
           IF WS-BOMB-ACT(WS-J) = 1
               ADD 1 TO WS-ACTIVE
           END-IF.

       PICK-SHOOTER.
           MOVE 0 TO WS-NCAND.
           PERFORM PS-COL VARYING WS-AC FROM 0 BY 1 UNTIL WS-AC > 10.
           IF WS-NCAND > 0
               MOVE WS-NCAND TO WS-RN
               PERFORM RAND-MOD
               ADD 1 TO WS-RND
               MOVE WS-RND TO WS-K
               MOVE WS-CAND-C(WS-K) TO WS-AC
               MOVE WS-CAND-R(WS-K) TO WS-AR
               COMPUTE WS-VIS = 9 + 4 * WS-AC + WS-HOFF + 1
               COMPUTE WS-SR  = 2 + 2 * WS-AR + WS-DROP + 1
               PERFORM PLACE-BOMB
           END-IF.

       PS-COL.
           COMPUTE WS-LEADR = 0 - 1.
           PERFORM PS-ROW VARYING WS-AR FROM 0 BY 1 UNTIL WS-AR > 4.
           IF WS-LEADR >= 0
               ADD 1 TO WS-NCAND
               MOVE WS-AC TO WS-CAND-C(WS-NCAND)
               MOVE WS-LEADR TO WS-CAND-R(WS-NCAND)
           END-IF.

       PS-ROW.
           COMPUTE WS-K = WS-AR * 11 + WS-AC + 1.
           IF WS-ALIVE(WS-K) = 1
               IF WS-AR > WS-LEADR
                   MOVE WS-AR TO WS-LEADR
               END-IF
           END-IF.

       PLACE-BOMB.
           IF WS-BOMB-ACT(1) = 0
               MOVE 1 TO WS-BOMB-ACT(1)
               MOVE WS-SR  TO WS-BOMB-ROW(1)
               MOVE WS-VIS TO WS-BOMB-COL(1)
           ELSE
               IF WS-BOMB-ACT(2) = 0
                   MOVE 1 TO WS-BOMB-ACT(2)
                   MOVE WS-SR  TO WS-BOMB-ROW(2)
                   MOVE WS-VIS TO WS-BOMB-COL(2)
               END-IF
           END-IF.

      *> BUNKER CELL LOOKUP. 
      *> Output: WS-BIDX (1..40) or 0 if no cell at that position.
      
       FIND-BUNKER-CELL-SR.
           MOVE 0 TO WS-BIDX.
           COMPUTE WS-RR = WS-SR - 17.
           PERFORM FB-B VARYING WS-FB FROM 0 BY 1 UNTIL WS-FB > 3.

       FB-B.
           COMPUTE WS-LEFTV = 8 + WS-FB * 13.
           COMPUTE WS-CC = WS-VIS - WS-LEFTV.
           IF WS-CC >= 0 AND WS-CC <= 4
               COMPUTE WS-BIDX = WS-FB * 10 + WS-RR * 5 + WS-CC + 1
           END-IF.

       BUILD-BOARD.
           PERFORM EMIT-ROW VARYING WS-R FROM 2 BY 1 UNTIL WS-R > 20.

       EMIT-ROW.
           PERFORM CLEAR-CELLS VARYING WS-CI FROM 1 BY 1 UNTIL WS-CI > 60.
           MOVE NEUTRAL TO WS-RC.
           PERFORM DRAW-ALIENS.
           PERFORM DRAW-BUNKERS.
           PERFORM DRAW-CANNON.
           PERFORM DRAW-BOMBS.
           PERFORM DRAW-BULLET.
           PERFORM APPLY-OVERLAY.
           PERFORM STORE-ROW.

       CLEAR-CELLS.
           MOVE ' ' TO WS-CELL(WS-CI).

       DRAW-ALIENS.
           PERFORM DA-AR VARYING WS-AR FROM 0 BY 1 UNTIL WS-AR > 4.

       DA-AR.
           COMPUTE WS-SR = 2 + 2 * WS-AR + WS-DROP.
           IF WS-SR = WS-R
               PERFORM SET-GLYPH
               MOVE WS-ACOL TO WS-RC
               PERFORM DA-AC VARYING WS-AC FROM 0 BY 1 UNTIL WS-AC > 10
           END-IF.

       DA-AC.
           COMPUTE WS-K = WS-AR * 11 + WS-AC + 1.
           IF WS-ALIVE(WS-K) = 1
               COMPUTE WS-VIS = 9 + 4 * WS-AC + WS-HOFF
               COMPUTE WS-VP1 = WS-VIS + 1
               COMPUTE WS-VP2 = WS-VIS + 2
               IF WS-VIS >= 1 AND WS-VP2 <= 60
                   MOVE WS-GC(1) TO WS-CELL(WS-VIS)
                   MOVE WS-GC(2) TO WS-CELL(WS-VP1)
                   MOVE WS-GC(3) TO WS-CELL(WS-VP2)
               END-IF
           END-IF.

       SET-GLYPH.
           EVALUATE WS-AR
               WHEN 0
                   MOVE RED TO WS-ACOL
                   IF WS-ANIM = 0
                       MOVE '<M>' TO WS-GLYPH
                   ELSE
                       MOVE '>M<' TO WS-GLYPH
                   END-IF
               WHEN 1
                   MOVE YELLOW TO WS-ACOL
                   IF WS-ANIM = 0
                       MOVE '(A)' TO WS-GLYPH
                   ELSE
                       MOVE '|A|' TO WS-GLYPH
                   END-IF
               WHEN 2
                   MOVE YELLOW TO WS-ACOL
                   IF WS-ANIM = 0
                       MOVE '(A)' TO WS-GLYPH
                   ELSE
                       MOVE '|A|' TO WS-GLYPH
                   END-IF
               WHEN 3
                   MOVE GREEN TO WS-ACOL
                   IF WS-ANIM = 0
                       MOVE '/X\' TO WS-GLYPH
                   ELSE
                       MOVE '\X/' TO WS-GLYPH
                   END-IF
               WHEN 4
                   MOVE GREEN TO WS-ACOL
                   IF WS-ANIM = 0
                       MOVE '/X\' TO WS-GLYPH
                   ELSE
                       MOVE '\X/' TO WS-GLYPH
                   END-IF
           END-EVALUATE.

       DRAW-BUNKERS.
           IF WS-R = 17 OR WS-R = 18
               COMPUTE WS-RR = WS-R - 17
               IF WS-RC = NEUTRAL
                   MOVE GREEN TO WS-RC
               END-IF
               PERFORM DBK-B VARYING WS-J FROM 0 BY 1 UNTIL WS-J > 3
           END-IF.

       DBK-B.
           PERFORM DBK-C VARYING WS-CC FROM 0 BY 1 UNTIL WS-CC > 4.

       DBK-C.
           COMPUTE WS-BIDX = WS-J * 10 + WS-RR * 5 + WS-CC + 1.
           COMPUTE WS-VIS = 8 + WS-J * 13 + WS-CC.
           IF WS-VIS >= 1 AND WS-VIS <= 60
               EVALUATE WS-BUNK-HP(WS-BIDX)
                   WHEN 3 MOVE '#' TO WS-CELL(WS-VIS)
                   WHEN 2 MOVE '+' TO WS-CELL(WS-VIS)
                   WHEN 1 MOVE '.' TO WS-CELL(WS-VIS)
                   WHEN OTHER MOVE ' ' TO WS-CELL(WS-VIS)
               END-EVALUATE
           END-IF.

       DRAW-CANNON.
           IF WS-GAMEOVER = 'N'
               IF WS-R = 20
                   IF WS-SHIPFLASH > 0
                       MOVE '*X*' TO WS-GLYPH
                       MOVE RED TO WS-RC
                   ELSE
                       MOVE '/#\' TO WS-GLYPH
                       MOVE TURQUOISE TO WS-RC
                   END-IF
                     COMPUTE WS-VIS = WS-CANNON
                     COMPUTE WS-VP1 = WS-CANNON + 1
                    COMPUTE WS-VP2 = WS-CANNON + 2
                   IF WS-VIS >= 1 AND WS-VP2 <= 60
                       MOVE WS-GC(1) TO WS-CELL(WS-VIS)
                       MOVE WS-GC(2) TO WS-CELL(WS-VP1)
                       MOVE WS-GC(3) TO WS-CELL(WS-VP2)
                   END-IF
               END-IF
               IF WS-R = 19
                   COMPUTE WS-VP1 = WS-CANNON + 1
                   IF WS-VP1 >= 1 AND WS-VP1 <= 60
                       MOVE '|' TO WS-CELL(WS-VP1)
                       IF WS-RC = NEUTRAL
                           MOVE TURQUOISE TO WS-RC
                       END-IF
                    END-IF
               END-IF
           END-IF.

       DRAW-BOMBS.
           PERFORM DBM-ONE VARYING WS-J FROM 1 BY 1 UNTIL WS-J > 2.

       DBM-ONE.
           IF WS-BOMB-ACT(WS-J) = 1
               IF WS-BOMB-ROW(WS-J) = WS-R
                   MOVE WS-BOMB-COL(WS-J) TO WS-VIS
                   IF WS-VIS >= 1 AND WS-VIS <= 60
                       MOVE '+' TO WS-CELL(WS-VIS)
                       IF WS-RC = NEUTRAL
                           MOVE RED TO WS-RC
                       END-IF
                   END-IF
               END-IF
           END-IF.

       DRAW-BULLET.
           IF WS-BULACT = 'Y'
               IF WS-BROW = WS-R
                   IF WS-BCOL >= 1 AND WS-BCOL <= 60
                       MOVE '|' TO WS-CELL(WS-BCOL)
                   END-IF
               END-IF
           END-IF.

      *> centred baners replace the row content
       APPLY-OVERLAY.
           IF WS-COUNTDOWN > 0
               IF WS-R = 11
                   PERFORM OV-COUNTDOWN
               END-IF
           ELSE
               IF WS-PAUSED = 'Y'
                   IF WS-R = 11
                       PERFORM OV-PAUSE
                   END-IF
               ELSE
                   IF WS-GAMEOVER = 'Y'
                       PERFORM OV-GAMEOVER
                   END-IF
               END-IF
           END-IF.

       OV-COUNTDOWN.
           PERFORM CLEAR-CELLS VARYING WS-CI FROM 1 BY 1 UNTIL WS-CI > 60.
           MOVE SPACES TO WS-PT-STR.
           STRING 'WAVE ' DELIMITED BY SIZE
                  WS-WAVE DELIMITED BY SIZE
                  ' - GET READY: ' DELIMITED BY SIZE
                  WS-COUNTDOWN DELIMITED BY SIZE
               INTO WS-PT-STR
           END-STRING.
           MOVE 23 TO WS-PT-LEN.
           MOVE 19 TO WS-PT-COL.
           MOVE YELLOW TO WS-RC.
           PERFORM PUT-TEXT.

       OV-PAUSE.
           PERFORM CLEAR-CELLS VARYING WS-CI FROM 1 BY 1 UNTIL WS-CI > 60.
           MOVE 'GAME PAUSED - PRESS F10 TO RESUME' TO WS-PT-STR.
           MOVE 33 TO WS-PT-LEN.
           MOVE 14 TO WS-PT-COL.
           MOVE NEUTRAL TO WS-RC.
           PERFORM PUT-TEXT.

       OV-GAMEOVER.
           IF WS-R = 10
               PERFORM CLEAR-CELLS VARYING WS-CI FROM 1 BY 1
                   UNTIL WS-CI > 60
               IF WS-DEATHBOMB = 'Y'
                   MOVE 'SHIP DESTROYED - GAME OVER' TO WS-PT-STR
                   MOVE 26 TO WS-PT-LEN
                   MOVE 18 TO WS-PT-COL
               ELSE
                   MOVE 'GAME OVER' TO WS-PT-STR
                   MOVE 9 TO WS-PT-LEN
                   MOVE 26 TO WS-PT-COL
               END-IF
               MOVE RED TO WS-RC
               PERFORM PUT-TEXT
           END-IF.
           IF WS-R = 11
               PERFORM CLEAR-CELLS VARYING WS-CI FROM 1 BY 1
                   UNTIL WS-CI > 60
               MOVE SPACES TO WS-PT-STR
               STRING 'FINAL SCORE: ' DELIMITED BY SIZE
                      WS-SCORE DELIMITED BY SIZE
                   INTO WS-PT-STR
               END-STRING
               MOVE 19 TO WS-PT-LEN
               MOVE 21 TO WS-PT-COL
               MOVE YELLOW TO WS-RC
               PERFORM PUT-TEXT
           END-IF.
           IF WS-R = 12
               PERFORM CLEAR-CELLS VARYING WS-CI FROM 1 BY 1
                   UNTIL WS-CI > 60
               MOVE 'PRESS ENTER TO PLAY AGAIN, F12 TO EXIT'
                   TO WS-PT-STR
               MOVE 38 TO WS-PT-LEN
               MOVE 12 TO WS-PT-COL
               MOVE NEUTRAL TO WS-RC
               PERFORM PUT-TEXT
           END-IF.

       PUT-TEXT.
           MOVE WS-PT-STR TO WS-PT-TBL.
           PERFORM PT-CHAR VARYING WS-PTI FROM 1 BY 1
               UNTIL WS-PTI > WS-PT-LEN.

       PT-CHAR.
           COMPUTE WS-PTD = WS-PT-COL + WS-PTI - 1.
           IF WS-PTD >= 1 AND WS-PTD <= 60
               MOVE WS-PT-CH(WS-PTI) TO WS-CELL(WS-PTD)
           END-IF.

      *> hip the finished row into its map field + colour
       STORE-ROW.
           EVALUATE WS-R
               WHEN 2  MOVE WS-BOARD TO ROW02  MOVE WS-RC TO ROW02-C
               WHEN 3  MOVE WS-BOARD TO ROW03  MOVE WS-RC TO ROW03-C
               WHEN 4  MOVE WS-BOARD TO ROW04  MOVE WS-RC TO ROW04-C
               WHEN 5  MOVE WS-BOARD TO ROW05  MOVE WS-RC TO ROW05-C
               WHEN 6  MOVE WS-BOARD TO ROW06  MOVE WS-RC TO ROW06-C
               WHEN 7  MOVE WS-BOARD TO ROW07  MOVE WS-RC TO ROW07-C
               WHEN 8  MOVE WS-BOARD TO ROW08  MOVE WS-RC TO ROW08-C
               WHEN 9  MOVE WS-BOARD TO ROW09  MOVE WS-RC TO ROW09-C
               WHEN 10 MOVE WS-BOARD TO ROW10  MOVE WS-RC TO ROW10-C
               WHEN 11 MOVE WS-BOARD TO ROW11  MOVE WS-RC TO ROW11-C
               WHEN 12 MOVE WS-BOARD TO ROW12  MOVE WS-RC TO ROW12-C
               WHEN 13 MOVE WS-BOARD TO ROW13  MOVE WS-RC TO ROW13-C
               WHEN 14 MOVE WS-BOARD TO ROW14  MOVE WS-RC TO ROW14-C
               WHEN 15 MOVE WS-BOARD TO ROW15  MOVE WS-RC TO ROW15-C
               WHEN 16 MOVE WS-BOARD TO ROW16  MOVE WS-RC TO ROW16-C
               WHEN 17 MOVE WS-BOARD TO ROW17  MOVE WS-RC TO ROW17-C
               WHEN 18 MOVE WS-BOARD TO ROW18  MOVE WS-RC TO ROW18-C
               WHEN 19 MOVE WS-BOARD TO ROW19  MOVE WS-RC TO ROW19-C
               WHEN 20 MOVE WS-BOARD TO ROW20  MOVE WS-RC TO ROW20-C
           END-EVALUATE.

      *> the Status line + high-score panel
       BUILD-STATUS.
           MOVE SPACES TO STATUS.
           STRING 'SCORE: ' DELIMITED BY SIZE
                  WS-SCORE   DELIMITED BY SIZE
                  '  LIVES: ' DELIMITED BY SIZE
                  WS-LIVES   DELIMITED BY SIZE
                  '  WAVE: ' DELIMITED BY SIZE
                  WS-WAVE    DELIMITED BY SIZE
               INTO STATUS
           END-STRING.
      *> Playr name under the title (row 1). WS-USR = BRICKS userid,
      *> or ANON when NOT signed on with CSSF
      
           MOVE SPACES TO PLNAME.
           STRING 'PLAYER: ' DELIMITED BY SIZE
                  WS-USR      DELIMITED BY SIZE
               INTO PLNAME
           END-STRING.

       BUILD-HSPANEL.
           PERFORM BHS-1.
           PERFORM BHS-2.
           PERFORM BHS-3.

       BHS-1.
           IF WS-HS-SCORE(1) > 0
               MOVE SPACES TO HS1
               STRING WS-HS-NAME(1) DELIMITED BY SIZE
                      ' ' DELIMITED BY SIZE
                      WS-HS-SCORE(1) DELIMITED BY SIZE
                   INTO HS1
               END-STRING
           ELSE
               MOVE SPACES TO HS1
           END-IF.

       BHS-2.
           IF WS-HS-SCORE(2) > 0
               MOVE SPACES TO HS2
               STRING WS-HS-NAME(2) DELIMITED BY SIZE
                      ' ' DELIMITED BY SIZE
                      WS-HS-SCORE(2) DELIMITED BY SIZE
                   INTO HS2
               END-STRING
           ELSE
               MOVE SPACES TO HS2
           END-IF.

       BHS-3.
           IF WS-HS-SCORE(3) > 0
               MOVE SPACES TO HS3
               STRING WS-HS-NAME(3) DELIMITED BY SIZE
                      ' ' DELIMITED BY SIZE
                      WS-HS-SCORE(3) DELIMITED BY SIZE
                   INTO HS3
               END-STRING
           ELSE
               MOVE SPACES TO HS3
           END-IF.

      *> set up the state moshix
       NEW-GAME.
           MOVE 0 TO WS-SCORE.
           MOVE 3 TO WS-LIVES.
           MOVE 1 TO WS-WAVE.
           MOVE 29 TO WS-CANNON.
           MOVE 0 TO WS-TICK.
           MOVE 0 TO WS-MARCHCTR.
           MOVE 0 TO WS-SHIPFLASH.
           MOVE 'N' TO WS-PAUSED.
           MOVE 'N' TO WS-GAMEOVER.
           MOVE 'N' TO WS-DEATHBOMB.
           MOVE 'N' TO WS-SAVED.
           MOVE 5 TO WS-COUNTDOWN.
           MOVE 0 TO WS-CDCTR.
           PERFORM INIT-WAVE.
           PERFORM INIT-BUNKERS.

       INIT-WAVE.
           MOVE 0 TO WS-DROP.
           MOVE 0 TO WS-BOUNCE.
           MOVE 0 TO WS-HOFF.
            MOVE 1 TO WS-DIR.
           MOVE 0 TO WS-ANIM.
            MOVE 0 TO WS-MARCHCTR.
           MOVE 55 TO WS-ALIVECT.
           MOVE 'N' TO WS-BULACT.
           PERFORM IW-CELL VARYING WS-K FROM 1 BY 1 UNTIL WS-K > 55.
           PERFORM CLEAR-BOMBS.

       IW-CELL.
           MOVE 1 TO WS-ALIVE(WS-K).

       INIT-BUNKERS.
           PERFORM IB-CELL VARYING WS-K FROM 1 BY 1 UNTIL WS-K > 40.

       IB-CELL.
           MOVE 3 TO WS-BUNK-HP(WS-K).

       CLEAR-BOMBS.
           MOVE 0 TO WS-BOMB-ACT(1).
           MOVE 0 TO WS-BOMB-ACT(2).

      *> set the flag when game over

       REGISTER-GAMEOVER.
           MOVE 'Y' TO WS-GAMEOVER.

      *> persist high scores in vsam 
      *> name = BBS userid.  
      *> if it does not exist
       LOAD-HISCORES.
           EXEC CICS READ FILE('STARHISC') INTO(WS-HSREC)
                          RIDFLD(WS-HS-KEY) RESP(WS-RESP) END-EXEC.
           IF WS-RESP NOT = RESP-NORMAL
               PERFORM CLEAR-HISCORES
           END-IF.

       CLEAR-HISCORES.
           MOVE SPACES TO WS-HS-NAME(1).
           MOVE 0 TO WS-HS-SCORE(1).
           MOVE SPACES TO WS-HS-NAME(2).
             MOVE 0 TO WS-HS-SCORE(2).
           MOVE SPACES TO WS-HS-NAME(3).
           MOVE 0 TO WS-HS-SCORE(3).

       SAVE-HISCORES.
           IF WS-SCORE > 0
               PERFORM LOAD-HISCORES
               MOVE 'N' TO WS-FOUND
                PERFORM HS-FIND VARYING WS-J FROM 1 BY 1 UNTIL WS-J > 3
               IF WS-FOUND = 'N'
                   PERFORM HS-FINDMIN
                   IF WS-SCORE > WS-MINSC
                        MOVE WS-USR TO WS-HS-NAME(WS-MINIDX)
                       MOVE WS-SCORE TO WS-HS-SCORE(WS-MINIDX)
                   END-IF
               END-IF
               PERFORM HS-SORT
      *> insert the single top-3 record.  REWRITE if it already exists
               EXEC CICS READ FILE('STARHISC') INTO(WS-HS-DUMMY)
                              RIDFLD(WS-HS-KEY) UPDATE
                              RESP(WS-RESP) END-EXEC
               IF WS-RESP = RESP-NORMAL
                   EXEC CICS REWRITE FILE('STARHISC') FROM(WS-HSREC)
                                  RIDFLD(WS-HS-KEY) RESP(WS-RESP) END-EXEC
               ELSE
                   EXEC CICS WRITE FILE('STARHISC') FROM(WS-HSREC)
                                  RIDFLD(WS-HS-KEY) RESP(WS-RESP) END-EXEC
               END-IF
           END-IF.

       HS-FIND.
           IF WS-HS-NAME(WS-J) = WS-USR
               IF WS-SCORE > WS-HS-SCORE(WS-J)
                   MOVE WS-SCORE TO WS-HS-SCORE(WS-J)
               END-IF
               MOVE 'Y' TO WS-FOUND
           END-IF.

       HS-FINDMIN.
           MOVE 1 TO WS-MINIDX.
           MOVE WS-HS-SCORE(1) TO WS-MINSC.
           IF WS-HS-SCORE(2) < WS-MINSC
               MOVE 2 TO WS-MINIDX
               MOVE WS-HS-SCORE(2) TO WS-MINSC
           END-IF.
           IF WS-HS-SCORE(3) < WS-MINSC
               MOVE 3 TO WS-MINIDX
               MOVE WS-HS-SCORE(3) TO WS-MINSC
           END-IF.

      *> descending sort and deduplicaton  already handled above moshix
       HS-SORT.
           PERFORM HS-SWAP12.
            PERFORM HS-SWAP23.
           PERFORM HS-SWAP12.

       HS-SWAP12.
           IF WS-HS-SCORE(2) > WS-HS-SCORE(1)
               MOVE WS-HS-NAME(1) TO WS-SW-NAME
               MOVE WS-HS-SCORE(1) TO WS-SW-SCORE
               MOVE WS-HS-NAME(2) TO WS-HS-NAME(1)
                MOVE WS-HS-SCORE(2) TO WS-HS-SCORE(1)
               MOVE WS-SW-NAME TO WS-HS-NAME(2)
               MOVE WS-SW-SCORE TO WS-HS-SCORE(2)
           END-IF.

       HS-SWAP23.
           IF WS-HS-SCORE(3) > WS-HS-SCORE(2)
               MOVE WS-HS-NAME(2) TO WS-SW-NAME
               MOVE WS-HS-SCORE(2) TO WS-SW-SCORE
               MOVE WS-HS-NAME(3) TO WS-HS-NAME(2)
               MOVE WS-HS-SCORE(3) TO WS-HS-SCORE(2)
               MOVE WS-SW-NAME TO WS-HS-NAME(3)
               MOVE WS-SW-SCORE TO WS-HS-SCORE(3)
           END-IF.

      *> basically a random function 
       RAND-MOD.
           COMPUTE WS-SEED = WS-SEED * 1103 + 12345.
           COMPUTE WS-DIV = WS-SEED / 32768.
           COMPUTE WS-SEED = WS-SEED - WS-DIV * 32768.
           COMPUTE WS-DIV = WS-SEED / WS-RN.
           COMPUTE WS-RND = WS-SEED - WS-DIV * WS-RN.
