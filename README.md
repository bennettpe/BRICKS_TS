# Bricks Transaction Server
> *In professional cycling, the philosophy of marginal gains was immortalized by Team Sky.
> Instead of chasing revolutionary breakthroughs, they pursued relentless refinement:
> a slightly more efficient bike fit, marginally lighter components,
> deeper sleep, cleaner nutrition, better recovery routines.
>
> Any single adjustment was almost trivial in isolation.
> But compounded across hundreds of decisions,
> those tiny advantages accumulated into a decisive competitive edge—
> one powerful enough to redefine the sport and sustain dominance for years.

> Bricks follow the same approach*

Chat with BRICKS developers and master operators [here](https://discord.gg/6NWE4Gp7kR)

A Go implementation of an IBM CICS-compatible 3270 transaction server. Users
dial in with a 3270 terminal emulator, sign on via a built-in CSSN screen, and
run REXX or COBOL programs whose `EXEC CICS` commands are interpreted by
built-in REXX and COBOL VMs (virtual machines)  with `EXEC CICS` handlers 
backed by an on-disk record store.

Both REXX and COBOL dialects, and their interpreter implementations, are designed
by moshix and are not related to BREXX, Regina, or GNUCobol . The `EXEC CICS` surface is
compatible with CICS, and the supported verb set is able to run
complex pseudo-conversational and conversational programs as usual.

Bricks also features a built-in VSAM-style KSDS access method whose records
are stored inside a single bbolt database for easy management and backup.

As of v2 of BRICKS, SQL support thru EXEC SQL statements is available to the programmers. 
** The extensive SQL support is document [here](SQL_guide.md)**

COBOL and REXX programs are parsed once and then cached, so repeat dispatches
skip the lex+parse cost. Each instantiated program has its own heap and stack,
so there are no re-entrancy issues. Bricks expressly disallows calculated
GOTOs in COBOL programs for the same reason.


> **Application programmers:** see **[PROGRAMMING.md](PROGRAMMING.md)** —
> the *Bricks Application Programming Reference*. It documents the
> BMS-flavoured map DSL, every supported `EXEC CICS` command (format,
> options, conditions, examples), the REXX dialect, the COBOL dialect, and
> sample programs.
>
> This README covers **running and operating** bricks: configuration,
> authentication, control blocks, on-disk file storage, the operator
> console, CEMT, the `/metrics` endpoint, the embedder API, the CLI
> utilities, the test suite, the `bricksload` stress tester, and
> performance / security hardening.

---

## Quick start

```sh
# Add a user (admin / admin already exists in runtime/users.conf).
./add_brick_user.bash alice "alice's-password" admin,users

# Run the server. Edit bricks.cnf first (see "Configuration").
./bricks --conf=bricks.cnf

# Connect with any 3270 emulator (c3270, x3270, tn3270 …):
c3270 -port 2300 localhost
```

On connect you'll see the `bricks.logo` splash in blue. Press ENTER to reach
the TRANSID prompt; type `CSSN` to sign on, then any defined TRANSID
(e.g. `HELO`).

---

## Breaking out of a transaction — `PA1`

A transaction program drives the terminal with `EXEC CICS SEND MAP` /
`SEND TEXT` and waits for the operator to press a key. A well-behaved
program offers an exit — conventionally `PF3` — but a program that never
checks `EIBAID` for an exit key (or simply has a logic bug) can leave the
terminal stuck on its screen with no way back to the TRANSID prompt.

**Press `PA1` to break out.** bricks intercepts `PA1` at every screen
wait, *before* the program sees it: the running transaction is aborted
and the terminal is returned to the empty TRANSID prompt. `PA1` cannot be
consumed by the program — even one that arms `HANDLE AID PA1(...)` never
receives it — so it is a guaranteed escape from a stuck transaction.

Break-out is treated like an abend, not a clean `RETURN`: any recoverable
work the task did since its last `SYNCPOINT` (FILE / TS / TD writes,
uncommitted SQL) is rolled back, because the task did not finish, and no
chained `RETURN TRANSID` task starts. The console logs one line naming
the terminal:

```
term=T123: PA1 break-out, transaction aborted
```

> **SysReq.** The 3270 *System Request* key is not decoded by the
> datastream layer bricks is built on, so it cannot trigger break-out —
> `PA1` is the single supported break-out key. Most emulators expose
> `PA1` directly (in c3270 / x3270 it is the `PA(1)` action); consult
> your emulator's key map.

---

## Configuration — `bricks.cnf`

Key=value, one per line, `#` for comments. Keys are case-insensitive.

| Key                          | Default                       | Notes |
|------------------------------|-------------------------------|-------|
| `port`                       | `2300`                        | Plain-TCP listener. |
| `tlsport`                    | `2023`                        | Used only when `start_TLS=yes`. |
| `start_TLS`                  | `no`                          | `yes` requires `tlscert` + `tlskey`. |
| `enforce_secure_login`       | `no`                          | `yes` blocks every TRANSID except the logon TRANSID until the session is authenticated. |
| `tlscert`                    | (none)                        | Path to PEM cert. |
| `tlskey`                     | (none)                        | Path to PEM key. |
| `secure_login_transacton`    | `CSSN`                        | The 4-character logon TRANSID. Built-in `CSSN` is implemented in Go; any other value must exist in `transactions.conf`. Misspelling preserved for back-compat; `secure_login_transaction` and `logon_transid` are also accepted. `CESN` (the IBM-traditional spelling) is accepted as a drop-in alias for `CSSN` and `CESF` for `CSSF` — both are canonicalised before dispatch, so every other knob and screen sees only the canonical name. |
| `start_transaction`          | (none)                        | If set, the 4-character TRANSID dispatched automatically after a successful `CSSN` sign-on — useful when a deployment has a clear "this is the app's home screen" and operators shouldn't have to type the first transid by hand. Empty / unset (the default) keeps today's behaviour: the operator lands at the blank TRANSID prompt with the `CSSNOK` success map. Rejected at startup if the value is neither empty nor exactly 4 characters, or if it equals `logon_transid` (loop guard). If the named transaction is missing from `transactions.conf` at run time, bricks logs one warning line and drops the operator at the blank prompt — no operator-facing error screen. ACLs on the target still apply: an unauthorised user lands on the standard "access denied" message. |
| `users_file`                 | `runtime/users.conf`          | Auth source. |
| `transactions_file`          | `runtime/transactions.conf`   | TRANSID dispatch table. |
| `maps_dir`                   | `runtime/map`                 | Directory of `*.map` files. |
| `rexx_dir`                   | `runtime/rexx`                | Directory of REXX programs. Sub-directories are supported: `transactions.conf` may reference programs as `subdir/file.rexx`. `CEDA PROGRAM` walks the tree recursively (depth cap 8, hidden-prefixed entries skipped). |
| `cobol_dir`                  | `runtime/cobol`               | Directory of COBOL programs. Same sub-directory support as `rexx_dir`. |
| `copybook_dir`               | `runtime/cobolcopy`           | Directory of COBOL copybooks (`SQLCA.cpy`, etc.). |
| `runtime_dir`                | `runtime`                     | Root for `maps_dir` / `rexx_dir` / `cobol_dir` / `tmp_dir` / `copybook_dir` when those aren't set explicitly. Set this to relocate the whole runtime tree in one knob. |
| `data_dir`                   | `data`                        | Holds `files.boltdb` (FILE store + TS queues). |
| `tmp_dir`                    | `runtime/tmp`                 | Sandbox directory for sequential text I/O (REXX `LINEIN`/`LINEOUT`, COBOL `READQ TD`/`WRITEQ TD`). Strict: ASCII only, LF-terminated, flat namespace, no traversal. See [Sequential file I/O — `tmp_dir`](#sequential-file-io--tmp_dir). |
| `ntp_server`                 | `time.google.com`             | NTP server polled every 12 hours to correct bricks's in-memory wall clock. EIBTIME / EIBDATE / FORMATTIME consult this corrected clock. Set to `off` to disable. Failures are non-fatal — bricks logs and continues with the previous offset (or the raw host clock if no sync has ever succeeded). See [Time synchronisation](#time-synchronisation). |
| `time_zone`                  | `Z` (UTC)                     | Military zone letter (`Z`=UTC, `A`–`M`=UTC+1..+12, `N`–`Y`=UTC-1..-12). Applies to operator-visible time fields; ABSTIME stays UTC milliseconds. See [Time synchronisation](#time-synchronisation). |
| `log_location`               | `log`                         | Directory where bricks writes per-run log files. On startup a new file `YYYY-MM-DD_HH-MM-SS.log` is created; every console line is appended (with ANSI color stripped) and prefixed with a 4-character subsystem tag. Set to `off` to disable file logging. See [Logging](#logging). |
| `idle_timeout_secs`          | `900`                         | Read deadline applied **only before sign-on** — to the LogonPrompt and to the BlankPrompt of an unauthenticated session, plus the CSSN sign-on input reads. A peer that completes telnet negotiation but never signs on is dropped after this many seconds so a half-open handshake doesn't tie up a `max_conns_per_ip` slot forever. **Once the operator has signed on, the deadline is not set** — a signed-on terminal sits at the blank prompt indefinitely and only disconnects on TCP close or an explicit `CSSF DISC` / `DISCONNECT` / `GOODNIGHT`. `CSSF LOGOFF` clears the authentication flag, so the deadline resumes for the now-unauthenticated session. |
| `max_conns_per_ip`           | `8`                           | Per-client cap. |
| `program_cache`              | `4`                           | L2 LRU pool size in MB for parsed REXX/COBOL programs (a 128-entry L1 of decoded ASTs sits in front of it). Allocated once at startup as eight contiguous byte slabs — one per shard — and reused for the life of the process; Go's GC never scans the program bytes. Valid range is `1..16384` (1 MB floor, 16 GB cap); out-of-range values are rejected at startup. Live counters for both tiers are visible in `CEMT MONITOR`. |
| `map_cache`                  | `128`                         | LRU bound on the number of **parsed** 3270 maps held resident. The directory index — `(map name → file path, mtime, size, SHA-256)` — always covers every `*.map` in `maps_dir`, so any map remains resolvable by name; only the parsed body is bounded. A `SEND/RECEIVE MAP` for a cached map is zero-parse; an evicted map is re-parsed on next lookup (microseconds) and re-inserted. Evicted entries drop their `*Map` pointer and the Go GC reclaims them on the next cycle, capping both steady-state memory and per-GC pointer-graph walk regardless of how many maps a deployment ships. Valid range is `1..1028`; rejected at startup if out of range. Live counters and runtime resize are visible in `CEMT P M`. |
| `banner`                     | `BRICKS Transaction Server`   | Shown at top of system screens. |
| `dns_name`                   | (none)                        | **Bind address.** Every bricks listener — the plain-TCP and TLS 3270 listeners, and the web3270 / `/metrics` HTTP services — binds **only** to the single IP this name resolves to (a literal IP is used as-is; a hostname resolves to one address, IPv4 preferred). A `dns_name` that is set but unresolvable is a fatal startup error. When `dns_name` is **empty**, listeners fall back to binding *all* interfaces (`0.0.0.0`) and bricks logs a `WARNING` — set `dns_name` to confine the server to one interface. |
| `start_web3270`              | `no`                          | `yes` enables the in-process browser-based 3270 emulator. |
| `web3270_port`               | `9000`                        | HTTP port for the web3270 frontend (only used when `start_web3270=yes`). |
| `start_metrics`              | `yes`                         | `yes` exposes a JSON `/metrics` endpoint with runtime + counter snapshots. Independent of `start_web3270`. Admin operators can flip the endpoint on/off at runtime via `CEMT PERFORM METRICS` without rewriting `bricks.cnf`. |
| `metrics_port`               | `9100`                        | HTTP port for the dedicated `/metrics` listener. The same route is also mounted on the web3270 listener when both are on. |
| `enable_wapi`                | `no`                          | `yes` enables the WAPI listener — the inbound-HTTP server that turns each matched request into a transaction dispatch via the `EXEC CICS WEB *` verbs (Phase 1 — server side). On startup bricks logs `WAPI listening on http://<host>:<port>/ (routes_file=…, N route(s) loaded)` (and a second `https://…` line when TLS opens). Off by default — no HTTP listener opens unless the operator opts in. Port defaults below apply unless overridden. |
| `enforce_wapi_tls`           | `no`                          | `yes` suppresses the plain HTTP listener — only the HTTPS port opens. Requires `tlscert` and `tlskey` to be set (rejected at startup otherwise). Use this for any deployment where the API is reachable from outside `localhost` so credentials and payloads aren't sniffable. |
| `wapi_port`                  | `8080`                        | TCP port for the **plain (non-TLS)** inbound EXEC CICS WEB listener. Bound to `dns_name` like every other bricks listener. Suppressed entirely when `enforce_wapi_tls=yes`. (`web_port` is accepted as a back-compat alias for the same field.) |
| `wapi_tls_port`              | `443`                         | TCP port for the **TLS** inbound EXEC CICS WEB listener. Opens whenever `enable_wapi=yes` AND `tlscert`/`tlskey` are set — the same cert/key as the 3270 TLS listener. The standard 443 is the default; on macOS / Linux bricks needs `CAP_NET_BIND_SERVICE` or root to bind it. Use `1443` / `8443` / etc. when running unprivileged. |
| `web_routes_file`            | `runtime/web_routes.conf`     | URIMAP-equivalent file. One row per route: `METHOD PATH-PATTERN TRANSID [groups] [response_timeout]`. `{name}` placeholders in the path are exposed to the transaction via `WEB READ QUERYPARM('name')`. Bad rows are skipped with a warning; bricks still starts. Hot-reload on mtime change. |
| `web_request_max_bytes`      | `1048576` (1 MiB)             | Hard cap on inbound body size — anything above returns 413. |
| `web_request_timeout`        | `30s`                         | Per-request total wall-clock cap. Accepts Go duration syntax (`5s`, `100ms`) or a bare integer (seconds). |
| `web_header_max_bytes`       | `65536`                       | Cap on combined inbound header size — protects against header-bomb attacks. |
| `web_client_timeout`         | `30s`                         | Per-outbound-request total wall-clock cap on the shared `*http.Client` driving `EXEC CICS WEB OPEN / CONVERSE / SEND / RECEIVE / CLOSE`. Go duration (`5s`, `100ms`) or bare integer seconds. `0` / `off` disables (no cap). |
| `web_client_max_idle_conns`  | `32`                          | Idle-connection pool size for the outbound `*http.Transport`. Per-host limit is the same value, so 32 hosts × 32 idle conns is the worst-case pool. |
| `web_client_tls_skip_verify` | `no`                          | `yes` accepts ANY TLS certificate on outbound HTTPS — test-only escape hatch for self-signed endpoints. Logs a loud `WARNING` at startup. Never use in production. |
| `web_client_ca_bundle`       | (none)                        | Path to a PEM file of trusted CAs to use for outbound TLS verification **instead of** the host system's trust store. Useful when bricks must trust an internal CA that's not installed system-wide. |
| `web_client_cert` / `web_client_key` | (none)                | PEM client-certificate + key for outbound mTLS — presented when an upstream service requires the caller to authenticate with a certificate (e.g. partner APIs gated by mTLS). Both must be set together; either alone is a startup error. |
| `web_inbound_client_ca`      | (none)                        | PEM CA bundle for **inbound mTLS**. When set, the WAPI TLS listener requires every client to present a certificate signed by this CA — handshakes from clients without an accepted cert are rejected at the TLS layer (no transaction dispatch happens). The dispatched program reads the verified peer cert via `EXEC CICS WEB EXTRACT CERTIFICATE` (see [`DFHWBCC.cpy`](runtime/cobolcopy/DFHWBCC.cpy)). Plain (non-TLS) listeners ignore this knob. |
| `db_host`                    | (none)                        | Postgres server hostname. Empty means SQL is not configured — bricks runs normally; `EXEC SQL` paths return SQLCODE = -1. See [SQL support](#sql-support). |
| `db_port`                    | `5432`                        | Postgres server TCP port. |
| `db_user`                    | (none)                        | Postgres login. |
| `db_password`                | (none)                        | Postgres password. URL-escaped when bricks builds the DSN, so special characters survive intact. |
| `db_sslmode`                 | `disable`                     | Passed straight to libpq (`disable`, `require`, `verify-ca`, `verify-full`, etc.). |
| `db_max_conns`               | `8`                           | Per-database connection pool cap (`SetMaxOpenConns` on the `*sql.DB`). |
| `db_stmt_timeout`            | `30s`                         | Per-statement wall-clock cap, enforced **from the bricks client side**. The cap counts every millisecond from the moment bricks sends the SQL to the moment the last result byte arrives — round-trip time on the wire is bounded, not just the server's CPU time. (PG's own `statement_timeout` is server-side only and would miss a network-bound stall; bricks layers both, so either side firing produces SQLSTATE 57014 → SQLCODE -952 / `SQL-TIMEOUT`.) Accepts a Go duration (`5s`, `100ms`, `1m30s`), a bare integer (seconds), or `0`/`off`/`none` to disable. Cursors are exempt — only single-shot statements (SELECT INTO, INSERT, UPDATE, DELETE) get the per-statement deadline; FETCH iteration is bounded only by PG's server-side timer. |
| `databases_file`             | `runtime/databases.conf`      | Catalogue of Postgres databases bricks knows about (CEDA-managed). First row is the default database for transactions that don't bind to a specific one. See [`databases.conf`](#databasesconf). |

Command-line flags (in addition to `--conf`):

| Flag             | Notes |
|------------------|-------|
| `--no-console`   | Disable the framed operator console; emit raw `log.Printf` lines on stderr. Use under `nohup` / `systemd` / when piping through `tee`. |

---

## WAPI routing — URL → TRANSID → program

Once `enable_wapi=yes` is set, the inbound listener resolves an
incoming HTTP request through **two operator-editable layers**.
Nothing is hard-wired — adding a new web application is one row
per layer, no code changes, no restart (both files reload on
mtime change).

```
HTTP request
    │
    ▼
runtime/web_routes.conf      ── URL pattern → 4-character TRANSID
    │
    ▼
runtime/transactions.conf    ── TRANSID → program file + ACL groups
    │
    ▼
runtime/rexx/*.rexx | runtime/cobol/*.cob       ── the program that runs
```

A four-app example mixing REST GET, REST POST, browse, and an
admin endpoint, in both REXX and COBOL:

**`runtime/web_routes.conf`** (URL → TRANSID):

```
# method  path-pattern         transid  [groups]   [response_timeout]
GET       /api/customer/{id}   WAPI     public
POST      /api/customer        WAPC     admin
GET       /api/orders/{id}     OAPI     users
DELETE    /admin/cache/{key}   CACR     admin                 5s
```

**`runtime/transactions.conf`** (TRANSID → program + ACL):

```
WAPI:rexx:wapi.rexx:public,users,admin
WAPC:cobol:wapic.cob:admin
OAPI:rexx:orders.rexx:users,admin
CACR:cobol:cacheclr.cob:admin
```

Each TRANSID is reachable from **both** front doors with no
extra wiring: a 3270 operator who types `WAPI` at the prompt runs
the exact same program that an HTTP `GET /api/customer/{id}`
request reaches. The transaction can tell which front door it's
serving by checking whether the `EXEC CICS WEB *` verbs return
data — they all return `INVREQ` on a 3270 dispatch — but most
programs don't need to: a transaction written for the 3270
naturally renders maps, and a transaction written for HTTP
naturally calls `WEB SEND`. Each side just doesn't reach the
other's verbs.

Live hot-reload — add a row to either file, save, hit the URL.
A bad row in `web_routes.conf` logs `web_routes.conf:N: skipping:
…` and is dropped; the surrounding good rows keep working
(opt-in ACL — see [Per-transaction ACL](#per-transaction-acl) —
applies to web rows too).

When you have hundreds of web applications, the two files just
grow longer; nothing about the dispatch path changes. CEMT
INQUIRE TRANSACTION pages through every transaction regardless
of which front door reaches it; `CEMT INQUIRE WEB` (Phase 3) will
do the same for routes.

### URIMAP — named outbound endpoints

A URIMAP entry in `runtime/web_routes.conf` defines a named
upstream service that outbound transactions reference by symbol
instead of hardcoded host/port/scheme. Real CICS uses URIMAPs
for the same purpose; the layered name → endpoint indirection
lets one row swap an entire fleet of programs to a new
upstream without code changes.

```
# Format: URIMAP NAME scheme://host[:port][/path-prefix]
URIMAP   GITHUB    https://api.github.com
URIMAP   WEATHER   https://api.openweathermap.org/data/2.5
URIMAP   INTRANET  https://api.internal:8443/v1
```

A program calls `EXEC CICS WEB OPEN URIMAP('GITHUB') SESSTOKEN(t)`
to resolve scheme/host/port from the named entry; the optional
path-prefix is recorded on the session and prepended to every
subsequent `WEB SEND` / `WEB CONVERSE` PATH. Operators can
inspect the loaded entries via `CEMT INQUIRE URIMAP`, and the
active inbound requests via `CEMT INQUIRE WEB`.

URIMAP rows load even when `enable_wapi=no` — the outbound-only
deployment (programs call external services, no inbound HTTP
listener) is fully supported.

Operators edit the URIMAP catalogue live from the 3270 console:
`CEDA URIMAP` lists every loaded row and accepts an `A` (alter) /
`D` (delete) selector per row, plus PF6 to define a new entry.
The editor uses the same mtime-guarded optimistic-concurrency
check the other CEDA screens use — if `web_routes.conf` was
modified externally between read and write, the screen reports
`file changed under us -- press ENTER to refresh` and the row is
not touched. Every successful change emits an audit line in the
bricks log (`ceda=URIMAP op=DEFINE …`), so the change history is
greppable.

### Inbound mTLS — verifying the caller's certificate

Set `web_inbound_client_ca=ca.pem` to require every HTTPS client
to present a certificate signed by `ca.pem`. The TLS handshake
rejects unauthenticated clients before they ever reach a route
handler — no `WEB *` verb runs, no transaction is dispatched.

Inside a dispatched program, `EXEC CICS WEB EXTRACT CERTIFICATE`
reads the verified peer cert into WORKING-STORAGE:

```cobol
       COPY DFHWBCC.   *> DFH-WB-CN, DFH-WB-ORG, DFH-WB-CO,
                       *> DFH-WB-SERIAL, DFH-WB-ISSUER, …
       EXEC CICS WEB EXTRACT CERTIFICATE
                       COMMONNAME(DFH-WB-CN)
                       ORGANISATION(DFH-WB-ORG)
                       COUNTRY(DFH-WB-CO)
                       SERIALNUM(DFH-WB-SERIAL)
                       ISSUER(DFH-WB-ISSUER)
       END-EXEC.
       EVALUATE EIBRESP
           WHEN DFHRESP(NORMAL)  ...   *> use the fields
           WHEN DFHRESP(NOTFND)  ...   *> non-TLS or no client cert
       END-EVALUATE.
```

`NOTFND` is returned on plain (non-TLS) requests and on TLS
requests where no client cert was presented — useful when one
TRANSID serves both authenticated and anonymous callers.

### Outbound HTTP — calling external APIs from a transaction

The other half of `EXEC CICS WEB *` is **outbound** — a bricks
transaction calling an HTTP API on a remote host. No `bricks.cnf`
toggle is needed; the outbound client is always available. Bricks
builds a single shared `*http.Client` at startup with the
`web_client_*` knobs above (timeout, idle-pool size, TLS-verify
escape hatch); every task reuses it.

The verb set is small: `WEB OPEN` (open a logical session and
return a `SESSTOKEN`), `WEB CONVERSE` (one-shot send + receive),
`WEB SEND` / `WEB RECEIVE` (the split form), and `WEB CLOSE`.
Sessions left open at task end are auto-closed by the dispatcher.

The shipped COBOL sample (`runtime/cobol/wzen.cob`, TRANSID
`WZEN`) fetches GitHub's public `/zen` endpoint over HTTPS and
displays the one-line reply on a 3270 map. Trace through it for
the canonical "make an HTTPS call from CICS" pattern:

```
EXEC CICS WEB OPEN HOST('api.github.com') PORT(443)
                   SCHEME('HTTPS')
                   SESSTOKEN(DFH-WB-SESS) END-EXEC.

EXEC CICS WEB CONVERSE SESSTOKEN(DFH-WB-SESS)
                       METHOD('GET') PATH('/zen')
                       INTO(BODY)
                       STATUSCODE(STAT) END-EXEC.

EXEC CICS WEB CLOSE SESSTOKEN(DFH-WB-SESS) END-EXEC.
```

Sign on with `CSSN` → `admin` / `admin`, type `WZEN`, press
ENTER — within `web_client_timeout` (30 s by default) the
program returns with the body in `BODY` and the HTTP status in
`STAT`. The system's CA bundle validates the api.github.com cert
automatically; no TLS configuration is required for outbound
HTTPS to a normal public endpoint.

---

## Authentication procedure

The connection lifecycle is owned by `main.go::handle()`:

1. **Accept** — telnet/3270 negotiation runs (`tn3270.Negotiate`); device size
   and codepage are captured.
2. **TCB** — a fresh `session.TCB` is created with a unique `TermID` (T0001,
   T0002, …) and registered in the global `session.Registry`.
   `Authenticated` is `false`.
3. **Splash** — `tn3270.ShowLogoSplash` paints `bricks.logo` in blue,
   centered. No input fields. Returns when the user presses any AID.
4. **Logon prompt** — `tn3270.LogonPrompt` shows the logo plus a TRANSID
   input field. When `enforce_secure_login=yes` and the session is not yet
   authenticated, a blue notice on row 0 reads `Sign on with <transid> to
   continue.`. PF3 / CLEAR / PA1-3 disconnect.
5. **Auth gate** —
   * If the typed TRANSID equals `secure_login_transacton`, the configured
     logon flow runs. The default `CSSN` is built into `auth/cssn.go`: it
     loads `runtime/map/cssn.map`, prompts for userid+password, looks the user up in
     `runtime/users.conf`, verifies the bcrypt hash with `golang.org/x/crypto/bcrypt`,
     and on success sets `tcb.UserID`, `tcb.Groups`, `tcb.Authenticated=true`,
     and attaches the TCB to a UCB via `Registry.AttachUserToTerminal`.
     Failures bump `Registry.AuthFailure` and re-prompt — but only
     up to a per-session cap. After **3 consecutive failed credential
     checks** on the same TCP connection, `RunCSSN` logs
     `term=Tnnnn disconnecting after 3 failed sign-on attempts` and
     returns `ErrDisconnect`; `main.go::handle` then drops the
     connection. The counter does not advance on usage errors like
     an empty userid (the operator gets to correct the form without
     burning an attempt), and it resets the next time the peer
     reconnects. The cap lives at `auth.MaxSignonFailures`.
   * Otherwise, if `enforce_secure_login=yes` and the session is not
     authenticated, the dispatcher is bypassed and the user is shown
     `Not signed on. Run <logon> first.` then sent back to the prompt.
   * Else the dispatcher runs the TRANSID.
6. **Dispatch** — `txn.Dispatcher.Run` chains through `tcb.NextTransid` after
   each `EXEC CICS RETURN TRANSID(...)`. When the next TRANSID is empty,
   control returns to step 4. Before each dispatch the per-transaction
   ACL gate fires (see [Per-transaction ACL](#per-transaction-acl)
   below); a denied dispatch shows `TRANSID "X": access denied -- ...`
   on the operator screen and logs the user / groups / required list
   to the console for grep.
7. **Sign off** — typing `CSSF LOGOFF` (any case; argument required) at the
   blank prompt detaches the UCB via
   `Registry.DetachUserFromTerminal(tcb)`, clears `tcb.UserID` and
   `tcb.Authenticated`, and sends the terminal back to the unauthenticated
   logon prompt. **The TCP connection stays open**: only the user's TCP
   close cuts it. Bare ENTER, PF3, CLEAR, and PA1-3 at the blank prompt
   redisplay the same screen — they no longer disconnect.
8. **Disconnect** — `defer registry.RemoveTerminal(tcb)` drops the TCB; if the
   user was signed on and this was their last terminal the UCB is also
   dropped.

The top-level prompt sets `conn.SetReadDeadline(now + idle_timeout_secs)`
**only while the session is unauthenticated** — that's the
half-open-handshake guard, not a session-idle timer. A peer that
completes telnet negotiation but never signs on is dropped after
`idle_timeout_secs` so it doesn't tie up a `max_conns_per_ip` slot
forever. A signed-on operator gets no read deadline at all; the
blank prompt waits indefinitely. The only intentional disconnects
are TCP close (the peer pulls the plug) and `CSSF DISC` /
`DISCONNECT` / `GOODNIGHT` (the operator explicitly asks bricks to
hang up). `CSSF LOGOFF` keeps the connection open and the deadline
resumes for the now-unauthenticated session.

`runtime/users.conf` format (the comment header in the file is the source of
truth):

```
# user:bcrypt_hash:groups(comma-separated)
admin:$2a$10$.....:admin,dev,users
alice:$2a$10$.....:dev,users
bob:$2a$10$.....:users
```

Group names are case-insensitive, application-defined strings. The
operator decides what each group means — bricks just compares the
TCB's group list against the per-transaction ACL (next section). Two
groups carry a built-in meaning the dispatcher honours directly,
without needing an entry in `transactions.conf`:

| Group | Gate |
|---|---|
| `admin` | Required for the `CEMT CONTROLBLOCKS` / `PERFORM` sub-trees and the entire `CEDA` transaction. |
| `dev` | Required for the `ISPF` source editor — see [ISPF — built-in source editor](#ispf--built-in-source-editor) and the operator manual at [`ISPF_editor.md`](ISPF_editor.md). A user without `dev` who types `ISPF` at the prompt gets `ISPF requires DEV group membership.` and is returned to the prompt. |

Anything else (`users`, `ops`, `qa`, …) is yours to define and use in
the per-transaction ACL column of `runtime/transactions.conf`.

To add or rotate passwords:

```sh
./add_brick_user.bash alice newpassword dev,users      # add (with ISPF access)
./add_brick_user.bash --update alice newpassword admin # update / change groups
go run ./cmd/brickspw "raw password"                   # just emit a hash
```

The script refuses to overwrite an existing user without `--update`.

---

## Per-transaction ACL

`runtime/transactions.conf` accepts an **optional last field** —
comma-separated, case-insensitive group names — that gates dispatch
per transaction. Format:

```
transid:type:program[:groups]
```

Three-field entries keep the legacy behaviour: `enforce_secure_login`
in `bricks.cnf` is the only check (so a signed-on user can run
anything, an unsigned-on user nothing if the gate is on). Add the 4th
field and the listed groups become an enforced ACL — checked in
`txn/dispatcher.go::Run` after the table lookup and before the REXX
program loads, and again in `LinkProgram` so a low-privilege task
can't `EXEC CICS LINK PROGRAM('ADMN')` to escalate.

Two reserved tokens:

| Token | Effect |
|---|---|
| `public` | Allow unauthenticated callers. Without it, a 4-field tx requires sign-on. |
| `*` | Allow any signed-on user, regardless of group. |

Decision precedence: `public` > unauthenticated denial > `*` > any
shared group. Real groups come from the `groups` column of
`runtime/users.conf` (attached to the TCB by `auth.RunCSSN`); both
sides are uppercased for comparison.

Examples:

```
HELO:rexx:hello.rexx                  # legacy — open to any signed-on caller (or anyone if enforce_secure_login=no)
HELP:rexx:help.rexx:public            # always reachable, even pre-CSSN
QAGE:rexx:qage.rexx:public,users,admin
PROD:rexx:prod.rexx:users,admin       # signed on AND in users or admin
ADMN:rexx:admn.rexx:admin             # admin only
ANYI:rexx:anyi.rexx:*                 # any signed-on user
```

A denied dispatch surfaces:

* On the 3270 screen: `TRANSID "QAGE": access denied -- requires
  group ADMIN, USERS` (or `-- sign on first` for an unsigned-on
  caller hitting a non-`public` ACL).
* In the console log: `term=T0001 transid=QAGE access denied;
  user="ALICE" groups=[USERS] required=[ADMIN]`.

`CEMT INQUIRE TRANSACTION` shows each transaction's ACL in the
`GROUPS` column (`-` for legacy 3-field entries) and a live `RES`
column indicating whether the transaction's program is currently
resident in the `program_cache` LRU pool. `RES` means a dispatch right
now would skip the parse and decode the program from the cached
buffer; `NOT` means the next dispatch will reread and reparse from
disk (because the program has never been loaded, or has been evicted
to make room for more-recently-used programs):

```
TRANSID  LANG  PROGRAM      INVOKED  CACHED  CACHE%  RES  GROUPS
QAGE     REXX  qage.rexx    124      123     99%     RES  PUBLIC,USERS,ADMIN
HELP     REXX  help.rexx    8        7       88%     RES  PUBLIC
HELO     REXX  hello.rexx   3        2       67%     NOT  -
ADMN     REXX  admn.rexx    0        0       -       NOT  ADMIN
```

The `CACHE%` column is cumulative hit rate over the life of this
bricks process; `RES`/`NOT` is the instantaneous answer right now.
They can disagree (e.g. a transaction with a 99% hit rate showing
`NOT` because its program was just evicted to make room for a hot
newcomer). The table is hot-reloaded on `transactions.conf` mtime
change, so adding or tightening an ACL takes effect on the next
dispatch with no bricks restart.

---

## In-memory control blocks

Bricks tracks four kinds of in-memory control blocks plus a process-wide
registry that owns them. All four live in package `session/`.

| Kind  | Scope                          | Lifetime |
|-------|--------------------------------|----------|
| TCB   | one per terminal connection    | accept → disconnect |
| UCB   | one per signed-on user         | first sign-on → last terminal disconnects |
| FCB   | one per CICS FILE name         | first access → process exit |
| TxCB  | one per running transaction    | dispatcher BeginTxn → EndTxn |


### `TCB` — termid_control_block (`session/session.go`)

One per accepted terminal connection. Holds everything bricks needs while
that connection is alive. Created at telnet-negotiation time, dropped on
disconnect. Field summary:

| Field            | Purpose |
|------------------|---------|
| `Conn`           | Underlying `net.Conn` (plain or `*tls.Conn`). |
| `Dev`            | `go3270.DevInfo` — terminal capabilities. |
| `IsTLS`          | True when the connection is on the TLS listener. |
| `TermID`         | Unique 4-digit terminal id (T0001 …). Mirrors `EIBTRMID`. |
| `UserID`         | Empty until the user signs on. |
| `Groups`         | Group membership snapshot from `users.conf`. |
| `RemoteIP`       | Remote host for per-IP accounting. |
| `Cols`, `Rows`   | Effective terminal size from `Dev.AltDimensions()`. |
| `Connected`      | Wall-clock time of accept. |
| `Authenticated`  | True after a successful CSSN sign-on. |
| `EIBAID`, `EIBCPOSN`, `EIBTRMID`, `EIBRESP`, `EIBRESP2` | EIB shadow used by EXEC CICS handlers. |
| `NextTransid`    | Set by `EXEC CICS RETURN TRANSID(...)`; consumed by the dispatcher. |
| `Commarea`       | COMMAREA bytes flowed between pseudo-conversational invocations. |
| `LastResponse`, `LastMapName` | Captured by `SEND MAP`; consumed by `RECEIVE MAP`. |
| `LockedRec`      | File→key map for `READ FILE UPDATE` / `REWRITE` protocol. |
| Counters (atomic): `TxnRun`, `TxnFailed`, `ScreensSent`, `ScreensRcvd`, `CommandsExec`, `BytesIn`, `BytesOut`. |

Once authenticated, `tcb.UCB()` returns the linked `*UCB`; nil before sign-on.

### `UCB` — userid_control_block (`session/ucb.go`)

One per signed-on user, regardless of how many terminals that user is using.
Created on the first successful sign-on for that userid; dropped when the
last terminal for that user disconnects.

| Field         | Purpose |
|---------------|---------|
| `UserID`      | The authenticated username. |
| `Groups`      | Groups from the most recent sign-on. |
| `FirstLogin`  | When the UCB was first created. |
| `LastLogin`   | When the most recent attached terminal signed on. |
| `LoginCount`  | Atomic counter, incremented on each `attach`. |
| `TxnRun`      | Atomic counter; the dispatcher bumps after every successful TRANSID. |
| `Terminals()` | Snapshot of every TCB this user is currently on. |
| `AnyTerminal()` | Convenience helper when only `Cols`/`Rows`/`IsTLS` is needed. |

`UCB.Terminals()` is the answer to "where is this user signed on right now,
and what are the terminal characteristics there?" — caller takes any TCB and
reads `Cols`, `Rows`, `IsTLS`, `Connected`, etc.

### `FCB` — file_control_block (`session/fcb.go`)

One per CICS FILE name. Created lazily the first time any session touches a
file (via READ/WRITE/REWRITE/DELETE FILE) and kept for the life of the
process.

| Field         | Purpose |
|---------------|---------|
| `Name`        | Uppercased FILE name. |
| `FirstAccess` | When the FCB was first registered. |
| `LastAccess`  | Atomic unix-nano of the most recent access. |
| Counters (atomic): `Reads`, `Writes`, `Rewrites`, `Deletes`, `NotFound`, `IOErrors`. |
| `Lock(termID)` / `Unlock(termID)` / `LockedBy()` | Track the holder of the current `READ FILE UPDATE` lock; the actual record-level mutex lives on `cics.Store`. |

### `TxCB` — transaction_control_block (`session/txcb.go`)

One per running transaction. Created by `Registry.BeginTxn` immediately
before the dispatcher runs the REXX program and removed by `EndTxn` after
the program returns or aborts.

| Field         | Purpose |
|---------------|---------|
| `ID`          | Sequential id (`X0000001 …`). |
| `TransID`     | The 4-character transid. |
| `Program`     | Program file as written in `transactions.conf`. |
| `StartedAt` / `EndedAt` | Wall-clock bookends. `Duration()` returns elapsed (running or final). |
| `TCB`         | Pointer to the terminal this transaction runs on. |
| `UCB`         | Pointer to the signed-on user (nil during the logon transaction itself). |
| `AddFCB(f)` / `FCBs()` | Set of FCBs touched by this transaction; populated automatically by the EXEC CICS file handlers. |

### `Registry` (`session/registry.go`)

Process-wide owner of every TCB, UCB, FCB, and TxCB. One instance is created
at startup and shared across the dispatcher, the auth flow, and the cics
store.

```go
reg := session.NewRegistry()
reg.AddTerminal(tcb)                              // on telnet-negotiation success
reg.AttachUserToTerminal(tcb, userID, groups)     // on CSSN success
reg.DetachUserFromTerminal(tcb)                   // on CSSF LOGOFF
reg.RemoveTerminal(tcb)                           // on disconnect

fcb  := reg.GetOrCreateFCB("USERS")               // called by cics.Store
txcb := reg.BeginTxn(tcb, "MENU", "menu.rexx")    // called by txn.Dispatcher
defer reg.EndTxn(txcb)

terms, users := reg.Snapshot()                    // for admin tools / CEMT
fcbs := reg.AllFCBs()
txns := reg.AllTxns()
nTCB, nUCB, nFCB, nTxCB := reg.Counts()
```

`Registry.Snapshot`, `AllFCBs`, and `AllTxns` are the entry points the CEMT
transaction uses to populate its Control Blocks screens.

**Lock layout.** The registry no longer uses a single global mutex over all
four collections. `tcbs`, `ucbs`, and `fcbs` each have their own
`sync.RWMutex`; `txcbs` is a `sync.Map` paired with an `atomic.Int64`
count, so `BeginTxn` / `EndTxn` (the per-transaction hot path) are
lock-free. Lock-ordering rule when more than one is needed:
`tMu` → `uMu` → per-block locks (`u.mu`, `t.mu`). `RemoveTerminal` and
`DetachUserFromTerminal` are the only paths that take `uMu` after `tMu`.

---

## How file storage works

CICS FILEs in bricks are **KSDS** (key-sequenced data sets), backed by a
single embedded B+tree database (`go.etcd.io/bbolt`) at
`data/files.boltdb`. Each CICS FILE is one bbolt **bucket** inside the
shared database; user-supplied keys map directly to the raw record bytes.

```
data/
    files.boltdb          ← single B+tree file
        bucket "CUSTOMERS"
            "00100" → "Alice Adams|123 Main St|Springfield, NY|212-555-0100"
            "00101" → "Bob Brooks|45 Elm St|Riverton, CA|415-555-0101"
            …
        bucket "ACCOUNTS"
            "A0001" → … (each app picks its own record format)
        bucket "_catalog"
            "CUSTOMERS" → JSON{records:250, key_max:6, rec_max:80, …}
            "ACCOUNTS"  → JSON{…}
```

Properties of the KSDS:

* **Record bodies are opaque.** Bricks does not impose any internal
  structure on a record — applications choose their own layout (separator-
  delimited, fixed-width, packed, JSON, raw EBCDIC). The example above
  uses `name|addr|city|phone` because *that's the application's choice*;
  bricks stores those bytes verbatim.
* **B+tree index.** READ by exact key is O(log n). STARTBR positions on
  any key in O(log n) and READNEXT walks in B+tree order in O(1) per step.
* **MVCC snapshot reads.** STARTBR opens a bbolt read transaction; the
  cursor walks a stable point-in-time view, so concurrent WRITE/REWRITE/
  DELETE on the same FILE don't disturb an in-progress browse.
* **Atomic writes.** WRITE/REWRITE/DELETE run inside a bbolt write
  transaction with `fsync` on commit; partial updates are never visible
  on disk after a crash.
* **Implicit DEFINE.** First WRITE to a FILE creates its bucket. There
  is no `EXEC CICS DEFINE FILE` step.
* **Per-FILE metadata.** A `_catalog` bucket tracks record count,
  last-modified, max key length, max record length, and creation time,
  so `CEMT INQUIRE FILE` shows accurate numbers without scanning the
  data bucket. The catalog is bricks-internal — REXX programs never see
  it.
* **Initial mmap.** bbolt is opened with a 4 MiB initial mmap so a
  long-running browse cursor doesn't deadlock against a write that needs
  to grow the file. Demo workloads (a few thousand records) never hit
  the grow path.

What this means for `EXEC CICS READ` / `WRITE` / `REWRITE` / `DELETE`:

| Verb | What bricks does on disk |
|------|-------------------------|
| `READ FILE('CUSTOMERS') INTO(REC) RIDFLD(K)` | One bbolt `View` tx, one B+tree lookup. The record bytes (whatever the app stored) come back into REC unchanged. |
| `WRITE FILE('CUSTOMERS') FROM(REC) RIDFLD(K)` | One bbolt `Update` tx: B+tree insert, `_catalog` bookkeeping, fsync. DUPREC if the key is already present. |
| `REWRITE FILE('CUSTOMERS') FROM(REC)` | Update tx that overwrites the value at the key locked by the prior READ UPDATE. Releases the per-FCB update lock at end of tx. |
| `DELETE FILE('CUSTOMERS') RIDFLD(K)` | Update tx that deletes the bucket entry; `_catalog` record count drops by one. |

What this means for `STARTBR / READNEXT / READPREV / RESETBR / ENDBR`:

* STARTBR opens a bbolt read tx + cursor; positions according to RIDFLD /
  GTEQ / EQUAL / GENERIC + KEYLENGTH (see the verb reference in
  [PROGRAMMING.md](PROGRAMMING.md)).
* READNEXT advances the cursor; with GENERIC active, returns `ENDFILE`
  the moment the prefix breaks (no full-file scan).
* READPREV walks backward from current position with the same prefix
  rule. Useful for paginating backwards through a key range.
* RESETBR repositions the cursor without closing the tx — cheaper than
  ENDBR + STARTBR when a program jumps inside the same browse session.
* ENDBR commits-rollback the read tx and releases its MVCC snapshot.

Pre-load 250 sample customers for the CUST transaction:

```sh
go run ./cmd/seed-customers
```

The seeder is idempotent; re-running adds only the missing rows.

---

## Sequential file I/O — `tmp_dir`

The `tmp_dir` directory is a sandboxed staging area for sequential
text files. It exists so REXX and COBOL programs can import data
from a `.csv` / `.txt` / `.tab` file into the VSAM (bbolt) store, or
export records out of it, without giving the application code raw
filesystem access.

Both languages hit the same backend (`cics.TmpStore`):

| Surface | Verbs |
|---|---|
| COBOL EXEC CICS | `READQ TD QUEUE(name) INTO(rec)` · `WRITEQ TD QUEUE(name) FROM(rec)` · `DELETEQ TD QUEUE(name)` |
| REXX builtins | `LINEIN(name)` · `LINEOUT(name, line)` · `LINES(name)` · `CHARIN/CHAROUT/CHARS(name)` · `STREAM(name, ...)` |

So a file produced by REXX is readable by COBOL and vice-versa; the
only constraint is an agreed column format inside each line.

The sandbox is **strict**:

* **Flat namespace.** Filenames match `[A-Za-z0-9._-]{1,255}` — no
  leading dot, no `..`, no slash or backslash, no NUL. Bricks runs
  `filepath.Rel` against every resolved path as defense-in-depth, so
  symlink and `..`-rebound attacks bounce too.
* **ASCII only.** Bytes must be `0x09` (TAB), `0x0A` (LF — the
  terminator), or `0x20`–`0x7E` (printable ASCII). No EBCDIC, no
  UTF-8, no UTF-16. The write path rejects the first violation with
  `INVREQ` (COBOL) or `ERROR` (REXX `STREAM('S')`) and names the
  offending byte's hex value and offset.
* **Unix line endings only.** Lines end with a single LF (`0x0A`).
  CR (`0x0D`) is explicitly rejected on write — bricks emits no
  CR-LF output ever. The read path splits on LF and preserves any
  CR bytes it finds verbatim (not stripped). To ingest a Windows
  file, pre-strip: `tr -d '\r' < windows.csv > runtime/tmp/clean.csv`.
* **Task-end cleanup.** Every handle a program opens is closed
  automatically at task end. A program that forgets `STREAM CLOSE`
  or `DELETEQ TD` does not leak descriptors.

The shipped `ORDR` sample transaction
(`runtime/cobol/ordr.cob`) demonstrates the canonical
"text → VSAM" pattern: read `runtime/tmp/orders.sample.txt` with
`READQ TD`, parse pipe-delimited rows, and `WRITE FILE('ORDERS')`
keyed on customer-id. Duplicates (`EIBRESP = 14`) are counted but
not fatal, so the import is idempotent on re-run. The full verb
reference is in
[PROGRAMMING.md, Chapter 9](PROGRAMMING.md#chapter-9-temporary-storage-and-transient-data-commands),
and the worked walk-through is in
[Chapter 27, example E](PROGRAMMING.md#e-sequential-import-via-readq-td--write-file).

---

## Time synchronisation

EXEC CICS `ASKTIME`, `FORMATTIME`, the `EIBTIME` / `EIBDATE` fields,
and the `EXEC CICS ASSIGN DATE / TIME / TODAYYR / TODAYMO / TODAYDY /
DAYCOUNT` shortcuts all consult an **NTP-corrected, time-zone-aware
wall clock** rather than the raw host clock. The implementation lives
in `bricks/timesync/`.

**How it works.** On startup bricks performs one synchronous SNTP-v4
query against the configured `ntp_server` (default `time.google.com`)
and logs the result:

```
ntp: initial sync ok skew=12.3ms server=time.google.com
```

or, on failure:

```
ntp: initial sync failed (time.google.com): dial: timeout -- continuing with host clock
```

The returned offset is stored in an `atomic.Int64` and applied to
every `Clock.Now()` call. A background goroutine repeats the query
every 12 hours; each result is logged the same way.

**Important: NTP failures are non-fatal.** If the server is
unreachable, returns garbage, or DNS fails, bricks logs one console
line and continues serving transactions. The previous successful
offset stays in effect (or zero on first failure, meaning bricks
falls back to the raw host clock). The 12-hour ticker retries
automatically — for one-off forced syncs in the meantime, restart
bricks (the initial sync runs synchronously at startup).

Bricks **never** sets the host OS clock — that would require root
and break the pure-Go / OS-independent guarantee. The offset is
purely a per-process correction applied at format time.

**Time zones.** The `time_zone` knob takes a single military letter
(`Z`=UTC, `A`–`M`=UTC+1..+12, `N`–`Y`=UTC-1..-12; `J` is reserved).
The selected zone applies to every operator-visible time field;
`ABSTIME` stays canonical UTC milliseconds since 1900-01-01
regardless. Examples:

| Letter | Offset | Typical city (winter) |
|---|---|---|
| `Z` | UTC+0 | London, Reykjavík |
| `A` | UTC+1 | Frankfurt, Paris |
| `B` | UTC+2 | Athens, Cairo |
| `I` | UTC+9 | Tokyo, Seoul |
| `K` | UTC+10 | Sydney, Brisbane |
| `M` | UTC+12 | Auckland, Wellington |
| `R` | UTC-5 | New York, Toronto |
| `U` | UTC-8 | San Francisco, Los Angeles |

Half-hour zones (India UTC+5:30, Adelaide UTC+9:30,
Newfoundland UTC-3:30) have no military letter; pick the nearest
whole-hour letter and adjust inside the program if 30-minute
precision matters.

**Disabling NTP.** Set `ntp_server = off` in `bricks.cnf` to skip
both the startup sync and the 5-minute goroutine. Bricks then uses
the raw host clock unchanged. Useful for air-gapped deployments
where outbound UDP/123 is blocked.

---

## Logging

Every line emitted to the framed console is **also appended to a
per-run log file** under `log_location` (default `log` under the
directory bricks was started in). On startup bricks creates a fresh
file named `YYYY-MM-DD_HH-MM-SS.log`, prints its path on the
console, and routes every subsequent `log.Printf` through a dual
writer (`bricks/brickslog`).

The console copy keeps any ANSI color codes (so red eviction
warnings, etc. render on the framed renderer). The **file copy
strips all ANSI escapes** so the log opens cleanly in editors and
log-aggregator tools.

### Subsystem tags

Every line carries a 4-character subsystem tag right after the
timestamp, padded so the message text always starts at column 6 of
the bracketed area:

```
2026/05/13 14:35:12 LOAD loaded 250 customers from data/files.boltdb
2026/05/13 14:35:12 NET  listener on :2300
2026/05/13 14:35:12 SYS  ntp: initial sync ok skew=12.3ms server=time.google.com
2026/05/13 14:35:17 AUTH term=T0001 signed on as admin
2026/05/13 14:35:18 EXEC term=T0001 transid=CUST: complete
2026/05/13 14:35:19 CICS term=T0001 READ FILE('CUSTOMERS') RID=00100 OK
```

Seven tags cover the codebase — kept deliberately few; more tags
fragment grep patterns without adding signal:

| Tag    | Subsystem |
|--------|-----------|
| `LOAD` | program loader / lexer / parser / cache (REXX, COBOL, MAP) |
| `EXEC` | transaction dispatch + REXX/COBOL runtime |
| `CICS` | EXEC CICS verb handlers (FILE, TS/TD queues, MAP, etc.) |
| `AUTH` | sign-on / sign-off / per-transaction ACL gates |
| `NET`  | 3270 / TLS / WebSocket / TCP listeners |
| `SYS`  | catch-all: config, startup, NTP, signals, console |
| `AUDT` | resource-mutation audit trail (CEDA DEFINE / ALTER / DELETE) — **file only**; falls back to console when `log_location=off` |

Untouched legacy `log.Printf` call sites get the `SYS` tag by
default (the dual writer is wired in as the standard `log` writer
during `brickslog.Init`). The per-subsystem helpers
(`brickslog.Load`, `brickslog.Exec`, `brickslog.CICS`, etc.) are
the way to opt into a more specific tag from new code.

### Configuration

```
# Default: log_location=log
log_location=/var/log/bricks
log_location=off
```

Setting `log_location=off` skips the file sink entirely; console
logging is unaffected. The default `log` directory is created on
startup if missing.

### File rotation

Bricks creates one file per startup — there's no built-in size or
time-based rotation. Long-running deployments should rely on
external tools (`logrotate`, `cronolog`, etc.) pointed at
`log_location`. A bricks restart always opens a new file, so
rotating by restarting cuts a clean boundary.

---

## SQL support

Bricks programs (COBOL and REXX) can run `EXEC SQL` against a
catalogue of Postgres databases. Same surface for both
languages: single-row CRUD (`SELECT INTO`, `INSERT`, `UPDATE`,
`DELETE`, `COMMIT`, `ROLLBACK`), the four-verb cursor lifecycle
(`DECLARE` / `OPEN` / `FETCH` / `CLOSE`), and per-task
`CONNECT TO 'name'` to switch between databases. See
[PROGRAMMING.md, Chapter 26](PROGRAMMING.md#chapter-26-embedded-sql-cobol)
for the full surface; this section covers operator-side setup.

### Configuration

The `db_*` block in `bricks.cnf` describes the **Postgres server**
(host / port / credentials / sslmode / pool size). The list of
databases bricks talks to lives in a separate `databases.conf`
file, managed via CEDA DATABASE A/D/U the same way `users.conf`
is managed via CEDA USER.

```
db_host=localhost
db_port=5432
db_user=bricks
db_password=...
db_sslmode=disable
db_max_conns=8
databases_file=runtime/databases.conf
```

Driver is `github.com/jackc/pgx/v5/stdlib` (database/sql adapter).
All keys are optional — when `db_host` is empty bricks runs
SQL-less and CEDA DATABASE reports `(SQL not configured)`. A
startup ping failure for any individual database is non-fatal
— one log line, and CEDA DATABASE shows that row as OFFLINE.

### `databases.conf`

One row per Postgres database, in the same style as
`users.conf`:

```
# bricks databases catalogue.
# Format: name[:description]
bricks:default application data
orders:order-management system
customers:customer master file
ledger:general ledger
```

The **first row is the default database** — transactions that
don't bind to a specific database fall back to it. To pick a
different default, just re-order the file (or use CEDA's add/
delete actions).

Each transaction in `transactions.conf` can optionally bind to a
named database via a 5th colon-separated field:

```
SQLD:cobol:sqld.cob:public                  # default db
ORDQ:cobol:ordq.cob:public:orders           # orders db
LEDQ:cobol:ledq.cob:admin,users:ledger      # ledger db, ACL'd
```

Adding a row to `databases.conf` (or CEDA DATABASE `A`) **only**
tells bricks about the database; it doesn't yet exist in
Postgres. To create the PG-side database, select the row and use
`C` on the CEDA DATABASE screen — bricks runs `CREATE DATABASE`
against PG's `postgres` maintenance connection and re-pings the
pool so it flips to ONLINE. The matching destructive action is
`X` (DROP DATABASE), which prompts the operator to re-type the
name as a safety gate and audit-logs both the attempt and the
outcome.

### CEDA DATABASE

The screen (`CEDA → D`) lists every row of `databases.conf` with
its current connection state and supports the standard CEDA
selector pattern:

| Cmd | Action |
|---|---|
| `A` | Add a new database row (form for name + description, writes `databases.conf`). |
| `C` | Create the PG-side database for an existing row (runs `CREATE DATABASE` via the maintenance connection; re-pings the pool). |
| `D` | Delete a row from the catalogue (refuses the default row). |
| `X` | Drop the PG-side database (confirmation form; closes the bricks pool first so PG won't complain about "other users connected"). |
| `U` | Alter a row's description. |
| `R` | Retest one row's connection. |
| `L` | Show that row's user-schema tables (one-line summary). |

`A` + `C` is the standard add-a-database flow; `X` + `D` is the
matching teardown. Each mutation flows through `brickslog.Audit`
— `ceda=DATABASE op=PG-CREATE target=orders status=OK term=T01
user=admin` — and the `databases.conf` rewrites are atomic
(write-and-rename), so a crash mid-mutation can't corrupt the
catalogue.

### Integration tests

The unit tests (`go test ./...`) cover the SQL executor's parsing
and mapping logic without a database. A second tier of live
integration tests exercises the executor end-to-end against a
real Postgres — they're behind the `pgtest` build tag so a normal
`go test ./...` (and CI without a database) stays green:

```
go test -tags pgtest ./cics/
```

These read the real connection parameters straight from
`bricks.cnf` (`db_host` / `db_user` / `db_password` /
`databases_file`), so they validate exactly the config an
operator runs with. When no database is reachable every test
`t.Skip()`s with a clear message. All work happens against a
hermetic scratch table (`bricks_pgtest_t`) created fresh at
start and dropped at the end — the operator's own data is never
touched. Coverage: SELECT INTO (row / no-row / multi-row),
INSERT / UPDATE / DELETE with `SQLERRD3` row counts, duplicate-key
and undefined-table SQLCODE mapping, null indicators (read and
write), the cursor lifecycle, COMMIT / ROLLBACK durability,
NUMERIC-scale and boolean coercion, the DDL gate, and `CONNECT TO`.

---

## Performance counters

All counters are `atomic.Uint64` so they can be sampled at any time without
locking.

### Process-level (`*session.Registry`)

| Counter             | Bumped when |
|---------------------|-------------|
| `Accepts`           | A TCB is added to the registry. |
| `Rejects`           | (Reserved for the per-IP cap path.) |
| `AuthSuccess`       | A UCB is attached to a TCB by the auth flow. |
| `AuthFailure`       | The auth store returns `ErrUnknownUser` or `ErrBadPassword`. |
| `TotalTxnRun`       | Every successful TRANSID dispatch. |
| `TotalTxnFailed`    | A REXX parse / runtime / IO error in `txn.Dispatcher.runRexx`. |
| `StartedAt`         | Server start (timestamp, not a counter). |

### Terminal-level (`*session.TCB`)

| Counter            | Bumped when |
|--------------------|-------------|
| `TxnRun`           | After a successful TRANSID on this terminal. |
| `TxnFailed`        | When the dispatcher records a failure for this terminal. |
| `ScreensSent`      | Reserved — `tn3270.SendMap` will increment once instrumentation lands. |
| `ScreensRcvd`      | Reserved — bumped by RECEIVE MAP. |
| `CommandsExec`     | Reserved — bumped by every `EXEC CICS` dispatch. |
| `BytesIn`/`BytesOut` | Reserved for an instrumented `net.Conn` wrapper. |

### User-level (`*session.UCB`)

| Counter      | Bumped when |
|--------------|-------------|
| `LoginCount` | Each time a TCB attaches to this UCB (re-sign-on, additional terminal). |
| `TxnRun`     | Every successful TRANSID by any of this user's terminals. |

### File-level (`*session.FCB`)

| Counter    | Bumped when |
|------------|-------------|
| `Reads`    | A successful `READ FILE`. |
| `Writes`   | A successful `WRITE FILE`. |
| `Rewrites` | A successful `REWRITE FILE`. |
| `Deletes`  | A successful `DELETE FILE`. |
| `NotFound` | The record did not exist on read/rewrite/delete. |
| `IOErrors` | The underlying filesystem returned a non-`NotExist` error. |

### EXEC CICS verb (`cics/metrics.go`)

| Counter                  | Bumped when |
|--------------------------|-------------|
| `cics.ExecTotal()`       | Every parsed EXEC CICS verb dispatch (`atomic.Int64`). |
| `cics.ExecPerVerb()`     | Snapshot of `(verb, count)` pairs sorted by count desc. Backed by a `sync.Map` of `*atomic.Int64` so the hot path is lock-free for any verb already seen. |

Live counters can be inspected from a 3270 terminal via the CEMT
transaction's INQUIRE CONTROLBLOCKS sub-tree and the MONITOR screen
(see below).

---

## Operator console

Pass `--no-console` to disable the frame and emit raw log output
(suitable for `nohup` / `systemd` / piping through `tee`).

---

## ISPF — built-in source editor

`ISPF` is a built-in TRANSID (no entry in `transactions.conf`,
implemented in package `ispf/`) that lets operators browse and edit
the REXX, COBOL, and BMS-map source trees from a 3270 session. It is
restricted to users who belong to the **`dev`** group in
`runtime/users.conf`; everyone else gets `ISPF requires DEV group
membership.` and a return to the blank prompt.

**The full operator manual** — every PF key, every command-line word,
every line-prefix command (D / I / C / M / R / U / L / ) / ( / X / O /
A / B plus the doubled block forms), the file browser, the warn-then-
save flow, multi-file editing, and edit locks — lives in
[`ISPF_editor.md`](ISPF_editor.md). The summary below is the operator-
quick-start; consult the manual for the verb and command surface.

The transaction follows the authentic ISPF *DATA SET LIST UTILITY*
look: white dashed banner, blue prompts, turquoise body, red intense
values in the writable fields. Three layers:

1. **Menu.** Pick the area: `1` REXX (`cfg.RexxDir`), `2` COBOL
   (`cfg.CobolDir`), or `3` MAPS (`cfg.MapsDir`). `F3` exits ISPF and
   returns to the blank prompt.

2. **File browser.** Two-column paged listing of files under the
   chosen area (filtered by extension: `.rexx` / `.cob` / `.map`).
   Type any character in the selector field next to a file and press
   ENTER to open it; type `D` and press ENTER to delete (with a `F9`
   confirmation overlay). `F6` creates a new file (prompts for a
   filename, auto-appends the extension, validates against the
   sandbox rules, creates an empty file, and drops into the editor).
   `F7` / `F8` paginate. `F3` returns to the menu.

3. **Editor.** ISPF-style line editor with column ruler, command
   line, scroll-mode field, and per-token syntax highlighting driven
   by the bricks REXX / COBOL / MAP lexers. AID map:

   | Key | Action |
   |---|---|
   | `F1` | Show the help overlay (any key dismisses) |
   | `F3` | Exit; prompts to abandon if the buffer is modified |
   | `F7` / `F8` | Scroll up / down (honours the `Scroll` field) |
   | `F10` / `F11` | Scroll left / right by 8 columns |
   | `F12` | Save and exit |
   | ENTER | Apply on-screen edits, process command-line if present |

**Per-path edit lock.** While a file is open in the editor it is
locked against other ISPF users. A second `dev` operator opening the
same file in the browser sees a red `Locked by USER123 since HH:MM`
message on the status line; the editor doesn't open. Locks release
on PF3 / PF12 / TCP drop / panic-unwind, all via
`txn.Dispatcher.runISPF`'s deferred `EditLocks.ReleaseAllByTerm`.

**Syntax highlighting.** Per-token color via go3270 `AttributeOnly`
overlay fields layered over each writable line. Palette: blue intense
keywords, turquoise strings, yellow numbers, green comments, white
identifiers. REXX block comments that span lines won't fully colorize
past the opening line — known v1 limitation, documented in the plan.

**File creation race.** Two `dev` users pressing `F6` with the same
filename are resolved by acquire-lock-before-create: the loser sees
`Locked by` on the status line and bounces back to the browser
without creating the file.

The full implementation plan (visual mockups, color palette, lock
semantics, save-validation strategy, EBCDIC 037 character discipline,
and risks) is in [`ispf_plan.md`](ispf_plan.md). The source layout:

| File | What |
|---|---|
| `ispf/menu.go` | The 1=REXX / 2=COBOL / 3=MAPS picker. |
| `ispf/ispf_filebrowser.go` | Two-column paged browser (port of the tsu source). |
| `ispf/ispfeditor.go` | Editor screen + AID dispatch (port of the tsu source). |
| `ispf/newfile.go` | PF6 "create new file" prompt + validator. |
| `ispf/highlight.go` | Per-line REXX / COBOL / MAP tokenizers. |
| `ispf/style.go` | Color palette constants (banner / prompt / body / value). |
| `ispf/host.go` + `ispf/area.go` | `EditorHost` interface and area enum. |
| `ispf/dispatch.go` | `ispf.Run` top-level menu → browser → editor loop. |
| `txn/ispf.go` | `Dispatcher.runISPF` — DEV-group gate + host shim. |
| `session/editlocks.go` | Process-wide `EditLockRegistry`. |

---

## CECI — command-level interpreter

`CECI` is a built-in TRANSID (no entry in `transactions.conf`,
implemented in package `ceci/`) that lets developers type a single
`EXEC CICS`, `EXEC SQL`, or `EXEC WEB` command and see the response
on the screen. Like ISPF it is restricted to users who belong to the
**`dev`** group in `runtime/users.conf`; everyone else gets
`CECI requires DEV group membership.` and a return to the blank
prompt.

```
CECI                                                      TERM=T0001  14:30:42
> exec cics asktime abstime(t)
>
>
>
>
RESPONSE:  NORMAL(0)    RESP2: 0      LEN: 46      ELAPSED: 0.044msec
EIBDATE=0126151
EIBTIME=143042
T=003989219027483
(blank result rows)
PF 3 END   5 PROCESS   7 SCROLL UP   8 SCROLL DOWN   PA1 BREAK
```

The screen has three zones:

1. **Input zone (rows 1–5).** Five writable rows, each marked with a
   green `>` indicator at the left edge. Type the command across as
   many rows as needed; rows that end in `(` or `,` are joined to the
   next row without a space (mid-token continuation), otherwise rows
   are joined with one space. A leading `EXEC CICS` / `EXEC WEB` /
   `EXEC SQL` is stripped before parsing, so both styles work.

2. **Response line (row 6).** Shows the dispatch outcome as
   `RESPONSE: NAME(rc)   RESP2: n   LEN: n   ELAPSED: d.dddmsec`.
   The `NAME(rc)` slot carries `NORMAL(0)` in white intense on
   success, the IBM condition name (`NOTFND`, `INVREQ`, etc.) in
   red on a non-NORMAL return, and one of `SYNTAX`, `DENIED`,
   `TIMEOUT`, `BADCHAR`, `NOSQL` in red for the corresponding
   early-return paths. Mutating verbs that succeed render
   `NORMAL(0)` in yellow intense so the operator notices the
   commit.

3. **Result pane (rows 7..R-2).** Variables the handler set during
   the call (`T=003989...`), `INTO`/`SET` buffer hex dumps,
   and any error detail (lines starting with `! `). The pane is
   cleared at the top of every PF5 press so each run's output
   replaces the previous run's output rather than appending.
   Scrolls with PF7 / PF8.

| Key | Action |
|---|---|
| `PF5` | Execute the current input |
| `PF3` | Exit CECI |
| `PF7` | Page down through the result pane |
| `PF8` | Page up through the result pane |
| `PA1` | Break out (also exits CECI) |

**Per-PF5 transaction lifetime.** Each press of `PF5` mints a fresh
`TxCB` and `cics.Handler` that commits on success and tears down
all handler-owned resources — open browses, TD handles, outbound
WEB sessions, document tokens, ENQ locks. Consequence: a file
`READ UPDATE` followed by `REWRITE` cannot span two PF5 presses;
type both on the same input or use a real transaction.

**Session-scoped variable frame.** A simple in-memory map satisfies
the `cics.Frame` contract; variables the handler `Set()` persist for
the whole CECI session, so a sequence like
`READ FILE('CUSTOMERS') RIDFLD('00001') INTO(REC) RESP(RC)` populates
`REC` and `RC`, and the next command can reference them. The frame
is cleared when CECI exits, not when a command runs.

**Verb policy.** CECI rejects verbs that would mangle the shell
itself:

- **Flow-altering:** `RETURN`, `XCTL`, `LINK`, `ABEND` would unwind
  the CECI task.
- **Screen-stealing:** `SEND MAP`, `SEND TEXT`, `SEND CONTROL`,
  `RECEIVE MAP`, `CONVERSE` would repaint CECI's own screen.
- **Task-life:** `START`, `RETRIEVE`, `CANCEL`, `DELAY` have no live
  task to receive deferred work or block in.
- **Trap tables:** `HANDLE`, `IGNORE`, `WHENEVER` set per-task trap
  state that would not survive the per-PF5 handler teardown.
- **Rollback:** `SYNCPOINT ROLLBACK` is meaningless — the per-PF5
  TxCB auto-commits at end-of-press.

`ENQ` is auto-rewritten with `NOSUSPEND` so a typed-in lock cannot
wedge the CECI session for the full 5-minute ENQ wait. Mutating
verbs that pass policy (`WRITE`, `REWRITE`, `DELETE`, `WRITEQ TS/TD`,
`WEB SEND` / `WEB RECEIVE` / etc.) commit at end-of-PF5 and the
RESPONSE line paints `NORMAL(0)` in yellow as the visible warning.

**Wall-clock cap.** Every command runs under a 7-second timeout.
On cap-hit the RESPONSE line shows `TIMEOUT` in red and the
abandoned goroutine is left to drain; CECI's defer chain skips
the handler closers on the timeout path to avoid racing the
in-flight call.

**EBCDIC 037 character discipline.** The shell rejects input rows
containing characters outside EBCDIC code page 037 (`[`, `]`, `{`,
`}`, `~`, `\`, backtick, `|`, `^`) with a `BADCHAR` response — these
characters do not render on a real 3270 terminal.

The source layout:

| File | What |
|---|---|
| `ceci/ceci.go` | `TransID`, `Deps`, `Run` AID loop, per-PF5 `executeOnce`, 7-second timeout race. |
| `ceci/screen.go` | Layout primitives, RESPONSE-line composition, EBCDIC input audit. |
| `ceci/frame.go` | Map-backed `cics.Frame` implementation. |
| `ceci/policy.go` | Verb deny / soft-warn lists; ENQ auto-NOSUSPEND rewrite. |
| `ceci/result.go` | Scrollable result buffer with wrap, head-trim, hex/ASCII dump. |
| `txn/ceci.go` | `Dispatcher.runCECI` — DEV-group gate + `Deps` construction. |

---

## CEMT — master-operator transaction

`CEMT` is a built-in TRANSID (no entry needed in `transactions.conf`,
implemented in package `cemt/`). INQUIRE (except its CONTROLBLOCKS
sub-tree) and MONITOR are open to any signed-on user; CONTROLBLOCKS
and PERFORM are gated on the `admin` group because they expose
internal control-block details and run mutating actions (purge / rescan).

```
+-----------------------------------------------------------+
| BRICKS Transaction Server  •  CEMT — master terminal      |
|                                                           |
|   Pick an option and press ENTER. PF3 to back out.        |
|                                                           |
|     I  INQUIRE   resources, CICS-style                    |
|     M  MONITOR   process metrics                          |
|     P  PERFORM   scans + TS purge (admin)                 |
|     Q  QUIT      (or press PF3)                           |
|                                                           |
|   Choice: _                                               |
+-----------------------------------------------------------+
```

Every node accepts any unambiguous abbreviation of its name (so `MON`,
`MONIT`, `MONITOR` all reach MONITOR; `INQ`, `PERF`, etc. follow the
same rule), and tokens chain — `CEMT P T` jumps straight to PERFORM →
TRANS without any intermediate menu.

### CEMT INQUIRE

The CICS-style read-only resource views, plus a CONTROLBLOCKS sub-tree
that exposes the live runtime control blocks for admins:

```
S  TS              TS queue stats
F  FILE            file resources
U  USER            signed-on users
T  TERMINAL        connected terminals
R  TRANSACTION     entries from transactions.conf
C  CONTROLBLOCKS   TCBs / UCBs / TXCBs / FCBs (admin)
   ├── T  TCBS    (3 active terminals)
   ├── U  UCBS    (1 signed-on users)
   ├── X  TXCBS   (0 running transactions)
   └── F  FCBS    (2 known files)
```

Each detail screen renders a fixed-width table. Columns are auto-sized
to the widest value, with a fallback to ellipsis when the row would
overflow. Every INQUIRE screen sorts rows alphabetically by the
first column (TRANSID, TERMID, FILE, USERID, …) so a long list reads
in operator-friendly order. PF3 exits the screen, ENTER refreshes
counters in place.

`CEMT INQUIRE USER` further colour-codes its rows so the four
categories of "user" jump out at a glance:

* **Red** — connected AND signed-on (a UCB exists for the userid).
  The `TERMS` column lists every TermID this user is on, so one user
  with two open sessions collapses into one row (`T0001,T0002`).
* **Pink** — connected but NOT signed-on. One pink row per
  unauthenticated TCB, USERID `(none)`, with the TermID in `TERMS`.
  Two anonymous connections produce two pink rows.
* **Turquoise** — previously signed-on this process but now
  disconnected. Pulled from an in-memory gone-cache that snapshots
  every UCB the registry drops; sorted newest-first by `LASTLOGIN`.
  Re-signing-on the same userid removes the entry so nothing is shown
  twice.
* **Yellow** — defined in `users.conf` but not seen this process.
  Rendered at the bottom so admins have the full catalogue in front of
  them when switching to `CEDA USER` to alter or define entries.

Each userid appears at most once across the four tiers. The
`TERMS` column sits at the right end of the row and absorbs
whatever screen width is left after the fixed columns; TermIDs are
appended comma-separated until adding the next one would push past
the right margin, at which point the list simply stops.

The gone-cache is purely in-memory — bricks restart clears it and no
login is ever written to disk by this screen.

### CEMT MONITOR

Process metrics (`cemt/perf.go`). Single screen — a renamed home for
what used to be `CEMT P PERFORMANCE`:

```
+----------------------------------------------------------------------+
| BRICKS Transaction Server • CEMT — Performance • TERM=T0001          |
|                                                                      |
|  Process                              Activity                       |
|  ───────────────────────              ───────────────────────         |
|  Memory (heap)        12.4 MB         EXEC CICS total       1,234    |
|  Memory (sys)         45.1 MB           SEND                  312    |
|  Heap objects        12,345             RECEIVE               312    |
|  GC runs                  3             READ                  140    |
|  GC last pause         1.20 ms          ASSIGN                 80    |
|  CPU user             2.50 s            LINK                   33    |
|  CPU sys              0.30 s            …                            |
|  CPU% (avg)           1.8%                                           |
|  Goroutines               7                                          |
|  Uptime               3m 12s                                         |
|                                                                      |
|  Sessions                                                            |
|  ───────────────────────────────────────────────────────────────────  |
|  Active terminals    2          Active transactions    1             |
|  Signed-on users     1          Known files            1             |
|                                                                      |
|  ENTER=Refresh  PF3=Back                                             |
+----------------------------------------------------------------------+
```

### CEMT PERFORM

The diagnostic rescans plus the live program- and map-cache
controls grouped under one admin sub-branch:

```
M  MAPCACHE        (N/M entries)                  -- resize / inspect the map LRU
R  RESCAN    trans / maps / programs              -- on-disk diagnostic scans
   ├── T  TRANS     (N transactions, M missing)   -- rescan transactions.conf
   ├── M  MAP       (N maps, M syntax errors)     -- parse every *.map in MapsDir
   └── P  PROGRAMS  (N programs, M orphans)       -- walk rexx_dir + cobol_dir
C  PROGRAMCACHE   (L1 N/M, L2 N MB)               -- resize / inspect the program cache
E  METRICS        (enabled|disabled, N scrapes)   -- toggle /metrics endpoint
```

(TS-queue purge moved to `CEDA QUEUES` — purges live alongside the
other CEDA mutations.)

* **RESCAN TRANS** (`CEMT P R T`) re-stats every program path declared
  in `runtime/transactions.conf` and renders TRANSID / LANG / PROGRAM /
  STATUS / PATH. STATUS is `OK` when the file is present, `MISSING` when
  it is not, or `ERROR: <message>` for any other stat error (e.g. a
  permission problem). ENTER re-runs the scan, so an operator can fix
  the conf or drop a file in place and watch a row flip without leaving
  the screen.
* **RESCAN MAP** (`CEMT P R M`) walks `MapsDir`, parses every `*.map`
  with `mapdsl.Parse`, and renders FILE / NAME / STATUS / SYNTAX.
  STATUS is `OK` when the file is readable, `MISSING` (or the stat
  error) otherwise. SYNTAX is `Pass` when the parser accepts the file,
  the parser error verbatim when it doesn't, and `-` when the file
  isn't readable. The catalog reload path silently keeps the prior
  catalog when a parse fails — this screen is how an operator finds
  out which file is broken.
* **RESCAN PROGRAMS** (`CEMT P R P`) walks `rexx_dir` and `cobol_dir`,
  lists every regular file, and shows the TRANSIDs in
  `transactions.conf` that reference it. Files with no matching
  TRANSID render with TRANSID=`-` so stale leftovers stand out.
* **MAPCACHE** (`CEMT P M`) shows the live counters for the parsed-
  map LRU set by `map_cache` in `bricks.cnf`: capacity, current
  occupancy, hits / misses / hit-ratio, and eviction count. The one
  writable cell takes a new capacity (`1..1028`); PF5 applies it
  immediately. Shrinking evicts the LRU overflow in place; counters
  survive the resize so the hit-ratio stays meaningful across an
  operator adjustment. Saturated occupancy paired with a steady
  eviction stream is the signal that the cap should be raised.
* **PROGRAMCACHE** (`CEMT P C`) is the parallel screen for the
  REXX/COBOL program cache — see the dedicated section under
  "Performance and security hardening" for the L1/L2 details.
* **METRICS** (`CEMT P E`) is the admin runtime toggle for the
  `/metrics` JSON endpoint. The top half of the screen shows live
  state (ENABLED / DISABLED, the endpoint URL, process uptime); a
  two-column counter grid lists SCRAPES, ERRORS, BYTES SERVED,
  IN FLIGHT, LAST STATUS, LAST SCRAPE, LAST BYTES, LAST DURATION,
  RATE per-second, and AVG bytes / scrape. The one writable cell
  accepts `Y` (enable) or `N` (disable); PF5 applies and is
  highlighted red on the footer to mark it as the commit key.
  When disabled, every scrape returns `503 Service
  Unavailable` immediately and the handler skips the
  `runtime.ReadMemStats` probe — that probe is a stop-the-world
  GC sample, so a deployment with no scraper attached can park
  the endpoint and save real CPU without restarting bricks.
  Counters keep advancing while disabled, so an operator can see
  whether a stale scraper is still trying to reach the endpoint.
  Toggling is admin-only and survives until the next process
  restart (it does NOT rewrite `start_metrics` in `bricks.cnf`).

---

## CEDA — resource definitions

`CEDA` is a separate built-in TRANSID (no entry needed in
`transactions.conf`, implemented alongside CEMT in package `cemt/`).
It is **admin-only** end-to-end. Every mutation surface that matters
for a bricks deployment — users, transactions, programs on disk,
SQL databases, VSAM files, and TS queues — lives under CEDA:

```
+--------------------------------------------------------------+
| BRICKS Transaction Server  •  CEDA — resource definitions    |
|                                                              |
|   Pick an option and press ENTER. PF3 to back out.           |
|                                                              |
|     U  USER         (N users)                                |
|     T  TRANSACTION  (N transactions)                         |
|     P  PROGRAM      (N REXX, M COBOL on disk)                |
|     D  DATABASE     (N databases)                            |
|     V  VSAM         (N VSAM files)                           |
|     Q  QUEUES       (N queues -- type P to purge)            |
|                                                              |
|   Choice: _                                                  |
+--------------------------------------------------------------+
```

CEDA shares CEMT's title bar, palette, and `pagedTable` layout — so
the screens look identical to a CEMT INQUIRE screen — but lives in
its own command tree. Tokens chain the same way: `CEDA U`, `CEDA
USER`, `CEDA CED U` (a no-op prefix that drops through), and `CEDA
TRANS` all reach the right screen via the existing
unambiguous-prefix matcher.

Real CICS CEDA's Groups / Lists / INSTALL / COPY / CHECK
abstractions are intentionally absent — bricks already collapses
CEDA's "definition + install" cycle into "edit text file,
hot-reload" — so this is a focused resource-management tool, not
a verbatim CICS port.

* **CEDA USER** (`CEDA U`) lists every user from `users.conf` with a
  per-row `SEL` cell. Type `A` to ALTER, `D` to DELETE, press ENTER to
  apply. PF6 opens a full-screen DEFINE form with USERID / PASSWORD
  (hidden) / GROUPS fields. The bcrypt hash is generated in-screen —
  no need to run `cmd/brickspw` and paste the hash by hand. Leaving
  the password blank on an ALTER keeps the existing hash; on a
  DEFINE it's required. Deleting your own userid is refused so an
  operator can't lock themselves out. Every mutation is written
  atomically to `users.conf` in canonical form (sorted by userid;
  comments are not preserved) and the in-memory view is refreshed
  immediately, so the next sign-on attempt sees the change with no
  restart.

* **CEDA TRANSACTION** (`CEDA T`) lists every transaction with the
  same `SEL` selector pattern. The form takes TRANSID (4 chars,
  uppercased), LANGUAGE (REXX or COBOL), PROGRAM (file relative to
  `rexx_dir` or `cobol_dir`), and GROUPS (CSV). Validation runs
  before the write: bad TRANSID format, unknown language,
  path-traversal in the program filename, malformed group tokens —
  all refused with the message on the status line. Runtime counters
  (`Invocations`, `CacheHits`) are preserved across ALTER so an
  operator who tweaks an ACL doesn't reset the cache-hit ratio shown
  in CEMT INQUIRE TRANSACTION.

* **CEDA PROGRAM** (`CEDA P`) is the read-only counterpart — a
  combined view of `rexx_dir` and `cobol_dir` showing LANG, FILE,
  SIZE, MODIFIED, the TRANSIDs that reference the file, and a SYNTAX
  cell that says `OK` when the parser accepts the file or `ERR …`
  with the first parse error otherwise. Only the page currently
  visible is re-parsed on each refresh, so the cost per ENTER is
  bounded regardless of how many programs are deployed. Useful for
  spot-checking a freshly-deployed file before referencing it from a
  new CEDA TRANSACTION definition.

The DEFINE / ALTER forms are plain full screens — no overlay, no
decorative box — modelled on the CSSN sign-on screen's layout. Row
0 carries the breadcrumb (`CEDA DEFINE USER`, `CEDA ALTER
TRANSACTION`). The labeled input fields sit at fixed rows 2 / 4 /
(5) / 6 / 7 / 8 depending on the form, with each writable field's
attribute byte at column 11 and the cursor landing one column past
it (column 12) — the same 3270 convention the rest of bricks uses.
The `PF5=Apply  PF3=Cancel` legend is pinned to the actual last row
of the terminal (row 23 on mod 2, 31 on mod 3, 42 on mod 4) so it's
always where the operator expects to find it.

**Concurrency**: every CEDA write is mtime-guarded. If the on-disk
`users.conf` or `transactions.conf` has been modified by another
process (a parallel `vi`, a script, etc.) between when CEDA read the
file and when it's about to write, the mutation is refused with a
"file changed under us; press ENTER to refresh and retry" message.
The CEDA in-memory snapshot then reloads from the new state so the
retry sees what's on disk.

**Audit**: every applied mutation emits a single-line `ceda=…` log
record so an admin can grep the bricks log to see who did what:

```
ceda=USER op=DEFINE target=test1 detail="USERS" term=T0001 user=admin
ceda=TRANS op=ALTER target=HELO detail="rexx hello.rexx" term=T0001 user=admin
```

### CEDA VSAM

`CEDA VSAM` — any abbreviation works: `CEDA V`, `CEDA VS`,
`CEDA VSA` all reach it via the same unambiguous-prefix matcher —
opens the VSAM file catalogue. It lists every KSDS file inside
`files.boltdb` with its record count, key / record maximum
lengths, last-modified time, and a `LOCK` column showing the
terminal holding a `READ FILE UPDATE` lock (or `-` when free).
See [How file storage works](#how-file-storage-works) for the
bbolt internals.

The one row action is `P` (purge). Mark one or more files with
`P` in the selector column and press ENTER; a secondary
confirmation screen lists each selected file beside an input
field, and a file is purged **only** when its name is re-typed
exactly. A mismatched or blank entry drops that file from the
purge; `PF3` cancels the whole operation. A file currently
holding a `READ FILE UPDATE` lock is **blocked** — it is
reported as skipped and never reaches the confirmation screen,
so a purge can't surprise an in-flight task.

Purging a file drops both its bbolt data bucket and its
catalogue entry; it disappears from `CEMT INQUIRE FILE` as well.
A later `WRITE FILE` re-creates it empty. Every purge — success
or failure — is audit-logged:

```
ceda=VSAM op=PURGE target=CUSTOMERS term=T0001 user=admin status=OK
```

Like the rest of CEDA, the VSAM screen is admin-only.

### CEDA QUEUES

`CEDA QUEUES` — any abbreviation works (`CEDA Q`, `CEDA QU`,
`CEDA QUEU` all reach it via the same unambiguous-prefix matcher;
CEDA carries no `QUIT` child so Q is unambiguous, and PF3 still
backs out of the menu) — opens the TS-queue list. Every TS queue
currently in the data store shows one row with its ITEMS / READS
/ WRITES / REWRT / LASTACC / STATUS counters — the same per-queue
stats `CEMT INQUIRE TS` renders for read-only inspection.

The one row action is `P` (purge). Type `P` (or `D` as an alias for
"delete") in a row's selector cell and press ENTER; a centred
confirmation overlay names the target queue and waits for `Y` to
commit the `DELETEQ TS`. Anything else cancels. Only one queue can
be marked per submit; mark more and the screen rejects the batch
with `Type P on only one queue at a time.`

Like the rest of CEDA, the QUEUES screen is admin-only. The
read-only counterpart — `CEMT INQUIRE TS` — remains available to
any signed-on operator.

---

## CLI utilities

| Command                           | Purpose |
|-----------------------------------|---------|
| `./bricks --conf=bricks.cnf`      | Run the server. |
| `./bricksload --help`             | Stress-test bricks; live dashboard + final report. See [Stress testing](#stress-testing--bricksload). |
| `./bricksconvert -h`              | Convert an IBM CICS BMS map source (`DFHMSD` / `DFHMDI` / `DFHMDF`) to the bricks map DSL. See [BMS conversion](#bms-conversion--bricksconvert). |
| `go run ./cmd/seed-customers`     | Idempotently load 250 sample customer records into the CUSTOMERS KSDS. |
| `go run ./cmd/brickspw <pw>`      | Print a bcrypt hash for a password. |
| `./add_brick_user.bash <u> <p> [groups]` | Add a user (refuses duplicates without `--update`). |
| `./add_brick_user.bash --update <u> <p> [groups]` | Replace an existing user's hash/groups. |
| `./build.bash`                    | Cross-compile `bricks`, `bricksload`, `brickspw` for linux/amd64, linux/386, linux/armv7, freebsd/amd64 into `bin/` (CGO_ENABLED=0). |

---

## API for embedders

```go
// 1. Configure.
cfg, _ := config.Load("bricks.cnf")

// 2. Wire dependencies.
users, _   := auth.LoadFile(cfg.UsersFile)
maps, _    := mapdsl.ParseDir(cfg.MapsDir)
table, _   := txn.LoadTable(cfg.TransactionsFile, cfg.RexxDir, cfg.CobolDir, cfg.ProgramCacheMB)
registry   := session.NewRegistry()
store, err := cics.NewStore(cfg.DataDir, registry)  // opens data/files.boltdb
if err != nil { log.Fatal(err) }
defer store.Close()
dispatch   := txn.NewDispatcher(table, maps, store, registry, cfg.Banner)

// 3. For each accepted connection, build a TCB and drive it manually.
tcb := &session.TCB{Conn: conn, Dev: dev, TermID: session.NextTermID(), …}
registry.AddTerminal(tcb)
defer registry.RemoveTerminal(tcb)

tn3270.ShowLogoSplash(conn, dev, "bricks.logo")
auth.RunCSSN(tcb, registry, users, cfg.MapsDir, cfg.EnforceSecureLogin, idle)

tcb.NextTransid = "MENU"
dispatch.Run(tcb)
```

For an `EXEC CICS` handler that talks to your own backend rather than the
disk-backed store, replace `cics.New(tcb, maps, store)` with an
implementation of `rexx.AddressHandler` and pass it via
`rexx.Options.Addresses`.

---

## Testing

```sh
go test ./...
```

Per-package coverage is small but focused:

* `mapdsl` — parser table tests.
* `tn3270` — render maps the on-disk `.map` files to `go3270.Field` slices.
* `auth` — bcrypt round-trip, malformed/duplicate rejection, unknown-user
  timing.
* `rexx` — lexer, IF/SELECT/DO, stems, PROCEDURE/EXPOSE, PARSE templates,
  ADDRESS commands, the canonical HELO sample end-to-end.
* `cics` — command parser, file store round-trip (DUPREC, NOTFND), TS queue
  append/rewrite/delete.

---

## Stress testing — `bricksload`

`cmd/bricksload` is a TN3270 stress tester that opens many concurrent
sessions, runs a scripted flow on each, and reports throughput,
latency percentiles, and bricks-side process metrics in real time.
It speaks the actual TN3270 protocol (telnet negotiation + 3270 data
streams) by reusing `web3270/client.go` — there's no JSON shortcut,
so what bricks sees from `bricksload` is indistinguishable from a
real `c3270` / `x3270` client.

### Building

```sh
./build.bash                               # produces bin/bricksload-<ver>-<os>-<arch>
go build -o bricksload ./cmd/bricksload    # quick local binary
```

### Quick start

```sh
# Full live dashboard (default), CUST query flow, 8 × 2,000 = 16,000 iterations.
./bricksload -clients=8 -iterations=2000 -flow=cust-q -refresh-ms=200

# Pipe-friendly: no dashboard, plain text report goes to a logfile.
./bricksload -no-dashboard -clients=50 -iterations=10000 -flow=splash > run.log

# JSON output, ready for jq / a downstream consumer.
./bricksload -out=json -clients=8 -iterations=500 -flow=cust-q | jq
```

### Flags

| Flag             | Default                            | Purpose |
|------------------|------------------------------------|---------|
| `-host`          | `localhost`                        | TN3270 host |
| `-port`          | `2300`                             | TN3270 port |
| `-clients`       | `10`                               | concurrent sessions |
| `-iterations`    | `100`                              | per-client iteration count |
| `-flow`          | `splash`                           | `splash` \| `cust-q` \| `qage` \| `prod` \| `cons` |
| `-userid`        | `""`                               | optional CSSN userid (sign-on once before iterations) |
| `-password`      | `""`                               | paired with `-userid` |
| `-warmup`        | `0`                                | iterations to discard from latency stats |
| `-timeout`       | `30s`                              | per-iteration wallclock cap (Go duration: `5s`, `250ms`…) |
| `-metrics-url`   | `http://localhost:9000/metrics`    | bricks `/metrics` endpoint URL (empty → skip server-side block) |
| `-poll-ms`       | `500`                              | `/metrics` poll cadence in milliseconds (≥50) |
| `-refresh-ms`    | `500`                              | dashboard redraw cadence in milliseconds (≥50) |
| `-no-dashboard`  | `false`                            | suppress live UI; print only the final report |
| `-out`           | `text`                             | `text` (live + final) \| `json` (skip dashboard, emit one JSON object) |

### Flows

* **`splash`** — one iteration is a complete connection lifecycle:
  dial → telnet negotiate → wait for splash → AID Enter → wait for
  prompt → close. Pure connection-handling benchmark; drives 0
  EXEC CICS verbs because the splash + blank-prompt screens are
  rendered Go-side (`tn3270.ShowLogoSplash` / `BlankPrompt`) and never
  enter REXX dispatch.

* **`cust-q`** — one iteration is one full `CUST → Q → 100` round-trip
  on an already-open session: send `CUST` ENTER → wait CUST1; send
  action `Q` + key `100` ENTER → wait CUST2 with the customer record;
  ENTER → wait CUST1 with `Query of 100 complete.` MSG; F12 → wait
  blank prompt. About 11 EXEC CICS dispatches per iteration (ASSIGN +
  SEND/RECEIVE pairs across CUST/CUST2 menus + LINK to CUSV + READ
  FILE + RETURN). Pass `-userid`/`-password` if `enforce_secure_login=yes`.

* **`qage`** — one iteration is `QAGE → birthdate → QAGR result` over
  the pseudo-conversational chain (`RETURN TRANSID('QAGR')` +
  `RECEIVE MAP` from prior SEND). 6 EXEC CICS dispatches per iteration:
  ASSIGN + SEND + RETURN in qage.rexx, ASSIGN + RECEIVE + SEND +
  RETURN in qagr.rexx. CEMT INQ TR shows the `QAGE` and `QAGR` invocation
  counts climbing in lockstep — handy for verifying the chain works.

* **`prod`** — TS queue producer. Drives the conversational `PROD`
  transaction: type the queue name + a per-iteration payload, ENTER,
  wait for the redisplayed map showing `Wrote item N`. 3 EXEC CICS
  dispatches per iteration (SEND + RECEIVE + WRITEQ TS). Hardcoded to
  queue `BENCHQ`; payloads are `c<client>-i<iter>` so items are
  uniquely traceable to the iteration that wrote them. Pair with
  `cons` (see below) running on a different bricksload invocation, or
  watch `CEMT I S` while it runs to see writes accumulate.

* **`cons`** — TS queue consumer. Drives the conversational `CONS`
  transaction: ENTER advances the implicit per-task cursor and reads
  the next item. 3 EXEC CICS dispatches per iteration (SEND + RECEIVE
  + READQ TS). Useful pattern: run `prod` to fill `BENCHQ`, then run
  `cons` to drain it. Iterations after the queue is exhausted still
  count as successes (the round-trip happened, the screen just shows
  `End of queue (ITEMERR)`); use `-iterations` close to the producer
  count to avoid a tail of empty reads.

  Example end-to-end TS workout:

  ```
  ./bricksload -flow=prod -clients=4 -iterations=5000   # ~20K items into BENCHQ
  ./bricksload -flow=cons -clients=4 -iterations=5000   # drain
  ```

  Watch `CEMT I S` between runs — `READS`, `WRITES`, and `LASTACC`
  for `BENCHQ` reflect what just happened.

### Live dashboard

Pure ANSI redraw — same approach as the `console.go` operator console.
Hidden cursor, in-place redraw every `-refresh-ms`, restored on exit.

```
bricksload — running                                    elapsed 19.7s   eta 22.3s
═══════════════════════════════════════════════════════════════════════════════
Target:      localhost:2300                Flow:    cust-q
Clients:     50    iter done 23,481   failed 2
Progress:    23,483 / 50,000 iter (47%)   total tx ≈ 258,313

Throughput:    last 5s   1,194 iter/s    run-to-date  1,191 iter/s
Latency 5s:    p50  18ms   p95  64ms   p99  121ms        max 287ms
Latency all:   p50  18ms   p95  63ms   p99  118ms

Errors:        timeout 2     screen_mismatch 0     connect_fail 0     proto 0

bricks process (sampled every 500ms via /metrics)
─────────────────────────────────────────────────────────────────────────────
  Heap   12.4 → 39.1 MB   peak 41.2 MB     Sys      45.1 → 78.4 MB
  Goroutines  7 → 105  peak 108            GC runs  Δ 18   last pause 7.4 ms
  CPU Δ        user 3.8 s   sys 0.4 s
  EXEC CICS    Δ 258,313   (harness 258,313 ✓)
  CICS txn/s   last 5s  1,194    avg  1,191
  EXEC CICS/s  last 5s 13,134    avg 13,101
  Per-verb Δ   SEND 70,449  RECEIVE 70,449  RETURN 46,966  ASSIGN 23,483  LINK 23,483

[Ctrl+C: graceful abort — clients drain, report prints]
```

The two rate lines (`CICS txn/s`, `EXEC CICS/s`) are computed from a
rolling history of `/metrics` snapshots:

* **`avg`** — `(latest.total − start.total) / Δuptime`. Stable
  run-to-date number.
* **`last 5s`** — pulls the oldest sample at least 5 s ago and
  computes `(latest − old) / Δt`. Reflects current load, not the
  warmup period.

The cross-check on the `EXEC CICS Δ` row (`harness X ✓ / ≈`) compares
`exec_cics.total` from `/metrics` against the harness's own iteration
count × `txPerIter()` for the active flow. ✓ means perfect match;
`≈` means within tolerance (counts shift slightly due to timed-out
iterations and the moment of the final snapshot).

### `/metrics` endpoint (`bricks/metrics`)

Bricks exposes a JSON snapshot at `http://<host>:<metrics_port>/metrics`
— the same numbers `CEMT → M` (MONITOR) shows on the 3270, but
machine-readable. Default port `9100`; gated on `start_metrics=yes`
(which is the default). Independent of `start_web3270` — turning the
browser frontend off does **not** turn metrics off. When both
`start_web3270=yes` and `start_metrics=yes` are set, the `/metrics`
route is mounted on both ports; either works.

```json
{
  "uptime_seconds": 3812.4,
  "memory":   { "heap_alloc_bytes": 12998144, "sys_bytes": 47185920, "heap_objects": 12345 },
  "gc":       { "num": 12, "last_pause_ns": 1234567, "total_pause_ns": 18234567 },
  "cpu":      { "user_seconds": 2.50, "sys_seconds": 0.30 },
  "runtime":  { "goroutines": 7, "num_cpu": 8, "go_version": "go1.25.0" },
  "registry": {
    "active_terminals": 2, "signed_on_users": 1,
    "active_transactions": 1, "known_files": 1,
    "accepts": 100, "rejects": 0, "auth_success": 50, "auth_failure": 3,
    "total_txn_run": 200, "total_txn_failed": 0
  },
  "exec_cics": {
    "total": 1234,
    "by_verb": { "SEND": 312, "RECEIVE": 312, "READ": 140, "ASSIGN": 80, "LINK": 33 }
  },
  "wallclock_unix": 1747250000
}
```

Counters (`accepts`, `total_txn_run`, `exec_cics.total`, …) are
**absolute since process start**. Memory and GC fields are
**snapshot values**. To compute rates, take two snapshots and divide
the delta by the time delta — that's exactly what `bricksload`'s
dashboard does.

`exec_cics.by_verb` maps verb name → count, sourced from
`cics.ExecPerVerb()`. Only verbs that have actually been dispatched
appear.

### Final report

When the run ends (clients drain or Ctrl+C), the final report prints
below the dashboard area. Same fields, plus `min/p50/p95/p99/max`
latency, the per-class error breakdown, and the bricks-process
deltas (heap start→end→peak, CPU Δ, GC Δ, CICS-txn rate,
EXEC-CICS-verb rate). `-out=json` emits all of this as a single JSON
object — see `cmd/bricksload/report.go::Report` for the schema.

### Operational notes

* **`max_conns_per_ip`** defaults to `8`. Running `-clients > 8` from
  one IP produces `connect_fail` rejections for the surplus
  connections. Raise it in `bricks.cnf` (e.g. `max_conns_per_ip=200`)
  and **restart bricks** — this key is read once at startup and is
  not on the live-reload list.
* **`enforce_secure_login=yes`** blocks every TRANSID until CSSN sign-on
  succeeds. The `cust-q` flow will fail at the auth gate unless you
  pass `-userid` / `-password` so the harness signs on once at session
  start before the iteration loop.
* The dashboard uses ANSI escape codes; `-no-dashboard` is required
  when redirecting stdout to a file or pipe (`-out=json` implies it).

---

## BMS conversion — `bricksconvert`

`cmd/bricksconvert` is a one-way converter from IBM CICS **BMS map
source** (the `DFHMSD` / `DFHMDI` / `DFHMDF` assembler macros) to
the bricks map DSL (the `MAP ... ENDMAP` format parsed by
`mapdsl/`). It is the recommended path for porting an existing
CICS application's screens onto bricks without rewriting every
panel by hand.

### Quick start

```bash
go build -o bricksconvert ./cmd/bricksconvert    # one-time build

# Mode 1 -- convert and write the result to a file.
./bricksconvert -o runtime/map/cust1.map  legacy/cust1.bms

# Mode 1b -- also emit a COBOL copybook alongside the .map.
./bricksconvert -o runtime/map/cust1.map -copy runtime/cobolcopy/cust1.cpy \
                legacy/cust1.bms

# Mode 2 -- "check-only" -- parse + verify with no output written.
#          Useful in CI: exits 0 iff every file converts cleanly.
./bricksconvert -check legacy/cust1.bms
```

The tool reads one BMS source file on the command line. Exactly
one of `-o <path>` or `-check` is required -- the converter
refuses to run without a declared destination so a misinvocation
can't dump the DSL onto stdout by accident.

### `-copy` — generate a matching COBOL copybook

Pair `-copy <path>` with `-o` to also write a COBOL copybook (`.cpy`)
mirroring the converted map's named fields. Each BMS map becomes a
`01 <mapname>.` group with one `05 <field> PIC X(N).` entry per
named field (or `PIC 9(N).` when the BMS source set `ATTRB=NUM`).
Unnamed fields (chrome / literals) are skipped; fields without a
`LENGTH=` are skipped with a `*> WARNING:` line in the header so the
operator notices.

The COBOL program then pulls the storage in with one line:

```cobol
       WORKING-STORAGE SECTION.
       COPY CUST1.
       ...
       EXEC CICS SEND MAP('CUST1') FROM(CUST1) END-EXEC.
```

`-copy` requires `-o` and refuses to combine with `-check` — the
copybook is a by-product of a real conversion, not a check-mode
emission. Misinvocations exit 2 with a specific message
(`bricksconvert: -copy requires -o`).

### Help, exit codes, colour

```
bricksconvert -h | -help
```

prints the concise usage block. Exit codes are operator-friendly:

| Exit | Meaning |
|---|---|
| `0` | Conversion (or `-check`) succeeded. |
| `1` | BMS syntax / semantic error in the source. The first offending line is shown with a dim source-line context row, file:line prefix, and the diagnostic in red. |
| `2` | Usage error (missing arguments, both `-o` and `-check` given), I/O failure, or an internal converter bug. |

Colour is on by default when stderr is a terminal; pipe through
`less` or set `--color=never` to suppress. Set `--color=always`
to force ANSI escapes on (useful when piping through colour-aware
viewers).

### Successful output

```
sample_bms.map: OK
  ─── BMS vs bricks ───────────────────────
                       BMS    bricks
  statements           34        34
  mapsets               1         -
  maps                  1         1
  size              24x80     24x80
  fields (display)     24        24
  inputs                7         7
  stops                 0         0
  cursor target    CUSTID    CUSTID
  warnings              0         -
  elapsed          0s.0ms

  Wrote runtime/map/cust1.map.
  runtime/map/cust1.map passes bricks parser.
```

The grid shows side-by-side counts so an operator can confirm
the conversion preserved every logical element of the source.
Rows that match are green; mismatches are red. The
`bricks parser` line is the **verification step**: bricksconvert
re-reads the just-written file from disk and runs it through
`mapdsl.ParseReader` (the same parser the bricks runtime uses on
every map at load time). A "passes" confirmation in green tells
you the file is immediately deployable.

### Coverage: 100% of BMS, lossy where bricks doesn't model

The parser accepts every documented BMS macro and every
attribute. Where bricks's map DSL can't represent a BMS feature
exactly, the converter emits a `* WARNING: ...` comment line into
the output AND bumps the `warnings` counter in the summary so
the operator can hand-finish the result. The current warning-
producing features are `PICIN=`, `PICOUT=` (picture-editing
clauses), `OCCURS=` (array fields), `GRPNAME=` (field groups),
`OUTLINE=` (box / underline / overline), `ATTRB=DET`
(light-pen detection), and any unrecognised `ATTRB=` token.

### Strict BMS column rules

The lexer enforces IBM's canonical column rules: the
continuation marker `X` must sit at exactly column 72. Lines
where the operator placed `X` at the end of the operand list
(say col 65 or 66) are rejected with a precise diagnostic:

```
sample.bms:1: BMS parse error: continuation marker `X` at col 66; BMS requires col 72 (pad the body to 71 chars).
  source line 1: ORDMAPS  DFHMSD TYPE=MAP,MODE=INOUT,LANG=COBOL,                  X
```

The other "wire format" subtleties (continuation lines resume
at col 16; cols 73-80 are sequence numbers when the line is
exactly 80 chars; comment lines start with `*` in col 1; the
`'don''t'` doubled-quote convention; adjacent string literal
concatenation for long `INITIAL=` values broken across multiple
continuation lines) are all handled automatically. See
`cmd/bricksconvert/bms_lex.go` and `bms_parse.go` for the full
grammar.

### One BMS file → one or more bricks DSL maps

A BMS mapset can hold multiple `DFHMDI`-bounded maps; the
converter emits one `MAP ... ENDMAP` block per map, in source
order, into a single output file. The bricks map catalogue
(`runtime/map/*.map`) accepts that shape natively -- no need
to split the output into one file per map.

---

## Performance and security hardening

### Parsed-program cache

Every TRANSID dispatch and every `EXEC CICS LINK PROGRAM(...)` resolves
through `Table.LoadProgram(tx)` for REXX or `Table.LoadCobolProgram(tx)`
for COBOL (`txn/transactions.go`); both share a single cache that holds
parsed `*rexx.Program` and `*cobol.Program` ASTs keyed by file path and
`mtime`. The cache is two tiers:

- **L1** (`txn/l1cache.go`) — a 128-entry LRU of already-decoded AST
  pointers. Hits are essentially free: a map lookup plus a list move,
  no gob, no memcpy, no allocation. This is the hot path for the
  working set of busy transactions and matches the speed of the
  original pointer cache.
- **L2** (`txn/programcache.go`) — the byte-budget tier, sized by
  `program_cache` in `bricks.cnf`. AST blobs are gob-encoded and
  LRU-evicted when the slab fills. The slab itself is a pointer-free
  `[]byte`, so Go's garbage collector scans it in O(1) regardless of
  how many programs it contains; the AST bytes inside are never
  visited by the collector.

Both tiers are 8-way sharded internally — keyed by FNV-1a hash of the
program's file path, each shard owns its own mutex, map, LRU list, and
(for L2) byte slab. Dispatches contend only when they happen to hash to
the same stripe, which under a normal mix of TRANSIDs spreads the
contention across shards rather than serializing every cache touch
through one lock. The capacities quoted above are totals: the default
128-entry L1 is eight 16-entry LRUs, and a default 4 MB L2 is eight
512 KB slabs, each with its own bump pointer and compaction. Hit and
miss counters on each shard are `atomic.Uint64`, so `CEMT MONITOR`
aggregates the totals without taking any shard lock.

On a miss, the dispatcher parses from disk, encodes into L2, and
populates L1 with the freshly-parsed AST. On an L1 miss but L2 hit, the
gob-decoded AST is promoted to L1 so subsequent dispatches skip the
decode. Both tiers store `interface{}` values and dispatch on the
concrete type at read time, so REXX and COBOL programs share the same
LRU budget — a busy COBOL workload can fill the cache just as a busy
REXX workload can. Edits to a program file are picked up on the next
dispatch automatically via `mtime` mismatch eviction.

`CEMT MONITOR` (`CEMT M`) renders live cache counters: cumulative
hits/misses per tier, the per-refresh-interval hit ratio, L1 entry
occupancy (`used/max`), and L2 byte occupancy (`used/cap MB (pct%)`).
Watching the L1 hit% climb toward 100% on a hot workload is the
quickest sign the working set is fitting in the decoded tier.

Both tiers can also be resized at runtime from `CEMT PERFORM
PROGRAMCACHE` (`CEMT P C`). The screen shows L1/L2 hit and miss totals
in two views — since process start (across every resize) and since the
last resize — and offers two writable input fields: new L1 entry count
(32..512) and new L2 size in MB (1..16384). Pressing PF5 swaps in
freshly-sized caches; in-flight dispatches finish against the old
instances. The change is runtime-only — `bricks.cnf` is not modified,
so the value reverts on restart unless the operator edits the file.

### Resource-name validation

FILE and QUEUE names that flow from a REXX program into the on-disk store
are validated by `validResourceName` against `^[A-Za-z0-9_-]{1,64}$`
before any path is composed (`cics/store.go`). Invalid names yield
`INVREQ` with a clean error string. Without this, `WRITE FILE('../tmp/X')`
would have escaped `data_dir` because `filepath.Join` collapses `..`
segments.

### Idle read deadlines on prompt screens

The top-level prompt loop sets
`conn.SetReadDeadline(now + idle_timeout_secs)` **only while
`sess.Authenticated` is false** (`main.go::handle`). That's the
half-open-handshake guard — a peer that completes telnet
negotiation but never signs on gets dropped after the deadline,
freeing its `max_conns_per_ip` slot. The CSSN sign-on flow
inherits the same deadline so a half-finished sign-on times out
too. A signed-on session has **no** read deadline: the BlankPrompt
read blocks indefinitely, and the only way for the server to drop
the connection is the operator's TCP close or an explicit
`CSSF DISC` / `DISCONNECT` / `GOODNIGHT`. `CSSF LOGOFF` clears
`sess.Authenticated`, so the deadline resumes on the next loop
iteration.

### CSSF LOGOFF cleanup

`CSSF LOGOFF` calls `Registry.DetachUserFromTerminal(tcb)` which severs
the UCB↔TCB link and drops the UCB if the terminal set is empty. The
prior session no longer leaves an orphan UCB visible in `CEMT → I → C → U`,
and a subsequent `CSSN` for a different userid does not create a
duplicate UCB.

### Registry locking

The session registry no longer uses a single global `RWMutex`. `tcbs`,
`ucbs`, and `fcbs` each have their own per-collection mutex; `txcbs`
moved to `sync.Map` with an `atomic.Int64` count, so `BeginTxn` /
`EndTxn` are lock-free in the steady state. CEMT snapshots no longer
block transaction starts. Lock order when more than one is needed:
`tMu` → `uMu` → per-block locks (`u.mu`, `t.mu`).

### Lock-free EXEC CICS metrics

Per-verb counters (`cics.ExecPerVerb`) are stored in a `sync.Map` of
`*atomic.Int64`. The hot path is lock-free for any verb already seen;
only the first sighting of a new verb pays a `LoadOrStore`. The
EXEC CICS command parser pre-allocates its token slice
(`make([]ctok, 0, 16)`) so the dispatch loop avoids slow-start growth.

### Bounded browse reconciliation

`READNEXT FILE` skips records that were deleted by a concurrent
transaction between the `STARTBR` snapshot and the read. The skip is
implemented as a bounded forward loop over the snapshot
(`cics/files.go::readNextFile`), replacing an unbounded recursion, so no
amount of in-flight deletes can blow the goroutine stack.

## Independent Bricks Apps

Third-party applications and projects built on top of bricks. Send a
PR to add yours.

| Project | Description | Author |
|---|---|---|
| [Minette-Codes/Bricks](https://github.com/Minette-Codes/Bricks) | App built on the bricks transaction server. | [Minette-Codes](https://github.com/Minette-Codes) |

![BRICKS](bricks.png)
