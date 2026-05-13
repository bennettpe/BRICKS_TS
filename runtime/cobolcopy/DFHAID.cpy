      *> DFHAID  3270 attention-identifier (AID) byte mnemonics.
      *>
      *> COPY DFHAID into WORKING-STORAGE SECTION, then compare
      *> EIBAID against named bytes instead of raw hex literals:
      *>
      *>     IF EIBAID = PF03    THEN ...      *> bricks mnemonic
      *>     IF EIBAID = DFHPF3  THEN ...      *> classic CICS alias
      *>     IF EIBAID = ENTER   THEN ...
      *>     IF EIBAID = DFHENTER THEN ...
      *>
      *> Every key is declared twice, once under the bricks-style
      *> short name (PF01..PF24, ENTER, CLEAR, PA1..PA3) and once
      *> under the IBM-traditional DFH-prefixed alias.  Both names
      *> resolve to the same single byte.  Pick whichever style
      *> you prefer -- you can even mix them inside one program.
      *>
      *> Hex bytes are the standard 3270 AID codes:
      *>   ENTER X'7D'   CLEAR X'6D'
      *>   PA1   X'6C'   PA2   X'6E'   PA3   X'6B'
      *>   PF1..PF9   X'F1'..X'F9'
      *>   PF10..PF12 X'7A' X'7B' X'7C'
      *>   PF13..PF21 X'C1'..X'C9'
      *>   PF22..PF24 X'4A' X'4B' X'4C'
       01 ENTER     PIC X VALUE X'7D'.
       01 DFHENTER  PIC X VALUE X'7D'.
       01 CLEAR     PIC X VALUE X'6D'.
       01 DFHCLEAR  PIC X VALUE X'6D'.
       01 PA1       PIC X VALUE X'6C'.
       01 DFHPA1    PIC X VALUE X'6C'.
       01 PA2       PIC X VALUE X'6E'.
       01 DFHPA2    PIC X VALUE X'6E'.
       01 PA3       PIC X VALUE X'6B'.
       01 DFHPA3    PIC X VALUE X'6B'.
       01 PF01      PIC X VALUE X'F1'.
       01 DFHPF1    PIC X VALUE X'F1'.
       01 PF02      PIC X VALUE X'F2'.
       01 DFHPF2    PIC X VALUE X'F2'.
       01 PF03      PIC X VALUE X'F3'.
       01 DFHPF3    PIC X VALUE X'F3'.
       01 PF04      PIC X VALUE X'F4'.
       01 DFHPF4    PIC X VALUE X'F4'.
       01 PF05      PIC X VALUE X'F5'.
       01 DFHPF5    PIC X VALUE X'F5'.
       01 PF06      PIC X VALUE X'F6'.
       01 DFHPF6    PIC X VALUE X'F6'.
       01 PF07      PIC X VALUE X'F7'.
       01 DFHPF7    PIC X VALUE X'F7'.
       01 PF08      PIC X VALUE X'F8'.
       01 DFHPF8    PIC X VALUE X'F8'.
       01 PF09      PIC X VALUE X'F9'.
       01 DFHPF9    PIC X VALUE X'F9'.
       01 PF10      PIC X VALUE X'7A'.
       01 DFHPF10   PIC X VALUE X'7A'.
       01 PF11      PIC X VALUE X'7B'.
       01 DFHPF11   PIC X VALUE X'7B'.
       01 PF12      PIC X VALUE X'7C'.
       01 DFHPF12   PIC X VALUE X'7C'.
       01 PF13      PIC X VALUE X'C1'.
       01 DFHPF13   PIC X VALUE X'C1'.
       01 PF14      PIC X VALUE X'C2'.
       01 DFHPF14   PIC X VALUE X'C2'.
       01 PF15      PIC X VALUE X'C3'.
       01 DFHPF15   PIC X VALUE X'C3'.
       01 PF16      PIC X VALUE X'C4'.
       01 DFHPF16   PIC X VALUE X'C4'.
       01 PF17      PIC X VALUE X'C5'.
       01 DFHPF17   PIC X VALUE X'C5'.
       01 PF18      PIC X VALUE X'C6'.
       01 DFHPF18   PIC X VALUE X'C6'.
       01 PF19      PIC X VALUE X'C7'.
       01 DFHPF19   PIC X VALUE X'C7'.
       01 PF20      PIC X VALUE X'C8'.
       01 DFHPF20   PIC X VALUE X'C8'.
       01 PF21      PIC X VALUE X'C9'.
       01 DFHPF21   PIC X VALUE X'C9'.
       01 PF22      PIC X VALUE X'4A'.
       01 DFHPF22   PIC X VALUE X'4A'.
       01 PF23      PIC X VALUE X'4B'.
       01 DFHPF23   PIC X VALUE X'4B'.
       01 PF24      PIC X VALUE X'4C'.
       01 DFHPF24   PIC X VALUE X'4C'.
