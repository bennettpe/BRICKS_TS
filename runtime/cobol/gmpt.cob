      *> GMPT -- COBOL pointer / storage demo. Exercises the bricks
      *> pointer surface end to end:
      *>
      *>   1. EXEC CICS GETMAIN SET(WS-PTR) FLENGTH(...) grabs a task-heap
      *>      buffer and writes its handle into the USAGE POINTER item.
      *>   2. SET ADDRESS OF a based LINKAGE 01 (GM-AREA) TO that handle
      *>      maps the record onto the GETMAIN bytes; a MOVE then writes
      *>      through the based item and a read pulls the same bytes back.
      *>   3. EXEC CICS FREEMAIN DATAPOINTER(WS-PTR) releases the buffer
      *>      while WS-PTR still holds the GETMAIN handle.
      *>   4. EXEC CICS ADDRESS COMMAREA(WS-CPTR) / EIB(WS-EPTR) hand back
      *>      handles addressing DFHCOMMAREA and the DFHEIB block. We test
      *>      the COMMAREA length against 0 so the operator can see
      *>      whether a commarea was flowed in.
      *>
      *> The result is painted with SEND TEXT (one flat <=79-column row,
      *> pure ASCII) so the sample needs no map file. There is NO pointer
      *> arithmetic anywhere -- bricks pointers are opaque handles.
       IDENTIFICATION DIVISION.
       PROGRAM-ID. GMPT.

       DATA DIVISION.
       WORKING-STORAGE SECTION.
       COPY DFHRESP.

      *> Three pointers: WS-PTR carries the GETMAIN handle; WS-CPTR the
      *> DFHCOMMAREA handle; WS-EPTR the DFHEIB handle.
       01 WS-PTR    USAGE POINTER.
       01 WS-CPTR   USAGE POINTER.
       01 WS-EPTR   USAGE POINTER.

      *> SCR is the SEND TEXT carrier: a single 79-byte line.
       01 SCR       PIC X(79).

      *> Scratch fields used to build the result line.
       01 WS-RESP     PIC S9(8) COMP.
       01 WS-READBACK PIC X(16).
       01 WS-CALEN    PIC 9(5).
       01 WS-CAMSG    PIC X(13).

       LINKAGE SECTION.
      *> GM-AREA is a based record. It owns no storage of its own until
      *> SET ADDRESS OF points it at the GETMAIN buffer.
       01 GM-AREA BASED.
          05 GM-TEXT  PIC X(16).

       PROCEDURE DIVISION.
       MAIN.
           MOVE SPACES TO SCR.
           MOVE SPACES TO WS-READBACK.
           MOVE SPACES TO WS-CAMSG.

      *> 1. GETMAIN a 16-byte buffer, space-initialised. The handle
      *>    lands in WS-PTR. FLENGTH <= 0 would raise LENGERR.
           EXEC CICS GETMAIN SET(WS-PTR) FLENGTH(16)
                             INITIMG(' ') RESP(WS-RESP) END-EXEC.

      *> 2. Map the based record onto the GETMAIN bytes, then write and
      *>    read through it. The MOVE writes into the GETMAIN buffer;
      *>    the read pulls the same bytes back via the based item.
           SET ADDRESS OF GM-AREA TO WS-PTR.
           MOVE 'POINTER-OK' TO GM-TEXT.
           MOVE GM-TEXT TO WS-READBACK.

      *> 3. FREEMAIN the GETMAIN buffer while WS-PTR still holds the
      *>    handle. DATAPOINTER names the pointer variable; INVREQ if the
      *>    address was not obtained by GETMAIN.
           EXEC CICS FREEMAIN DATAPOINTER(WS-PTR) END-EXEC.

      *> 4a. ADDRESS COMMAREA -- WS-CPTR addresses DFHCOMMAREA. EIBCALEN
      *>     tells us whether a commarea was flowed in.
           EXEC CICS ADDRESS COMMAREA(WS-CPTR) END-EXEC.
           MOVE EIBCALEN TO WS-CALEN.
           IF WS-CALEN = 0 THEN
               MOVE 'NO-COMMAREA' TO WS-CAMSG
           ELSE
               MOVE 'HAVE-COMMAREA' TO WS-CAMSG
           END-IF.

      *> 4b. ADDRESS EIB -- WS-EPTR addresses the DFHEIB block. The
      *>     handle is always non-NULL (the EIB always exists).
           EXEC CICS ADDRESS EIB(WS-EPTR) END-EXEC.

      *> Build the <=79-column result line. DELIMITED BY SIZE rstrips
      *> each source (bricks convention), so the alphanumeric fields
      *> concatenate without their trailing PIC X padding.
           STRING 'GM='        DELIMITED BY SIZE
                  WS-READBACK   DELIMITED BY SIZE
                  ' CA='        DELIMITED BY SIZE
                  WS-CAMSG      DELIMITED BY SIZE
                  ' PTRS-OK'    DELIMITED BY SIZE
                  INTO SCR
           END-STRING.

           EXEC CICS SEND TEXT FROM(SCR) ERASE END-EXEC.
           EXEC CICS RETURN END-EXEC.
           STOP RUN.
