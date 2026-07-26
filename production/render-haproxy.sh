#!/usr/bin/env bash
# Regenerate haproxy/haproxy.cfg and haproxy/docker-compose.yml from the
# .env.world-* files, which are the single source of truth for what worlds exist.
#
#   ./render-haproxy.sh                          # every .env.world-*
#   ./render-haproxy.sh .env.world-a .env.world-b # only these
#
# WHY THIS IS A FULL REGENERATION, NOT AN UPSERT
#
# The previous approach edited haproxy.cfg in place, accumulating one marker
# block per world. That made the file runtime STATE while it was also tracked in
# git — so the committed copy (no worlds) and the server's copy (all worlds)
# were guaranteed to diverge, and any `git pull` / `checkout` / `reset` on the
# server silently wiped every registered world. Deriving the whole file from the
# env files instead makes this idempotent and stateless: the generated files are
# gitignored, only the .template files are tracked, and running this after a pull
# restores every world. Add or remove a world by adding or removing its env file.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CFG_TMPL="$HERE/haproxy/haproxy.cfg.template"
CFG_OUT="$HERE/haproxy/haproxy.cfg"
COMPOSE_TMPL="$HERE/haproxy/docker-compose.yml.template"
COMPOSE_OUT="$HERE/haproxy/docker-compose.yml"
CFG_MARK="# >>> WORLD BLOCKS (generated — do not edit below this line)"
PORTS_MARK="# >>> WORLD PORTS (generated — do not edit below this line)"

# Flood limits, applied per frontend. Keep in sync with the template's comment.
MAX_CONN_CUR="${MAX_CONN_CUR:-50}"
MAX_CONN_RATE="${MAX_CONN_RATE:-100}"

for f in "$CFG_TMPL" "$COMPOSE_TMPL"; do
    [ -f "$f" ] || { echo "error: template not found: $f" >&2; exit 1; }
done

# ---- collect worlds ----
if [ $# -gt 0 ]; then
    ENV_FILES=("$@")
else
    shopt -s nullglob
    ENV_FILES=("$HERE"/.env.world-*)
    shopt -u nullglob
fi
[ ${#ENV_FILES[@]} -gt 0 ] || {
    echo "error: no .env.world-* files found in $HERE" >&2
    echo "       create a world first:  ./new-world.sh <id>" >&2
    exit 1
}

# Read one key from an env file without sourcing it (values are never executed).
env_get() { # <file> <key>
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        case "$line" in "$2="*) printf '%s' "${line#*=}"; return 0 ;; esac
    done < "$1"
    return 1
}

blocks=""
ports=""
summary=""
seen_ports=""
for envf in "${ENV_FILES[@]}"; do
    [ -f "$envf" ] || { echo "error: env file not found: $envf" >&2; exit 1; }
    w="$(env_get "$envf" WORLD)"       || { echo "error: no WORLD in $envf" >&2; exit 1; }
    cp_="$(env_get "$envf" CHAR_PORT)" || { echo "error: no CHAR_PORT in $envf" >&2; exit 1; }
    mp="$(env_get "$envf" MAP_PORT)"   || { echo "error: no MAP_PORT in $envf" >&2; exit 1; }

    # A duplicated port silently breaks whichever world binds second.
    for p in "$cp_" "$mp"; do
        case " $seen_ports " in
            *" $p "*) echo "error: port $p used twice (world '$w' in $(basename "$envf"))" >&2
                      echo "       fix CHAR_PORT/MAP_PORT in the world env files" >&2; exit 1 ;;
        esac
        seen_ports="$seen_ports $p"
    done

    blocks="$blocks
#----------------------------------- world $w
frontend ${w}_char
    bind :$cp_
    tcp-request connection track-sc0 src table st_flood
    tcp-request connection reject if { sc0_conn_cur gt $MAX_CONN_CUR }
    tcp-request connection reject if { sc0_conn_rate gt $MAX_CONN_RATE }
    default_backend ${w}_char_bk
frontend ${w}_map
    bind :$mp
    tcp-request connection track-sc0 src table st_flood
    tcp-request connection reject if { sc0_conn_cur gt $MAX_CONN_CUR }
    tcp-request connection reject if { sc0_conn_rate gt $MAX_CONN_RATE }
    default_backend ${w}_map_bk
backend ${w}_char_bk
    server char rathena-world-${w}-char:$cp_ check resolvers docker init-addr last,libc,none
backend ${w}_map_bk
    server map rathena-world-${w}-map:$mp check resolvers docker init-addr last,libc,none"

    ports="$ports
            - \"$cp_:$cp_\"   # world $w char
            - \"$mp:$mp\"   # world $w map"

    summary="$summary  $w -> char $cp_, map $mp
"
done

# ---- render: generated content is inserted after the marker line ----
# Substring match, not whole-line: the compose marker is indented inside the
# `ports:` list, so an anchored match would miss it. The original line is echoed
# back verbatim to keep that indentation.
render_marker() { # <template> <output> <marker> <content>
    grep -qF "$3" "$1" || { echo "error: marker not found in $1: $3" >&2; exit 1; }
    awk -v mark="$3" -v body="$4" '
        index($0, mark) { print; printf "%s\n", body; next }
                        { print }
    ' "$1" > "$2.tmp" && mv "$2.tmp" "$2"
}

render_marker "$CFG_TMPL"     "$CFG_OUT"     "$CFG_MARK"   "$blocks"
render_marker "$COMPOSE_TMPL" "$COMPOSE_OUT" "$PORTS_MARK" "$ports"

echo ">> regenerated haproxy config for ${#ENV_FILES[@]} world(s):"
printf '%s' "$summary"
echo "   wrote $CFG_OUT"
echo "   wrote $COMPOSE_OUT"
echo
echo "   apply:  docker compose -f haproxy/docker-compose.yml up -d"
echo "   (recreates the container so it binds any new ports)"
echo "   firewall: ufw allow $(printf '%s' "$seen_ports" | tr ' ' '\n' | grep -v '^$' | paste -sd, -)/tcp"
