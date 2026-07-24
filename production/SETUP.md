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

**2. Bring up the login stack** (builds the shared image, starts db + login):

```bash
docker compose -f docker-compose.login.yml --env-file .env up -d --build
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

**2. Render its config** (`asset-world-a/{inter,char,map}_conf.txt`):

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

## Operations

```bash
# Update after a code change (rebuild image, restart everything)
docker compose -f docker-compose.login.yml --env-file .env up -d --build
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
