/* EXAM - echo what the user types in the terminal including arguments */
 ADDRESS CICS
 
 PARSE ARG A B C
 
 EXEC CICS ASSIGN TERMID(TRM) END-EXEC
 
 MSG = 'EXAM ON ' TRM ' -- A=' || A '  B=' || B '  C=' || C
 
  EXEC CICS SEND TEXT FROM(MSG) ERASE END-EXEC
  EXEC CICS RETURN END-EXEC
 EXIT
