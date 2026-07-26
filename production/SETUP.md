# rAthena Server Setup (Docker)

One **login** server + a shared **accounts** database, fronted by **HAProxy**,
serving up to 5 **worlds**. Each world is its own char + map + database; players
log in once and pick a world on the character-select screen. Every server runs
the same `rathena:prod` image — worlds differ only by env file, config, DB, and
ports.

```
                internet
                   │
             HAProxy (edge, publishes ports)
   6900 login ─────┼───── 61x1 char / 51x1 map  (per world)
                   │
   ── docker net rathena-nmey_default ──────────────────
   login   db(MariaDB)   world-a char+map   world-b char+map  …
         ├ accounts DB      └ world_a DB        └ world_b DB
         ├ world_a DB
         └ world_b DB
```

**Rules (enforced by the source):**
- Max **5 worlds** (`#define MAX_SERVERS 5`).
- Each world needs a unique **login slot** `ACCOUNT_ID` in **0–4**, its own
  `sex='S'` interserver account, and its own database.
- Compile flags (`--enable-packetver`, `--enable-prere`) are baked into the
  image; all worlds share them. Different client/renewal mode ⇒ separate image.

Everything runs from `production/` (at the repo root). Per-world facts live in one file,
`.env.world-<id>` (generated), which drives the env, the DB, and the config.

---

## First-time setup (once)

**1. Credentials.** Set strong passwords in `.env`, then render the login
config from it (the DB password flows in automatically — no hand-editing):

```bash
cp .env.login.example .env
$EDITOR .env                                    # DB_ROOT_PASSWORD + DB_PASSWORD
./render-assets.sh --login                      # -> asset-login/inter_conf.txt
```

**2. Get the `rathena:prod` image.** Compiling it needs **~3 GiB of RAM for a
single g++ process** — `src/map/skill.cpp` is a unity build of ~1200 skill
sources and `-j` cannot split it ([why](#build-reference)). So pick one:

*Option A (recommended) — compile on a machine with cores and RAM, ship the
image.* Only the login stack has a `build:` block; everything else refers to
`rathena:prod` by name, so the VPS never needs a compiler:

```bash
# on the build machine, from production/ — the context is the repo root (..)
docker build -t rathena:prod -f Dockerfile.prod ..
docker save rathena:prod | zstd -3 | ssh VPS 'zstd -d | docker load'
```

*Option B — compile on the VPS.* On a 4 GB host this **needs swap first**, or the
OOM killer stops the build hours in (`dmesg | grep -i oom`):

```bash
fallocate -l 6G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab   # survive reboot

docker compose -f docker-compose.login.yml --env-file .env build --build-arg MAKE_JOBS=2
```

Then start db + login (with option A, this is the only command you run here):

```bash
docker compose -f docker-compose.login.yml --env-file .env up -d
```

**3. Start HAProxy + open the login port.** The shipped `haproxy/haproxy.cfg`
has only the `login` frontend; per-world blocks are added by `new-world.sh`
(next section). Backends for not-yet-running worlds show as down until up.

```bash
docker compose -f haproxy/docker-compose.yml up -d
ufw allow 6900/tcp                              # + your SSH port
```

Now add at least one world ↓ (the DB is created on the first world's init).

---

## Add a world (repeat, up to 5 total)

Nothing to hand-edit — the script also wires up HAProxy. Example: world `a`.

**1. Generate its env file + HAProxy config.** Accepts defaults (next free slot,
`world_a`, `s1`, ports `6121/5121`); press Enter through, or override at the
prompts. It writes `.env.world-a` **and** upserts world `a`'s block into
`haproxy/haproxy.cfg` + its ports into `haproxy/docker-compose.yml` (idempotent;
pass `--no-haproxy` to skip):

```bash
./new-world.sh a
```

**2. Render its config** (`asset-world-a/{inter,char,map,battle}_conf.txt` plus
`asset-world-a/npc/`, see [Per-world NPCs](#per-world-npcs)):

```bash
./render-assets.sh --env-file .env.world-a
```

**3. Create its database + interserver account** (also creates the shared
`accounts` DB on the very first world; idempotent):

```bash
./multiworld-init-db.sh --env-file .env.world-a
```

**4. Bring the world up, apply the new HAProxy ports + firewall:**

```bash
docker compose -f docker-compose.world.yml --env-file .env.world-a up -d
docker compose -f haproxy/docker-compose.yml up -d      # recreates to bind new ports
ufw allow 6121,5121/tcp
```

**5. Verify:**

```bash
docker compose -f docker-compose.login.yml logs login | grep -i "char-server"
# -> "Connection of the char-server 'WorldA' accepted."
```

Then point a client at `PUBLIC_IP:6900` — the world appears on world-select.

---

## Per-world level cap

`world-highrate` runs base level 300; every other world stays at 99, on the same
image.

**The compile-time part is shared.** `MAX_LEVEL` (`src/map/map.hpp:78`) is
`300` — raised from rAthena's default 275. It is a ceiling for *every* world on
`rathena:prod`; changing it means rebuilding the image. What differs per world is
data.

**The per-world part is data.** Every db Footer import chain ends with
`db/import/<file>.yml` ("Finally, import custom information"), so that directory
is the override point, and each world bind-mounts its own at
`/rathena/db/import`. Two files decide the cap:

- `job_stats.yml` — `MaxBaseLevel` plus `BaseExp` rows. A level with no `BaseExp`
  row cannot be left: `pc_nextbaseexp` returns 0 and `pc_checkbaselevelup` bails
  on `!next`. This, not `MAX_LEVEL`, is what actually holds the other worlds at
  99. `MaxBaseLevel` must be in the **same node** as the new rows — the parser
  reads it first and skips any `BaseExp` row above it (`src/map/pc.cpp:14053`).
- `statpoint.yml` — `Points` is **cumulative**, and the stock pre-renewal table
  is flat at 4545 from level 200 up, so `pc_gets_status_point` (`next - current`)
  returns **0** for every level past 200. Without an override a raised cap grants
  no stat points.

Generate both with the script rather than by hand — it reads the stock tables for
its anchors, so it cannot drift from `db/pre-re/*.yml`:

```bash
./gen-level-tables.py --world highrate --max-level 300   # --dry-run to preview
./render-assets.sh --env-file .env.world-highrate
```

### Stat caps

Set `MAX_PARAMETER=200` in `.env.world-highrate`. Without it the cap stays 99,
and since it costs 3768 points to take all six stats to 99 while the stock table
hands out 4545 by level 200, stats saturate at **base level 181** — every level
past that is cosmetic no matter how high the level cap goes.

There are **nine** parameter caps, applied per class family by
`JobDatabase::loadingFinished` (`src/map/pc.cpp:14338`); `pc_maxparameter` then
reads `job->max_param[]`, which those defaults fill in. Three are reachable in
pre-renewal, and `battle_conf.txt` renders all three:

| token | stock | applies to |
| --- | --- | --- |
| `MAX_PARAMETER` | 99 | normal 1st/2nd jobs, plus Ninja / Gunslinger / Star Gladiator / Soul Linker |
| `MAX_TRANS_PARAMETER` | 99 | transcendent (`JOBL_UPPER`) — Lord Knight, High Priest, … |
| `MAX_BABY_PARAMETER` | 80 | baby jobs |

`MAX_TRANS_PARAMETER` defaults to whatever `MAX_PARAMETER` is set to, because
setting only `max_parameter` would leave the transcendent jobs — the actual
pre-renewal endgame — capped at 99. The remaining six
(third / fourth / extended / summoner / trait) are renewal-only here.

### Allocation cost

`PC_STATUS_POINT_COST` (`src/map/pc.cpp`) has a second branch above 99: cost
grows by 4 every 5 points instead of 1 every 10, so `low=150` costs 51 instead of
16 and `low=199` costs 87 instead of 21. The branch is continuous at the boundary
(99 and 100 both cost 11) and **sub-100 is bit-for-bit stock**, so worlds capped
at 99 can never reach it and their allocation costs are unchanged. It is
compile-time, hence shared by every world on the image — which is exactly why the
split is at 100.

Consequence at cap 200: one stat costs 5539 points, all six cost 33,234, and the
generated table grants 9795 by level 300. A max-level character can take **one**
stat to 200 and still have 4256 points — roughly the other five at 99. The cap is
build-defining rather than something everyone maxes out. `gen-level-tables.py`
prints this budget on every run; retune with `--stat-formula` or `--max-level`.

**Exp ceiling.** `src/config/const.hpp` sets
`MAX_EXP = PACKETVER >= 20170830 ? INT64_MAX : INT32_MAX`, and this image builds
at packetver 20111102 — so per-level exp must stay under **2,147,483,647**. The
generator enforces it and defaults to a 2,000,000,000 ceiling at the last level.
That is also why the transcendent curve converges on the normal one at high
level: both have to fit under the same int32 roof, so trans cannot stay 3× above
it. Raising the ceiling needs a newer packetver, i.e. a different image.

Job levels (`MaxJobLevel` 10/50/70/99) are deliberately untouched.

Verify after restart:

```bash
docker compose -f docker-compose.world.yml --env-file .env.world-highrate logs map \
  | grep -iE "job_stats|statpoint|Failed to open|exceeds"
```

---

## Per-world NPCs

All worlds run the same `rathena:prod` image, so every world *has* every script
under `npc/`. What differs is which ones each world **loads**.

Each world already bind-mounts `asset-world-<id>/` at `/rathena/conf/import`, so
`conf/import/npc/scripts_world.conf` names a different file in every world.
`npc/scripts_custom.conf` ends by importing exactly that path, making it the
last entry in the script chain — so a world can both add and remove relative to
everything above it. Sources are tracked in `production/world-npc/<id>/` and
copied into the mount by `render-assets.sh`; worlds with no such directory fall
back to `world-npc/_default/` and load nothing extra.

Give world `a` its own NPCs:

```bash
mkdir -p world-npc/a
cp world-npc/_default/scripts_world.conf world-npc/a/
$EDITOR world-npc/a/scripts_world.conf
./render-assets.sh --env-file .env.world-a
```

Only `npc:`, `delnpc:`, `import:` and `//` comments are valid in that file —
anything else logs `Unknown setting`. Paths are relative to `/rathena`:

```
// Enable a script that ships in the image but is off for everyone else.
npc: npc/custom/etc/lottery.txt

// Drop a script that npc/scripts_custom.conf enables for every world.
delnpc: npc/custom/etc/mvp_arena.txt

// A script that lives in world-npc/a/ alongside this file.
npc: conf/import/npc/pvp_arena.txt
```

Then restart the world, or just `@reloadscript` in-game — the chain is re-read.

**Put actively-edited world scripts in `world-npc/<id>/`, not `npc/`.** They
arrive via the bind mount, so a change needs only `@reloadscript`. Anything
under `npc/` is inside `COPY . /rathena`, so editing it invalidates that layer
and forces a **full map-server recompile** (the ~3 GiB `skill.cpp` unity build —
see [Build reference](#build-reference)). Keep `npc/` for stable shared scripts.

**Do not** put per-world `npc:` lines in `conf/import/map_conf.txt` instead.
`map_conf.txt` does accept them at boot (`src/map/map.cpp:4170`), but
`@reloadscript` calls `map_reloadnpc(true)`, which clears the list and re-reads
*only* the `scripts_main.conf` chain — those NPCs vanish on the first reload.

For *same NPC, different behavior* rather than present/absent, one script that
branches is simpler than two files: each world has its own database, so a
`$world$` global set in an `OnInit` from that world's list is enough to gate on.

**Heads-up on the mount:** it replaces `/rathena/conf/import` *entirely*, so the
image's own `conf/import/` files (`groups.yml`, `atcommands.yml`,
`inter_server.yml`, `log_conf.txt`, …) are invisible inside a world container —
they log a "failed to open" error at boot and their settings do not apply. Today
those are the untouched `import-tmpl` defaults, so nothing is lost; if you ever
add a custom group or atcommand there, copy it into `asset-world-template/` (or
each world's mount) or it will silently have no effect.

---

## Build reference

Background for the build in first-time setup step 2 — nothing here needs running.

**Why it costs ~3 GiB.** The map server does not parallelise: `src/map/skill.cpp`
`#include`s `skills/skill_factory.cpp`, which pulls all ~1200 skill sources into a
**single** translation unit, so it is one `g++` process that `-j` cannot split.
Measured on that one file, on a fast desktop core:

| CXXFLAGS | wall | peak RSS |
| --- | --- | --- |
| `-g -O2` (autoconf default) | 52 s | 3.7 GiB |
| `-O2` (what we pass) | 36 s | 3.1 GiB |
| `-O1` | 27 s | 2.9 GiB |

On a 4 GB box that one process, plus MariaDB's ~400 MB, does not fit — hence the
swap file. `docker compose down` before compiling buys back the MariaDB share.

**Build args** (`production/Dockerfile.prod`), all settable with `--build-arg`:
- `MAKE_JOBS` (default `1`) — compile jobs. Every job beyond the first needs its
  own headroom on top of the ~3 GiB peak, so 4 GB hosts want `1`–`2`. `up --build`
  takes no `--build-arg`, which is why step 2 and *Operations* build separately.
- `BUILDER_CXXFLAGS` (default `-O2`) — no `-g`: autoconf would default to
  `-g -O2`, costing ~650 MiB and ~45% more wall time for symbols the runtime
  stage discards. Drop to `-O1` to shave another ~200 MiB.
- `BUILDER_CONFIGURE` — packetver / renewal mode, pinned in
  `docker-compose.login.yml`. All worlds share it; changing it means a new image.

**`.dockerignore`** (repo root) cuts the uploaded context from ~800 MB to ~90 MB —
`.git` alone is ~400 MB, and host build output (a `-g` `map-server` is 90 MB) is
useless in a musl image. It also keeps `production/` out, so editing an `.env` or
this file no longer invalidates the `COPY . /rathena` layer and forces a full
recompile.

---

## Operations

```bash
# Update after a code change (rebuild image, restart everything).
# Separate build step because `up --build` takes no --build-arg, so it would
# compile with MAKE_JOBS=1 — see "Build reference".
docker compose -f docker-compose.login.yml --env-file .env build --build-arg MAKE_JOBS=2
docker compose -f docker-compose.login.yml --env-file .env up -d
docker compose -f docker-compose.world.yml --env-file .env.world-a up -d
docker compose -f haproxy/docker-compose.yml up -d

# Logs
docker compose -f docker-compose.world.yml --env-file .env.world-a logs -f

# Back up every database
for db in accounts world_a world_b; do
  docker exec rathena-db sh -c \
    "mariadb-dump -uroot -p\"$DB_ROOT_PASSWORD\" $db" > "backup-$db-$(date +%F).sql"
done

# Stop everything
docker compose -f haproxy/docker-compose.yml down
docker compose -f docker-compose.world.yml --env-file .env.world-a down
docker compose -f docker-compose.login.yml down
```

**Change a config later:** edit `.env.world-<id>` (or `asset-world-template/`),
re-run `./render-assets.sh --env-file .env.world-<id>`, then restart that world.
**Change DB creds:** update `.env`, re-render everything (`./render-assets.sh
--login` and each world), restart.
**Change a world's NPCs:** edit `world-npc/<id>/`, re-render, then
`@reloadscript` — see [Per-world NPCs](#per-world-npcs). No image rebuild.

**Local (non-Docker) dev server:** `npc/scripts_custom.conf` imports
`conf/import/npc/scripts_world.conf`, which in production comes from the world's
bind mount. A local run has no mount, so create the stub once (`conf/import` is
gitignored, so this stays local) or map-server logs a missing-import error on
every boot:

```bash
mkdir -p conf/import/npc && touch conf/import/npc/scripts_world.conf
```

---

## Database accounts (MySQL / MariaDB)

The app user (`DB_USER`, default `ragnarok`) is created from `.env` on first boot
and granted access to `accounts` + each world DB by `multiworld-init-db.sh` — no
manual step needed. Use the commands below to add an extra account, e.g. a
read-only reporting user.

Open a root shell in the DB container (3306 is not published, so MariaDB is only
reachable from inside the docker network):

```bash
docker exec -it rathena-db mariadb -uroot -p     # password = DB_ROOT_PASSWORD
```

Create a least-privilege account and grant only the databases it needs:

```sql
CREATE USER 'reporter'@'%' IDENTIFIED BY 'long-random-secret';
GRANT SELECT ON accounts.* TO 'reporter'@'%';    -- read-only
GRANT SELECT ON world_a.* TO 'reporter'@'%';
SHOW GRANTS FOR 'reporter'@'%';                  -- verify
```

Manage it later:

```sql
ALTER USER 'reporter'@'%' IDENTIFIED BY 'new-secret';   -- rotate password
DROP USER 'reporter'@'%';                                -- remove
```

Notes:
- The identity is `'user'@'host'`. `'%'` (any host) is fine here **only because
  3306 is unpublished** — access is limited to the private `rathena-nmey_default`
  network. If you ever expose the port, scope the host (e.g. `'reporter'@'172.%'`).
- Grant the minimum: `SELECT` for read-only, `SELECT,INSERT,UPDATE,DELETE` for a
  read-write app user. Don't use `root` from an application or add `WITH GRANT
  OPTION`. `CREATE USER`/`GRANT` apply immediately (no `FLUSH PRIVILEGES` needed).
