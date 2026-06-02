      *> DFHVALUE  EXEC CICS QUERY SECURITY axis values.
      *>
      *> COPY DFHVALUE into WORKING-STORAGE SECTION, then compare
      *> the four host variables QUERY SECURITY writes against the
      *> named codes instead of bare integers:
      *>
      *>     EXEC CICS QUERY SECURITY RESOURCE('GUST')
      *>                              RESCLASS('TCICSTRN')
      *>                              READ(WS-CACR-RD)
      *>                              UPDATE(WS-CACR-UP)
      *>                              END-EXEC.
      *>     IF WS-CACR-UP = DFHVALUE-UPDATABLE THEN ...
      *>     IF WS-CACR-RD = READABLE          THEN ...   *> bricks mnemonic
      *>
      *> Every code is declared twice -- once under the bricks-style
      *> short name (READABLE, NOTREADABLE, UPDATABLE, ...) and once
      *> under the IBM-traditional DFHVALUE-prefixed alias.  Both
      *> forms resolve to the same numeric value, so programs may
      *> pick either style or mix them.
      *>
      *> The four-axis matrix mirrors the IBM DFHVALUE codes 50..57:
      *>
      *>   READ     50 READABLE    / 51 NOTREADABLE
      *>   UPDATE   52 UPDATABLE   / 53 NOTUPDATABLE
      *>   CONTROL  54 CTRLABLE    / 55 NOTCTRLABLE
      *>   ALTER    56 ALTERABLE   / 57 NOTALTERABLE
      *>
      *> The bricks-flavoured access mapping (see PROGRAMMING.md
      *> chapter "Security inquiry") narrows the IBM matrix:
      *>   READ     = user shares any group with the resource, or is admin
      *>   UPDATE/CONTROL/ALTER = user is in the admin group
      *>
      *> ====================================================================
      *> IMPORTANT  --  bricks decimal-text deviation from IBM canonical
      *> ====================================================================
      *> On a z/OS CICS region these constants are usually declared as
      *> PIC S9(8) COMP (a 4-byte binary half-word), matching the
      *> COMP-format integer the host variables receive from QUERY
      *> SECURITY.  Bricks ships the constants as PIC S9(8) VALUE
      *> (DISPLAY, decimal-text) instead.
      *>
      *> Reason: the bricks COBOL -> cics bridge resolves every
      *> EXEC CICS host variable as DISPLAY text (the same convention
      *> the ESDS RBA host-var lesson documents, see PROGRAMMING.md
      *> Chapter 8a).  A target variable declared
      *>     PIC S9(8)               -- DISPLAY, "00000050"
      *> receives the seven ASCII bytes "0000050" from the bridge; a
      *> later
      *>     IF WS-CACR-UP = DFHVALUE-UPDATABLE
      *> comparison must therefore have DFHVALUE-UPDATABLE in the
      *> SAME representation, hence VALUE 52 (DISPLAY), not COMP 52.
      *>
      *> Operators who reflexively declare the target host variable
      *> AND the constant as PIC S9(8) COMP -- IBM-canonical for
      *> 30 years -- will hit the decimal-text-vs-binary mismatch
      *> documented in the ESDS lesson:  the IF-equals always falls
      *> false.  Use PIC S9(8) on the target (DISPLAY) to match.
      *> See PROGRAMMING.md Chapter 6 ("Security inquiry") for the
      *> chapter-level note pointing back at this copybook.
       01 READABLE              PIC S9(8) VALUE 50.
       01 DFHVALUE-READABLE     PIC S9(8) VALUE 50.
       01 NOTREADABLE           PIC S9(8) VALUE 51.
       01 DFHVALUE-NOTREADABLE  PIC S9(8) VALUE 51.
       01 UPDATABLE             PIC S9(8) VALUE 52.
       01 DFHVALUE-UPDATABLE    PIC S9(8) VALUE 52.
       01 NOTUPDATABLE          PIC S9(8) VALUE 53.
       01 DFHVALUE-NOTUPDATABLE PIC S9(8) VALUE 53.
       01 CTRLABLE              PIC S9(8) VALUE 54.
       01 DFHVALUE-CTRLABLE     PIC S9(8) VALUE 54.
       01 NOTCTRLABLE           PIC S9(8) VALUE 55.
       01 DFHVALUE-NOTCTRLABLE  PIC S9(8) VALUE 55.
       01 ALTERABLE             PIC S9(8) VALUE 56.
       01 DFHVALUE-ALTERABLE    PIC S9(8) VALUE 56.
       01 NOTALTERABLE          PIC S9(8) VALUE 57.
       01 DFHVALUE-NOTALTERABLE PIC S9(8) VALUE 57.
