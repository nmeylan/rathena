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

TOKENS=(DB_USER DB_PASSWORD WORLD WORLD_DB SERVER_USERID SERVER_PASSWORD \
        SERVER_NAME CHAR_PORT MAP_PORT PUBLIC_IP)

if [ -d "$CONFIG_DIR" ] && [ "$FORCE" -ne 1 ]; then
    echo ">> updating existing $CONFIG_DIR (use --force to silence this note)"
fi
mkdir -p "$CONFIG_DIR"

echo ">> rendering world '$WORLD' assets into $CONFIG_DIR"
render "$TEMPLATE_DIR/inter_conf.txt"  "$CONFIG_DIR/inter_conf.txt"
render "$TEMPLATE_DIR/char_conf.txt"   "$CONFIG_DIR/char_conf.txt"
render "$TEMPLATE_DIR/map_conf.txt"    "$CONFIG_DIR/map_conf.txt"
render "$TEMPLATE_DIR/battle_conf.txt" "$CONFIG_DIR/battle_conf.txt"
echo ">> done. Bring the world up:  docker compose -f docker-compose.world.yml --env-file $WORLD_ENV up -d"
