      *> DFHWBMETH -- HTTP method-name literals. Used on the
      *> client-side EXEC CICS WEB SEND METHOD(...) option (Phase 2);
      *> declared in Phase 1 because the value set is fixed and
      *> programs may name them in server-side code (e.g. when
      *> branching on the inbound method extracted via WEB EXTRACT).
       01 WB-GET       PIC X(7) VALUE 'GET'.
       01 WB-POST      PIC X(7) VALUE 'POST'.
       01 WB-PUT       PIC X(7) VALUE 'PUT'.
       01 WB-DELETE    PIC X(7) VALUE 'DELETE'.
       01 WB-PATCH     PIC X(7) VALUE 'PATCH'.
       01 WB-HEAD      PIC X(7) VALUE 'HEAD'.
       01 WB-OPTIONS   PIC X(7) VALUE 'OPTIONS'.
