      *> DFHWBCC -- TLS / cipher / client-certificate WORKING-STORAGE
      *> template for EXEC CICS WEB EXTRACT CERTIFICATE. Used in
      *> mTLS deployments where the WAPI TLS listener requires
      *> every client to present a certificate signed by the CA
      *> bundle named in `web_inbound_client_ca`. After dispatch,
      *> the program reads fields off the verified peer cert via:
      *>
      *>     COPY DFHWBCC.
      *>     EXEC CICS WEB EXTRACT CERTIFICATE
      *>                    COMMONNAME(DFH-WB-CN)
      *>                    ORGANISATION(DFH-WB-ORG)
      *>                    COUNTRY(DFH-WB-CO)
      *>                    SERIALNUM(DFH-WB-SERIAL)
      *>                    ISSUER(DFH-WB-ISSUER)
      *>     END-EXEC.
      *>     EVALUATE EIBRESP
      *>         WHEN DFHRESP-NORMAL  ...   *> verified, use the fields
      *>         WHEN DFHRESP-NOTFND  ...   *> non-TLS or no client cert
      *>     END-EVALUATE.
      *>
      *> Field widths match the X.509 subject / issuer common-name
      *> limits most CAs follow; programs that need wider buffers
      *> declare their own PIC X(n).
       01 DFH-WB-CN        PIC X(64).
       01 DFH-WB-ORG       PIC X(64).
       01 DFH-WB-CO        PIC X(2).
       01 DFH-WB-SERIAL    PIC X(40).
       01 DFH-WB-ISSUER    PIC X(64).
       01 DFH-WB-ISSUERORG PIC X(64).
