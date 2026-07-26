#!/usr/bin/env bash
# Render rAthena import configs from templates + env, so credentials/params live
# in one place (the env files) instead of being hand-copied into config.
#
#   ./render-assets.sh --login                     # -> asset-login/inter_conf.txt (from .env)
#   ./render-assets.sh --env-file .env.world-a     # -> asset-world-a/{inter,char,map}_conf.txt
#
# DB creds come from the login env file (default .env, override --login-env);
# world params come from --env-file. Re-run any time env or a template changes.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LOGIN_TEMPLATE_DIR="$HERE/asset-login-template"
WORLD_TEMPLATE_DIR="$HERE/asset-world-template"
WORLD_NPC_DIR="$HERE/world-npc"
WORLD_DBIMPORT_DIR="$HERE/world-db"
DB_IMPORT_TMPL="$HERE/../db/import-tmpl"
LOGIN_ENV=".env"
WORLD_ENV=""
MODE=""
TEMPLATE_OVERRIDE=""
FORCE=0

usage() {
    cat >&2 <<EOF
usage: $(basename "$0") (--login | --env-file <world env>) [options]

  --login              render asset-login/inter_conf.txt from .env
  --env-file <file>    render a world's {inter,char,map}_conf.txt from that env file
  --login-env <file>   env file with DB creds (default: .env)
  --template-dir <dir> override the template source for the active mode
  --force              overwrite without the "updating existing" note
EOF
}

# ---- args ----
while [ $# -gt 0 ]; do
    case "$1" in
        --login)        MODE="login"; shift ;;
        --env-file)     MODE="world"; WORLD_ENV="${2:-}"; shift 2 ;;
        --login-env)    LOGIN_ENV="${2:-}"; shift 2 ;;
        --template-dir) TEMPLATE_OVERRIDE="${2:-}"; shift 2 ;;
        --force)        FORCE=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        *) echo "error: unknown argument '$1'" >&2; usage; exit 1 ;;
    esac
done

[ -n "$MODE" ] || { echo "error: pass --login or --env-file <world env>" >&2; usage; exit 1; }
[ -f "$LOGIN_ENV" ] || { echo "error: login env file not found: $LOGIN_ENV (use --login-env)" >&2; exit 1; }

# ---- load env files (values assigned literally; never executed) ----
load_env() {
    local file="$1" line key val
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        case "$line" in ''|'#'*) continue ;; esac
        [ "$line" = "${line#*=}" ] && continue
        key="${line%%=*}"; val="${line#*=}"
        export "${key// /}=$val"
    done < "$file"
}
load_env "$LOGIN_ENV"

# ---- render helper: literal substitution of the tokens in $TOKENS ----
render() { # <template file> <output file>
    [ -f "$1" ] || { echo "error: template not found: $1" >&2; exit 1; }
    local content; content="$(cat "$1")"
    local v
    for v in "${TOKENS[@]}"; do
        content="${content//\$\{$v\}/${!v}}"
    done
    if printf '%s' "$content" | grep -q '\${'; then
        echo "error: unresolved \${...} token in $(basename "$1") — check the template/env" >&2
        printf '%s\n' "$content" | grep -n '\${' >&2
        exit 1
    fi
    printf '%s\n' "$content" > "$2"
    echo "   wrote $2"
}

if [ "$MODE" = "login" ]; then
    TEMPLATE_DIR="${TEMPLATE_OVERRIDE:-$LOGIN_TEMPLATE_DIR}"
    [ -d "$TEMPLATE_DIR" ] || { echo "error: template dir not found: $TEMPLATE_DIR" >&2; exit 1; }
    DB_USER="${DB_USER:-ragnarok}"
    : "${DB_PASSWORD:?set DB_PASSWORD in $LOGIN_ENV}"
    ACCOUNTS_DB="${DB_NAME:-accounts}"
    TOKENS=(DB_USER DB_PASSWORD ACCOUNTS_DB)

    mkdir -p "$HERE/asset-login"
    echo ">> rendering login asset into asset-login/"
    render "$TEMPLATE_DIR/inter_conf.txt" "$HERE/asset-login/inter_conf.txt"
    render "$TEMPLATE_DIR/login_conf.txt" "$HERE/asset-login/login_conf.txt"
    echo ">> done."
    exit 0
fi

# ---- world mode ----
[ -n "$WORLD_ENV" ] || { echo "error: --env-file requires a path" >&2; usage; exit 1; }
[ -f "$WORLD_ENV" ] || { echo "error: world env file not found: $WORLD_ENV" >&2; exit 1; }
TEMPLATE_DIR="${TEMPLATE_OVERRIDE:-$WORLD_TEMPLATE_DIR}"
[ -d "$TEMPLATE_DIR" ] || { echo "error: template dir not found: $TEMPLATE_DIR" >&2; exit 1; }
load_env "$WORLD_ENV"

DB_USER="${DB_USER:-ragnarok}"
: "${DB_PASSWORD:?set DB_PASSWORD in $LOGIN_ENV}"
: "${WORLD:?set WORLD in $WORLD_ENV}"
: "${CONFIG_DIR:?set CONFIG_DIR in $WORLD_ENV}"
: "${WORLD_DB:?set WORLD_DB in $WORLD_ENV}"
: "${SERVER_USERID:?set SERVER_USERID in $WORLD_ENV}"
: "${SERVER_PASSWORD:?set SERVER_PASSWORD in $WORLD_ENV}"
: "${SERVER_NAME:?set SERVER_NAME in $WORLD_ENV}"
: "${CHAR_PORT:?set CHAR_PORT in $WORLD_ENV}"
: "${MAP_PORT:?set MAP_PORT in $WORLD_ENV}"
: "${PUBLIC_IP:?set PUBLIC_IP in $WORLD_ENV}"

# Optional per-world knobs: defaulted here so existing world env files (written
# before these were introduced) keep rendering unchanged. 99 is the stock
# conf/battle/player.conf value, so an unset MAX_PARAMETER is a no-op.
MAX_PARAMETER="${MAX_PARAMETER:-99}"
MAX_TRANS_PARAMETER="${MAX_TRANS_PARAMETER:-$MAX_PARAMETER}"   # stock is also 99
MAX_BABY_PARAMETER="${MAX_BABY_PARAMETER:-80}"

TOKENS=(DB_USER DB_PASSWORD WORLD WORLD_DB SERVER_USERID SERVER_PASSWORD \
        SERVER_NAME CHAR_PORT MAP_PORT PUBLIC_IP \
        MAX_PARAMETER MAX_TRANS_PARAMETER MAX_BABY_PARAMETER)

if [ -d "$CONFIG_DIR" ] && [ "$FORCE" -ne 1 ]; then
    echo ">> updating existing $CONFIG_DIR (use --force to silence this note)"
fi
mkdir -p "$CONFIG_DIR"

echo ">> rendering world '$WORLD' assets into $CONFIG_DIR"
render "$TEMPLATE_DIR/inter_conf.txt"  "$CONFIG_DIR/inter_conf.txt"
render "$TEMPLATE_DIR/char_conf.txt"   "$CONFIG_DIR/char_conf.txt"
render "$TEMPLATE_DIR/map_conf.txt"    "$CONFIG_DIR/map_conf.txt"
render "$TEMPLATE_DIR/battle_conf.txt" "$CONFIG_DIR/battle_conf.txt"

# ---- per-world NPC list ----
# Copied verbatim (NOT through render(): NPC scripts are not templates, and a
# literal '${' in one would trip the unresolved-token check). Lands at
# /rathena/conf/import/npc/, which npc/scripts_custom.conf imports as the last
# entry of the script chain. Own subdir so it can be wiped without touching the
# rendered *_conf.txt, and so a stray file here can never shadow them.
NPC_SRC="$WORLD_NPC_DIR/$WORLD"
NPC_SRC_LABEL="world-npc/$WORLD"
if [ ! -d "$NPC_SRC" ]; then
    NPC_SRC="$WORLD_NPC_DIR/_default"
    NPC_SRC_LABEL="world-npc/_default (no world-npc/$WORLD — this world loads no extra NPCs)"
fi
[ -f "$NPC_SRC/scripts_world.conf" ] || {
    echo "error: $NPC_SRC/scripts_world.conf not found — the server errors on a" >&2
    echo "       missing import, so this file must exist (may be comment-only)." >&2
    exit 1
}
rm -rf "$CONFIG_DIR/npc"
mkdir -p "$CONFIG_DIR/npc"
cp -a "$NPC_SRC"/. "$CONFIG_DIR/npc"/
echo "   wrote $CONFIG_DIR/npc/ from $NPC_SRC_LABEL"

# ---- per-world db/import overrides ----
# Mounted at /rathena/db/import, the LAST entry in every db Footer import chain
# (db/job_stats.yml, db/statpoint.yml, …), so it is the per-world override point
# for level caps, exp tables and other db values.
#
# Seeded from db/import-tmpl FIRST, then this world's overrides on top. The seed
# is not optional: the mount replaces /rathena/db/import wholesale, and every
# file in import-tmpl is referenced by some Footer, so without it each one logs a
# "Failed to open" error at boot. (Same trap as conf/import — see SETUP.md.)
[ -d "$DB_IMPORT_TMPL" ] || { echo "error: $DB_IMPORT_TMPL not found" >&2; exit 1; }
rm -rf "$CONFIG_DIR/db-import"
mkdir -p "$CONFIG_DIR/db-import"
cp -a "$DB_IMPORT_TMPL"/. "$CONFIG_DIR/db-import"/
if [ -d "$WORLD_DBIMPORT_DIR/$WORLD" ]; then
    cp -a "$WORLD_DBIMPORT_DIR/$WORLD"/. "$CONFIG_DIR/db-import"/
    echo "   wrote $CONFIG_DIR/db-import/ from db/import-tmpl + world-db/$WORLD"
else
    echo "   wrote $CONFIG_DIR/db-import/ from db/import-tmpl (no world-db/$WORLD — stock db values)"
fi

echo ">> done. Bring the world up:  docker compose -f docker-compose.world.yml --env-file $WORLD_ENV up -d"
echo "   (already running? \`@reloadscript\` in-game picks up NPC list changes.)"
