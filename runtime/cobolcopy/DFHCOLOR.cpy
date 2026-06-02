      *> DFHCOLOR  3270 extended-attribute color mnemonics.
      *>
      *> COPY DFHCOLOR into WORKING-STORAGE, then MOVE a colour into
      *> the per-field <NAME>-C override variable before SEND MAP:
      *>
      *>     MOVE DFHGREEN TO STATUS-C   *> classic CICS alias
      *>     MOVE GREEN    TO STATUS-C   *> bricks mnemonic
      *>
      *> Every colour is declared twice: once under the IBM-traditional
      *> DFH-prefixed canonical name and once under the bricks-style
      *> short alias. Both names resolve to the same 9-char string the
      *> renderer matches against colorOf() in tn3270/render.go.
      *>
      *> NOTE: there is no DFHWHITE in canonical CICS -- the canonical
      *> name for "white" is DFHNEUTR. The bricks alias NEUTRAL is a
      *> bricks ergonomic add-on; on z/OS you will see DFHNEUTR.
       01 DFHDFT     PIC X(9) VALUE 'DEFAULT  '.
       01 DEFAULT    PIC X(9) VALUE 'DEFAULT  '.
       01 DFHBLUE    PIC X(9) VALUE 'BLUE     '.
       01 BLUE       PIC X(9) VALUE 'BLUE     '.
       01 DFHRED     PIC X(9) VALUE 'RED      '.
       01 RED        PIC X(9) VALUE 'RED      '.
       01 DFHPINK    PIC X(9) VALUE 'PINK     '.
       01 PINK       PIC X(9) VALUE 'PINK     '.
       01 DFHGREEN   PIC X(9) VALUE 'GREEN    '.
       01 GREEN      PIC X(9) VALUE 'GREEN    '.
       01 DFHTURQ    PIC X(9) VALUE 'TURQUOISE'.
       01 TURQUOISE  PIC X(9) VALUE 'TURQUOISE'.
       01 DFHYELLO   PIC X(9) VALUE 'YELLOW   '.
       01 YELLOW     PIC X(9) VALUE 'YELLOW   '.
       01 DFHNEUTR   PIC X(9) VALUE 'NEUTRAL  '.
       01 NEUTRAL    PIC X(9) VALUE 'NEUTRAL  '.
