/* TIME - A SMALL TIME UTILITY  FOR BRICKS - COPYRIGHT 2026 MOSHIX */
 ADDRESS CICS
time=""
EXEC CICS ASKTIME
        ABSTIME(time)
    END-EXEC
timeout=""
dateout=""
EXEC CICS FORMATTIME
        ABSTIME(time)
        TIME(timeout)
        TIMESEP(':')
        YYYYMMDD(dateout)
        DATESEP('-')
    END-EXEC                    
                                                                       
/*  EXEC CICS ASSIGN TERMID(TRM) END-EXEC */
                    
                                                                       
 MSG = 'It is: ' || timeout || '  ' || dateout
                                                                       
  EXEC CICS SEND TEXT FROM(MSG) ERASE END-EXEC
  EXEC CICS RETURN END-EXEC
 EXIT
