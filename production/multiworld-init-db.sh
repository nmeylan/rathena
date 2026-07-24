#!/usr/bin/env bash
# Set up ONE world for the shared-login multi-world layout: its database, the
# rAthena schema, and its sex='S' interserver login account. Run once per world
# (and any time you add a world); re-running is idempotent.
#
#   ./multiworld-init-db.sh --env-file .env.world-a
#   ./multiworld-init-db.sh --env-file .env.world-b
#
# Reads DB credentials from the login env file (default .env, override with
# --login-env) and the world's parameters from --env-file. On the first run it
# also creates the shared `accounts` DB (login table) used by every world.
#
# Requires the login stack to be up first (db must be healthy):
#   docker compose -f docker-compose.login.yml --env-file .env up -d --build
set -euo pipefail

DB_CONTAINER="${DB_CONTAINER:-rathena-db}"
LOGIN_ENV=".env"
WORLD_ENV=""
SQLDIR="$(cd "$(dirname "$0")/../sql-files" && pwd)"

usage() {
    cat >&2 <<EOF
usage: $(basename "$0") --env-file <world env> [--login-env <login env>]

  --env-file    per-world env file (e.g. .env.world-a) providing:
                  WORLD_DB, ACCOUNT_ID (0-4), SERVER_USERID, SERVER_PASSWORD
  --login-env   login stack env file with DB creds (default: .env) providing:
                  DB_ROOT_PASSWORD, DB_PASSWORD [, DB_USER, DB_NAME]
EOF
}

# ---- args ----
while [ $# -gt 0 ]; do
    case "$1" in
        --env-file)  WORLD_ENV="${2:-}"; shift 2 ;;
        --login-env) LOGIN_ENV="${2:-}"; shift 2 ;;
        -h|--help)   usage; exit 0 ;;
        *) echo "error: unknown argument '$1'" >&2; usage; exit 1 ;;
    esac
done

[ -n "$WORLD_ENV" ] || { echo "error: --env-file is required" >&2; usage; exit 1; }
[ -f "$WORLD_ENV" ] || { echo "error: world env file not found: $WORLD_ENV" >&2; exit 1; }
[ -f "$LOGIN_ENV" ] || { echo "error: login env file not found: $LOGIN_ENV (use --login-env)" >&2; exit 1; }

# ---- load env files (values assigned literally; never executed) ----
load_env() {
    local file="$1" line key val
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"                       # tolerate CRLF files
        case "$line" in ''|'#'*) continue ;; esac
        [ "$line" = "${line#*=}" ] && continue     # no '=' -> not a var line
        key="${line%%=*}"; val="${line#*=}"
        export "${key// /}=$val"
    done < "$file"
}
load_env "$LOGIN_ENV"
load_env "$WORLD_ENV"

# ---- validate ----
: "${DB_ROOT_PASSWORD:?set DB_ROOT_PASSWORD in $LOGIN_ENV}"
: "${DB_PASSWORD:?set DB_PASSWORD in $LOGIN_ENV}"
DB_USER="${DB_USER:-ragnarok}"
ACCOUNTS_DB="${DB_NAME:-accounts}"

: "${WORLD_DB:?set WORLD_DB in $WORLD_ENV}"
: "${ACCOUNT_ID:?set ACCOUNT_ID (0-4) in $WORLD_ENV}"
: "${SERVER_USERID:?set SERVER_USERID in $WORLD_ENV}"
: "${SERVER_PASSWORD:?set SERVER_PASSWORD in $WORLD_ENV}"

case "$ACCOUNT_ID" in ''|*[!0-9]*) echo "error: ACCOUNT_ID must be an integer 0-4" >&2; exit 1 ;; esac
{ [ "$ACCOUNT_ID" -ge 0 ] && [ "$ACCOUNT_ID" -le 4 ]; } \
    || { echo "error: ACCOUNT_ID must be 0-4 (source: #define MAX_SERVERS 5)" >&2; exit 1; }

# ---- helpers ----
mysql() { docker exec -i "$DB_CONTAINER" mariadb -uroot -p"$DB_ROOT_PASSWORD" "$@"; }
load()  { docker exec -i "$DB_CONTAINER" mariadb -uroot -p"$DB_ROOT_PASSWORD" "$1" < "$2"; }

table_exists() { # <db> <table>  -> exit 0 if present
    local n
    n=$(mysql -N -B -e \
        "SELECT COUNT(*) FROM information_schema.tables \
         WHERE table_schema='$1' AND table_name='$2';")
    [ "${n:-0}" -gt 0 ]
}

ensure_db() { # <db>  create + grant app user (idempotent)
    mysql -e "CREATE DATABASE IF NOT EXISTS \`$1\` CHARACTER SET utf8mb4;
              GRANT ALL PRIVILEGES ON \`$1\`.* TO '$DB_USER'@'%';
              FLUSH PRIVILEGES;"
}

# ---- shared accounts DB (created once; skipped on later worlds) ----
echo ">> ensuring shared accounts DB '$ACCOUNTS_DB' (user '$DB_USER')"
ensure_db "$ACCOUNTS_DB"
if table_exists "$ACCOUNTS_DB" login; then
    echo "   login table already present — skipping schema load"
else
    echo "   loading schema (main.sql)"
    load "$ACCOUNTS_DB" "$SQLDIR/main.sql"
fi
# The login server logs to `loginlog`, which lives in logs.sql (a world-log
# file). The accounts DB only gets main.sql, so create just that one table here
# — the other logs.sql tables are map-server logs and belong in world DBs.
if table_exists "$ACCOUNTS_DB" loginlog; then
    echo "   loginlog table already present"
else
    echo "   creating loginlog table (from logs.sql)"
    awk '/CREATE TABLE IF NOT EXISTS `loginlog`/{f=1} f{print} f&&/;[[:space:]]*$/{exit}' \
        "$SQLDIR/logs.sql" | mysql "$ACCOUNTS_DB"
fi

# ---- this world's DB ----
echo ">> setting up world DB '$WORLD_DB'"
ensure_db "$WORLD_DB"
if table_exists "$WORLD_DB" char; then
    echo "   schema already present ('char' table) — skipping schema load"
else
    echo "   loading schema (main.sql + logs.sql)"
    load "$WORLD_DB" "$SQLDIR/main.sql"
    load "$WORLD_DB" "$SQLDIR/logs.sql"
fi

# ---- interserver (sex='S') account: account_id is this world's login slot ----
echo ">> registering interserver account: account_id=$ACCOUNT_ID userid='$SERVER_USERID'"
existing=$(mysql -N -B "$ACCOUNTS_DB" -e "SELECT userid FROM login WHERE account_id=$ACCOUNT_ID;" || true)
if [ -n "$existing" ] && [ "$existing" != "$SERVER_USERID" ]; then
    echo "   WARNING: slot $ACCOUNT_ID currently belongs to '$existing'; overwriting with '$SERVER_USERID'" >&2
fi
mysql "$ACCOUNTS_DB" -e \
    "REPLACE INTO login (account_id,userid,user_pass,sex,email)
     VALUES ($ACCOUNT_ID,'$SERVER_USERID','$SERVER_PASSWORD','S','athena@athena.com');"

echo ">> done: world DB '$WORLD_DB', login slot $ACCOUNT_ID -> '$SERVER_USERID'."
echo "   ('$SERVER_USERID'/password must match userid/passwd in this world's inter_conf.txt)"
