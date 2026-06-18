# Multi-Region Operation (MRO)

Multi-Region Operation lets several BRICKS TS regions cooperate. A transaction
defined in one region can be **tagged** to run on a *different* region; BRICKS TS
forwards it over an authenticated TLS link and splices the result back so the
connected operator cannot tell it ran elsewhere. This lets you split
responsibilities across regions — one region owns the database connections,
another owns outbound web access, a third owns a particular application — while
any region can surface all of it from a single 3270 (or web3270) session.

The other big advantage is increased availability. You can put a load balancer
in front of several terminal owning regions, and this way, if one goes down, your
users can still access the other. 

Finally, there are very substantial scalability gains in running BRICKS in MRO mode, as
you can put each region on its own server thus increasing overall transaction thruput. 

- [Concept and trust model](#concept-and-trust-model)
- [Configuring a region (`bricks.cnf`)](#configuring-a-region-brickscnf)
- [The peer catalogue (`mro.conf`)](#the-peer-catalogue-mroconf)
- [Tagging a transaction (`transactions.conf`)](#tagging-a-transaction-transactionsconf)
- [How routing works](#how-routing-works)
- [Operating MRO — CEDA and CEMT](#operating-mro--ceda-and-cemt)
- [Security](#security)
- [v1 limitations](#v1-limitations)
- [Abend codes](#abend-codes)
- [Worked example — two regions on two hosts](#worked-example--two-regions-on-two-hosts)
- [Troubleshooting](#troubleshooting)

---

## Concept and trust model

Every region keeps its own `transactions.conf`, programs, and (optionally)
database connections. A transaction line can carry a trailing **`[region]`
tag**. When an operator invokes a tagged transaction, the region they are
connected to (the **origin**) does not run it locally — it opens a TLS
connection to the named **peer**, ships a small bootstrap context, and then:

- **3270 sessions** — splices the operator's terminal to the peer for the life
  of the task. The peer runs the program with its *own* full `EXEC CICS`
  engine; its 3270 output flows back to the real terminal and the operator's
  keystrokes flow to the peer. Interactive `SEND MAP` / `RECEIVE MAP` work
  unchanged.
- **web3270 sessions** — there is no persistent terminal socket, so the request
  is forwarded as a single request/response: the peer runs the transaction and
  returns the accumulated HTTP body/status/headers.

When the peer task ends, the origin applies the pseudo-conversational result
(`NextTransid`, `COMMAREA`, EIB shadow) to the local session and carries on.

**Trust.** TLS is used purely for **encryption** (each region presents an
in-memory self-signed certificate generated at startup). The **`mro_token`**
(8–24 alphanumeric) authenticates the *calling region* — it is compared in
constant time and never logged. The connected **user's** identity (userid + groups) is
asserted by the trusted peer; the peer does **not** re-authenticate the user,
but it **does** re-run its own per-transaction ACL against the supplied groups,
so authorization is enforced on both sides.

---

## Configuring a region (`bricks.cnf`)

Three knobs identify **this** region to its peers. They are only needed when
this region should be **contactable** (run a listener). A pure client region —
one that only routes *outward* — can leave all three empty and still list peers
in `mro.conf`.

| Key         | Notes |
|-------------|-------|
| `mro_name`  | This region's identifier, 1–8 alphanumeric. The name peers use to reach it. |
| `mro_port`  | TCP port (1025–65535) for the MRO TLS listener. |
| `mro_token` | Shared secret peers present to contact this region: **8 to 24 alphanumeric** characters. Clear text; never logged. |
| `mro_file`  | Path to the peer catalogue. Default `runtime/mro.conf`. |

Validation is **non-fatal and all-or-nothing**: if the `mro_*` block is absent
or wrongly configured (incomplete triple, bad port, mis-sized token), BRICKS TS 
logs one warning and runs as a **single region** — it never refuses to boot.
`CEMT MONITOR` shows the resulting posture (`Single Region`, or `MRO` with the
peer counts).

```
# bricks.cnf — region that owns the database and is contactable by peers
mro_name  = DBREG1
mro_port  = 1055
mro_token = Token1234567890abcdefABC
mro_file  = runtime/mro.conf
```

---

## The peer catalogue (`mro.conf`)

Lists the regions **this** region can route to. One peer per line:

```
name:host:port:token[:pin]
```

- `name`  — the peer's `mro_name` (1–8 alphanumeric); this is what a
  transaction tag references.
- `host`  — DNS name or IP of the peer.
- `port`  — the peer's `mro_port`.
- `token` — the peer's own `mro_token` (8 to 24 alphanumeric), presented when
  contacting it.
- `pin`   — *optional* hex SHA-256 fingerprint of the peer's certificate for
  MITM hardening (see [Security](#security)). Omit in the default
  self-signed + token model.

Parsing is lenient: blank lines and `#` comments are ignored, malformed or
duplicate rows are skipped with a logged warning (the token value is never
logged), and a missing file is fine (the region simply has no peers). Edit the
file with `vi` or, preferably, with **`CEDA MRO`** (below), which validates and
refreshes the live router immediately. After a `vi` edit, run **`CEMT PERFORM
RESCAN MRO`** (`CEMT P R O`) to re-read `mro.conf` without restarting.

> **Limit:** a region federates with **at most 16 peers**. Entries in
> `mro.conf` beyond the first 16 are ignored (with a logged warning), and
> `CEDA MRO` refuses to define a 17th — delete one first.

```
# runtime/mro.conf  (on the TERMREG region)
# name : host                : port : token
DBREG1 : dbreg1.example.com   : 1055 : Token1234567890abcdefABC
```

---

## Tagging a transaction (`transactions.conf`)

Append a bracketed region tag as the **last** field of a transaction line:

```
CSGM:rexx:csgm.rexx:PUBLIC,USERS,ADMIN:[DBREG1]
```

The tag (`[DBREG1]`) routes `CSGM` to the peer named `DBREG1`. The tag is
mutually exclusive with a local database binding (a routed transaction resolves
its database on the peer). For a tagged row the local `LANG`/`PROGRAM` fields
are **placeholders** — the peer resolves the actual program, language, and
database binding from *its own* `transactions.conf`. The local `GROUPS` field
is still enforced by the origin before routing.

> **Both regions define the transaction.** The origin's line carries the tag
> and the local ACL; the peer's line carries the real program and database
> binding. See the [worked example](#worked-example--two-regions-on-two-hosts).

---

## How routing works

1. The operator invokes a tagged transaction on the origin.
2. The origin checks its **local ACL** (`GROUPS`), counts the routing, and opens
   the link to the peer named by the tag.
3. **Mutual-link gate.** During the handshake the peer independently dials the
   origin back (from its own `mro.conf`) and authenticates. The origin forwards
   the transaction **only if that reverse link succeeds** — i.e. both regions
   can reach and authenticate each other. If it does not (the peer doesn't list
   the origin, or its entry is wrong, or the origin's listener is unreachable
   from it), the origin **refuses to forward**: the task ends with the short
   message `MRO region X: link not mutual - forwarding refused` (a clean
   config-error screen, not a program abend code) rather than running half a
   conversation the peer can't splice back. This is the same check that drives
   the ACK status.

   *Cost:* the reverse verification is a second short TLS handshake the peer
   makes back to the origin on **every** forward — including each
   pseudo-conversational `RETURN TRANSID` turnaround, which re-routes. On a
   healthy LAN link it is a few milliseconds; over a high-latency WAN budget for
   the extra round-trip per routed turn.
4. The peer authenticates the origin's token, resolves the transaction in its
   own table, re-checks **its** ACL against the supplied groups, and runs it.
5. 3270 I/O is spliced live (or, for web, the request is run and the response
   returned). `XCTL` chains continue on the peer; `LINK` runs on the peer;
   `EXEC SQL` uses the peer's database.
6. When the task issues `RETURN` / `RETURN TRANSID`, the peer ships the next
   transid + COMMAREA back. The **origin** re-routes that next transid against
   its *own* `transactions.conf` — so every pseudo-conversational turnaround is
   independently routed, and a `RETURN TRANSID` to a local menu lands locally.

Counters: the origin's transaction row counts **routings**; the peer's row
counts **executions**. Under healthy operation they match.

---

## Operating MRO — CEDA and CEMT

- **`CEDA MRO`** — define / view / alter / delete the **peer** regions in
  `mro.conf` (this region's own identity stays in `bricks.cnf` and is not edited
  here). A list screen (with `A`/`D` selectors and paging) and a form. The list
  also probes each peer on every paint, so it shows **STATUS** (responding?) and
  **RTT** (latency) alongside NAME / HOST / PORT. The token is shown only as
  asterisks in the list and is a hidden field in the form; leave it blank on
  ALTER to keep the existing secret. Admin-only. Edits refresh the live router
  immediately (no restart).
- **`CEMT INQUIRE MRO`** and **`CEDA MRO`** — a live health table: each render
  probes every peer (bounded, short timeouts, no task is dispatched on the peer)
  and colours each row by STATUS. A *positive* status requires a
  **mutually-verified** link. When this region probes a peer, the peer
  **independently dials this region back** (from its own `mro.conf`) and
  authenticates before answering; only if that reverse link succeeds does the
  peer report that it sees us:
  - **ACK** (green) — responding, and the peer independently established and
    authenticated a link back to us (genuinely bidirectional).
  - **REACHABLE** (pink) — responding, but the peer could **not** establish a
    link back (it doesn't list us, or its `mro.conf` entry for us has the wrong
    host/port/token, or our listener is unreachable from it). One-way.
  - **UNREACHABLE** (yellow) — probed but did not respond.
  - **Unknown** (turquoise) — not yet probed.

  Because the check is bidirectional, the two regions agree: if A shows B as
  ACK, B shows A as ACK. A one-way break makes **both** sides show the other as
  REACHABLE (not ACK) — there is no longer an asymmetric "A says ACK while B
  says UNREACHABLE".

  Columns: REGION, HOST, PORT, STATUS, LASTOK, RTT. The **CEDA MRO** list shows
  the same STATUS / RTT.
- **`CEMT MONITOR`** — a bottom-left **MRO quadrant** listing each peer with its
  live STATUS (ACK / REACHABLE / UNREACHABLE) and the number of transactions
  that peer has served for callers; the header shows this region's own name, and
  the Activity column tallies inter-region (MRO) routings alongside VSAM and WEB
  counts. Single-region deployments show `Single Region`.

---

## Security

- **Encryption**: each region generates an ephemeral self-signed ECDSA P-256
  certificate in memory at startup (never written to disk). Clients connect
  with `InsecureSkipVerify` — the certificate is *not* verified against a CA,
  consistent with the token-based trust model (and with the existing
  `web_client_tls_skip_verify` house behaviour).
- **Region authentication**: the `mro_token` (8–24 alphanumeric), constant-time
  compared, never logged or echoed in any error, screen, or audit line.
- **Caveat**: because the certificate is not authenticated, an active
  man-in-the-middle on the inter-region network could intercept the TLS session
  and capture/replay the token. Run MRO on a trusted network. To harden against
  this, pin the peer's certificate fingerprint as the optional 5th `mro.conf`
  field (`:pin`) — a hex SHA-256 of the peer's cert — and the client will
  refuse a mismatching certificate.
- **Authorization**: enforced on **both** sides — the origin's `GROUPS` gate
  before routing, and the peer's own ACL against the supplied groups.

---

## v1 limitations

- **Remote `EXEC CICS START` back to the origin terminal** is not yet
  delivered. A `START` issued by a routed task runs natively on the peer; one
  that targets the origin terminal is not relayed back.
- **Onward routing from a peer** (a peer transid that is *itself* tagged to a
  third region) is refused with abend `AZMH`. Multi-hop topologies are still
  reachable because the **origin** re-routes each pseudo-conversational
  turnaround against its own table; routing loops are detected and refused
  (`AZMR`).
- **Screen geometry / codepage**: the peer renders at **Mod 2 (24×80)** with
  the default codepage. This is the BRICKS  screen-design target; alternate
  screen sizes and non-default codepages are not forwarded across MRO in v1.
- **Upgrade ordering**: because forwarding is now gated on a mutually-verified
  link, a region must be upgraded to a build that performs the reverse
  verification before its peers will forward to it — a peer that always answers
  "cannot see you" is refused. Upgrade regions together (or peers-first) so no
  origin is left refusing a link that would otherwise work.

---

## Abend codes

A routed transaction that fails on the peer surfaces a clean abend on the
origin (rendered with the origin's banner). MRO-specific codes:

| Code   | Meaning |
|--------|---------|
| `AZMT` | Transaction is not defined on the peer region. |
| `AZMA` | Access denied by the peer's ACL. |
| `AZML` | The peer's program language is not supported. |
| `AZMH` | Onward routing from a peer is not supported (v1). |
| `AZMR` | Routing loop detected. |
| `AZMC` | XCTL chain too long on the peer. |
| `AZMP` | Peer internal error. |
| `AZMX` | Peer has no task runner wired. |

A region that is configured but cannot be reached produces a plain message
rather than an abend — e.g. `MRO region DBREG1 unreachable: connection
refused` — and the operator is returned to the prompt with no work performed.

---

## Worked example — two regions on two hosts

Two hosts: **`termreg`** owns the terminals (operators connect here);
**`dbreg1`** owns the Postgres connection. The transaction `CSGM` is defined on
both, tagged to `DBREG1` on the terminal region.

### Region DBREG1 — `dbreg1.example.com` (owns the database)

`bricks.cnf`:
```
port      = 2300
mro_name  = DBREG1
mro_port  = 1055
mro_token = Token1234567890abcdefABC

db_host     = 10.0.0.20
db_user     = bricks
db_password = secret
```

`runtime/transactions.conf` (CSGM runs locally here, bound to a database):
```
CSGM:rexx:csgm.rexx:PUBLIC,USERS,ADMIN:customers
```

`runtime/mro.conf`: empty (DBREG1 has no peers of its own).

### Region TERMREG — `termreg.example.com` (owns the terminals)

`bricks.cnf`:
```
port      = 2300
mro_name  = TERMREG
mro_port  = 1066
mro_token = Termreg00000000000000xyz
```

`runtime/mro.conf` (point at DBREG1, using DBREG1's token):
```
# name : host                : port : token
DBREG1 : dbreg1.example.com   : 1055 : Token1234567890abcdefABC
```

`runtime/transactions.conf` (CSGM is tagged — runs on DBREG1):
```
CSGM:rexx:csgm.rexx:PUBLIC,USERS,ADMIN:[DBREG1]
```

### Run it

1. Start DBREG1, then TERMREG. Each logs `MRO listening on … as region …`.
2. On TERMREG, run `CEMT INQUIRE MRO` — `DBREG1` should show **ACK** (green)
   with an RTT once DBREG1 also lists TERMREG in its `mro.conf`. If DBREG1 does
   not list TERMREG back, it shows **REACHABLE** (pink) — reachable but one-way.
3. Connect a tn3270 client to TERMREG and run `CSGM`. It executes on DBREG1
   (against DBREG1's database) and paints exactly as if it were local.
4. Stop DBREG1. Re-run `CSGM` on TERMREG — you get a clean
   `MRO region DBREG1 unreachable: …` message; `CEMT INQUIRE MRO` flips to
   **UNREACHABLE** (yellow); the `CEMT MONITOR` MRO quadrant flips DOR1 to
   `UNREACHABLE` too.

---

## Troubleshooting

| Symptom | Likely cause |
|---------|--------------|
| `CEMT MONITOR` shows `Single Region` though you set the knobs | Incomplete/invalid `mro_*` triple — check the startup log for the warning (bad port, mis-sized token, missing knob). |
| `CSGM` returns `MRO region DBREG1 not defined` | The tag references a region absent from `mro.conf` (or `CEDA MRO` deleted it). |
| `… unreachable: connection refused` | Peer not running, wrong host/port, or a firewall between the regions. |
| Abend `AZMT` | The peer's `transactions.conf` doesn't define the transid. Define it (with its real program + database) on the peer. |
| Abend `AZMA` | The peer's ACL rejects the operator's groups. Align the peer's `GROUPS`. |
| STATUS shows **UNREACHABLE** (yellow) | The peer was probed but did not answer — not running, wrong host/port, or a firewall. |
| STATUS shows **REACHABLE** (pink), never **ACK** | You can reach the peer, but it could not establish a link **back** to this region during the probe: the peer doesn't list this region in its own `mro.conf`, OR its entry for this region has the wrong host/port/token, OR this region's `mro_port` listener is unreachable from the peer (or this region has no `mro_name`). Fix the peer's `mro.conf` entry for this region (and give this region an identity + reachable `mro_port`) for a mutual **ACK**. |
| `link not mutual - forwarding refused` | The tagged transaction was refused (a clean message, not an abend code) because the peer could not authenticate a link back to this region (same cause as REACHABLE-never-ACK). Forwarding is gated on a mutually-verified link; fix the peer's `mro.conf` entry for this region so STATUS reaches **ACK**, then retry. |
| RTT shows `-` after a successful transaction | The region was reached by routing but not yet probed — open `CEMT INQUIRE MRO` to probe. |
