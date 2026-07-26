#!/usr/bin/env python3
"""Generate a world's db/import overrides for a raised base level cap.

Writes production/world-db/<world>/{job_stats.yml,statpoint.yml}, which
render-assets.sh copies into that world's db/import mount — the last entry in
every db Footer import chain, so it wins over db/ and db/pre-re/.

    ./gen-level-tables.py --world highrate --max-level 300

Re-run any time you want to retune; it reads the stock tables for its anchors,
so it stays in sync with db/pre-re/*.yml rather than duplicating them.

WHY A SCRIPT: the exp curve and the stat budget are gameplay design choices, not
facts about the code. The knobs are --max-level, --exp-ceiling and
--stat-formula. Everything else is derived.

HARD CONSTRAINT — --exp-ceiling: src/config/const.hpp sets
MAX_EXP = (PACKETVER >= 20170830) ? INT64_MAX : INT32_MAX. This server builds
with packetver 20111102, so exp is capped at INT32_MAX (2,147,483,647) and any
per-level requirement above that is unreachable. The default ceiling leaves
headroom under it. Raising the ceiling past INT32_MAX requires a newer packetver.
"""
import argparse
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
INT32_MAX = 2147483647

# The two job groups in db/pre-re/job_exp.yml that define BASE level (the other
# nine define job level only, which this script deliberately leaves alone).
BASE_GROUPS = {"normal": 88, "trans": 341}


def parse_job_group(path, start_line):
    """Extract (job names, {level: exp}) for the BaseExp block of one group."""
    lines = path.read_text().splitlines()
    jobs, exp, lv, in_base = [], {}, None, False
    for line in lines[start_line - 1:]:
        if re.match(r"^  - Jobs:", line) and jobs:
            break
        if m := re.match(r"^      (\w+): true", line):
            jobs.append(m.group(1))
        if re.match(r"^    BaseExp:", line):
            in_base = True
            continue
        if in_base and re.match(r"^    \w", line):
            break
        if in_base:
            if m := re.match(r"^      - Level: (\d+)", line):
                lv = int(m.group(1))
            elif m := re.match(r"^        Exp: (\d+)", line):
                exp[lv] = int(m.group(1))
    return jobs, exp


def stat_point_cost(low):
    """Mirror of PC_STATUS_POINT_COST, pre-renewal branch (src/map/pc.cpp:8803).

    Keep in sync with the macro. Below 100 it is stock rAthena; above, cost grows
    by 4 every 5 points so the 100+ range is progressively expensive.
    """
    return (1 + (low + 9) // 10) if low < 100 else (11 + 4 * ((low - 100) // 5))


def cost_to_reach(cap):
    """Points to raise ONE stat from 1 to `cap`."""
    return sum(stat_point_cost(low) for low in range(1, cap))


def parse_statpoints(path):
    d, lv = {}, None
    for line in path.read_text().splitlines():
        if m := re.match(r"^  - Level: (\d+)", line):
            lv = int(m.group(1))
        elif m := re.match(r"^    Points: (\d+)", line):
            d[lv] = int(m.group(1))
    return d


def build_exp_curve(stock, anchor_lv, last, ceiling):
    """Geometric curve from stock[anchor_lv] up to `ceiling` at level `last`.

    Rows above anchor_lv are regenerated, deliberately overwriting vanilla's
    endgame padding. Those top rows are not a natural continuation of the curve:
    the normal group jumps 58,135,000 (L97) -> 99,999,998 (L98) -> 99,999,999
    (L99), and the transcendent group drops 343,210,000 (L98) -> 99,999,999
    (L99). They are artefacts of MAX_LEVEL_BASE_EXP and of L99 never being read
    for levelling (pc_nextbaseexp short-circuits at max level). Anchoring on them
    would leave a spike, then a dip, in the middle of the new curve.
    """
    if anchor_lv not in stock:
        raise SystemExit(f"error: no stock BaseExp row for anchor level {anchor_lv}")
    anchor = stock[anchor_lv]
    steps = last - anchor_lv
    ratio = (ceiling / anchor) ** (1.0 / steps)
    return anchor_lv, anchor, ratio, {
        lv: min(int(round(anchor * ratio ** (lv - anchor_lv))), ceiling)
        for lv in range(anchor_lv + 1, last + 1)
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--world", required=True, help="world id, e.g. highrate")
    ap.add_argument("--max-level", type=int, default=300,
                    help="base level cap; must be <= MAX_LEVEL in src/map/map.hpp (default 300)")
    ap.add_argument("--exp-ceiling", type=int, default=2_000_000_000,
                    help="exp required for the last level before the cap; must stay "
                         f"under INT32_MAX={INT32_MAX:,} (default 2,000,000,000)")
    ap.add_argument("--anchor-level", type=int, default=97,
                    help="last stock BaseExp level kept as-is; rows above it are regenerated. "
                         "Default 97 = the last level before vanilla's endgame padding in both "
                         "base-level groups (see build_exp_curve)")
    ap.add_argument("--stat-cap", type=int, default=200,
                    help="the world's max_parameter, used to report and document how far the "
                         "generated point budget actually goes (default 200). Set the real value "
                         "via MAX_PARAMETER in the world env file")
    ap.add_argument("--stat-formula", choices=("continue", "flat"), default="continue",
                    help="'continue' extends the engine's own sub-200 statpoint formula past "
                         "the level-200 plateau; 'flat' keeps the plateau (levels past 200 "
                         "grant no points). Default: continue")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    # MAX_LEVEL is the compile-time ceiling; MaxBaseLevel above it is silently
    # capped by the parser (src/map/pc.cpp:14043), so fail loudly here instead.
    max_level_hpp = int(re.search(r"^#define MAX_LEVEL (\d+)",
                                 (REPO / "src/map/map.hpp").read_text(),
                                 re.M).group(1))
    if args.max_level > max_level_hpp:
        sys.exit(f"error: --max-level {args.max_level} exceeds MAX_LEVEL {max_level_hpp} in "
                 f"src/map/map.hpp. Raise it there and rebuild the image first.")
    if args.exp_ceiling > INT32_MAX:
        sys.exit(f"error: --exp-ceiling {args.exp_ceiling:,} exceeds INT32_MAX "
                 f"({INT32_MAX:,}), unreachable at packetver < 20170830.")

    out_dir = REPO / "production/world-db" / args.world
    job_exp_src = REPO / "db/pre-re/job_exp.yml"

    # ---- job_stats.yml: MaxBaseLevel + extended BaseExp ----
    body, report = [], []
    for name, line_no in BASE_GROUPS.items():
        jobs, stock = parse_job_group(job_exp_src, line_no)
        anchor_lv, anchor, ratio, curve = build_exp_curve(
            stock, args.anchor_level, args.max_level, args.exp_ceiling)
        body.append("  - Jobs:")
        body += [f"      {j}: true" for j in jobs]
        body.append(f"    MaxBaseLevel: {args.max_level}")
        body.append("    BaseExp:")
        for lv in sorted(curve):
            body.append(f"      - Level: {lv}")
            body.append(f"        Exp: {curve[lv]}")
        report.append((name, len(jobs), anchor_lv, anchor, ratio,
                       curve[anchor_lv + 1], curve[args.max_level]))

    job_yml = f"""# GENERATED by production/gen-level-tables.py — do not edit by hand.
# Re-run:  ./gen-level-tables.py --world {args.world} --max-level {args.max_level} \\
#              --exp-ceiling {args.exp_ceiling} --stat-formula {args.stat_formula}
#
# Per-world base level cap for world '{args.world}'. Loaded via db/import/job_stats.yml,
# the LAST entry in db/job_stats.yml's Footer import chain, so it overrides the
# MaxBaseLevel: 99 and the BaseExp rows in db/pre-re/job_exp.yml.
#
# Only the two job groups that define BASE level are touched. Job level caps
# (MaxJobLevel 10/50/70/99) are left exactly as pre-renewal ships them.
#
# MaxBaseLevel MUST be in the same node as the new BaseExp rows: the parser reads
# it first and skips any BaseExp row above it (src/map/pc.cpp:14053).
Header:
  Type: JOB_STATS
  Version: 4

Body:
{chr(10).join(body)}
"""

    # ---- statpoint.yml: continue past the level-200 plateau ----
    stat_src = parse_statpoints(REPO / "db/pre-re/statpoint.yml")
    PLATEAU = 200
    cum = stat_src[PLATEAU]
    stat_body = []
    for lv in range(PLATEAU + 1, args.max_level + 1):
        if args.stat_formula == "continue":
            cum += (lv - 1 + 15) // 5   # the engine's own sub-200 formula
        stat_body.append(f"  - Level: {lv}")
        stat_body.append(f"    Points: {cum}")

    stat_yml = f"""# GENERATED by production/gen-level-tables.py — do not edit by hand.
#
# Per-world stat points for world '{args.world}'. Loaded via db/import/statpoint.yml,
# the last entry in db/statpoint.yml's Footer import chain.
#
# WHY THIS EXISTS: 'Points' is CUMULATIVE, and the stock pre-renewal table is flat
# at {stat_src[PLATEAU]} from level {PLATEAU} to the cap — pc_gets_status_point returns
# next-current, so every level past {PLATEAU} grants ZERO stat points. Without this
# file a raised level cap is cosmetic.
#
# Values continue the formula the engine itself uses below level 200
# ((level - 1 + 15) / 5, see PlayerStatPointDatabase::loadingFinished), simply
# without the plateau. Level {args.max_level} ends at {cum} cumulative points.
#
# BUDGET vs the world's stat cap ({args.stat_cap}, set via MAX_PARAMETER in the env file).
# Under the pre-renewal cost formula (src/map/pc.cpp PC_STATUS_POINT_COST) one stat
# costs {cost_to_reach(args.stat_cap)} points to reach {args.stat_cap}, so all six cost {cost_to_reach(args.stat_cap) * 6}.
# This table grants {cum} by level {args.max_level} — enough to take
# {min(6, cum // cost_to_reach(args.stat_cap))} of six stats to {args.stat_cap}, with {cum - cost_to_reach(args.stat_cap) * min(6, cum // cost_to_reach(args.stat_cap))} left over.
# That is intentional: the cap is build-defining, not something every character
# reaches on all six stats. Retune with --stat-formula / --max-level.
Header:
  Type: STATPOINT_DB
  Version: 2

Body:
{chr(10).join(stat_body)}
"""

    print(f"world '{args.world}': base level cap {args.max_level} "
          f"(MAX_LEVEL in map.hpp = {max_level_hpp})")
    for name, njobs, alv, aexp, ratio, first_exp, last_exp in report:
        print(f"  {name:>6}: {njobs:>2} jobs | anchored on stock L{alv} = {aexp:,} | "
              f"{(ratio-1)*100:.3f}%/level | L{alv+1} = {first_exp:,} -> L{args.max_level} = {last_exp:,}")
    print(f"  statpoints: L{PLATEAU} = {stat_src[PLATEAU]} -> L{args.max_level} = {cum} "
          f"({args.stat_formula})")
    one = cost_to_reach(args.stat_cap)
    print(f"  stat cap {args.stat_cap}: {one} pts/stat, {one * 6} for all six; budget {cum} "
          f"buys {min(6, cum // one)} of 6 at cap ({cum - one * min(6, cum // one)} left over)")

    if args.dry_run:
        print("\n(dry run — nothing written)")
        return
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "job_stats.yml").write_text(job_yml)
    (out_dir / "statpoint.yml").write_text(stat_yml)
    print(f"\nwrote {out_dir.relative_to(REPO)}/job_stats.yml")
    print(f"wrote {out_dir.relative_to(REPO)}/statpoint.yml")
    print(f"\nnext:  ./render-assets.sh --env-file .env.world-{args.world}")


if __name__ == "__main__":
    main()
