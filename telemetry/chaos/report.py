#!/usr/bin/env python3
"""After a chaos run: for every injected scenario, show where it surfaced in Jaeger, the log file and
Prometheus, next to the same measurement for the baseline session (no chaos).
Sessions and scenarios come from the per-container game logs (telemetry/live-check-report/container-*).
Usage: report.py <start-unix-seconds>
"""
import functools
import glob
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, __file__.rsplit("/", 2)[0])
from backends import failed, logs, prom, traces
from check_traces import FORCED_SCORE

START = END = 0  # the report window, set in main()


@functools.cache
def all_spans():
    return [s for spans in traces(START, END).values() for s in spans]


@functools.cache
def all_logs():
    return logs(START, END)


def session_of(item):
    return item["attrs"].get("session.id") or item["resource"].get("session.id") or item["resource"].get("service.instance.id")


def spans(session, name=None):
    return [s for s in all_spans() if session_of(s) == session and (name is None or s["name"] == name)]


def events(session, event_name=None, scope=None):
    return [r for r in all_logs() if session_of(r) == session
            and (event_name is None or r.get("eventName") == event_name) and (scope is None or r["scope"] == scope)]


def duration(span):
    return (int(span["endTimeUnixNano"]) - int(span["startTimeUnixNano"])) / 1e9


def sessions():
    found = []
    for d in sorted(glob.glob("telemetry/live-check-report/container-*") + glob.glob("telemetry/live-check-report/wave-*/container-*")):
        log = "".join(Path(f).read_text(errors="replace") for f in glob.glob(f"{d}/lovely-log/*.log"))
        session = re.search(r"\[otel\] loaded, session ([0-9a-f-]{36})", log)
        chaos = re.search(r"\[chaos\] scenarios: (\S+)", log)
        if session:
            found.append((d.split("live-check-report/", 1)[1], session.group(1), chaos.group(1).split(",") if chaos else []))
    return found


# Each measurement: (where it shows up, function(session) -> printable value)
def jank(s):
    found = events(s, "app.jank")
    if not found:
        return "0 app.jank events"
    states = sorted({str(r["attrs"].get("balatro.game.state")) for r in found})
    worst = max(float(r["attrs"].get("app.jank.period", 0)) for r in found)
    upd = max(float(r["attrs"].get("balatro.frame.update.duration", 0)) for r in found)
    return f"{len(found)} app.jank events, states {states}, worst frame {worst:.2f}s (update {upd:.2f}s)"


def slow_joker(s):
    slow = [x for x in spans(s, "balatro.card.evaluate") if duration(x) > 0.02]
    names = sorted({x["attrs"].get("balatro.card.name") for x in slow} - {None})
    return f"{len(slow)} card evaluations > 20 ms" + (f": {names[:5]}" if names else "")


def queue_flood(s):
    lengths = [int(x["attrs"].get("balatro.event_queue.max_length") or 0) for x in spans(s, "balatro.blind")]
    return f"max event queue {max(lengths) if lengths else '-'} over {len(lengths)} blinds"


def leak(s):
    # balatro.lua.memory.live: heap after a full GC at run start; sampled memory includes garbage
    live = sorted((int(x["startTimeUnixNano"]), int(x["attrs"].get("balatro.lua.memory.live") or 0)) for x in spans(s, "balatro.run"))
    return f"live lua heap at run start: {[round(m / 2**20, 1) for _, m in live]} MiB"


def score_bug(s):
    # by blind, not by run: an interrupted run never sends its balatro.run span
    mine, bad, total = spans(s), 0, 0
    for blind in (x for x in mine if x["name"] == "balatro.blind"):
        score = blind["attrs"].get("balatro.blind.score")
        if score is None or score >= FORCED_SCORE:
            continue
        hands = sum(h["attrs"].get("balatro.hand.score", 0) for h in mine
                    if h["name"] == "balatro.hand" and h.get("parentSpanId") == blind["spanId"])
        total += 1
        bad += abs(hands - score) > 1e-6 * max(score, 1)
    return f"{bad}/{total} blinds where score != sum of hands"


def mod_error(s):
    found = events(s, scope="ChaosMod")
    linked = sum(1 for r in found if r.get("traceId"))
    levels = sorted({str(r.get("severityText")) for r in found})
    sample = found[0].get("body", {}).get("stringValue", "") if found else ""
    return f"{len(found)} ChaosMod log records {levels}, {linked} linked to a trace" + (f'; e.g. "{sample}"' if sample else "")


def crash(s):
    found = events(s, "app.crash")
    failed_spans = [x for x in spans(s) if failed(x)]
    if not found:
        return f"no app.crash; {len(failed_spans)} failed spans"
    a = found[0]["attrs"]
    frames = [ln.strip() for ln in str(a.get("exception.stacktrace", "")).splitlines() if "otel-chaos" in ln][:1]
    # last_over_time: an instant query only looks back 5 minutes, and the session is over
    crashes = prom(f'sum(last_over_time(balatro_crashes_total{{instance="{s}"}}[3h]))')
    return (f'app.crash "{a.get("exception.message")}" in state {a.get("balatro.game.state")}, '
            f"stack {frames}; {len(failed_spans)} failed spans; balatro_crashes_total={crashes}")


def draw_heavy(s):
    calls = prom(f'max_over_time(balatro_render_draw_calls{{instance="{s}"}}[2h])')
    p50 = prom(f'histogram_quantile(0.5, sum by (le) (balatro_frame_draw_duration_seconds_bucket{{instance="{s}"}}))')
    return f"max draw calls {calls}, median draw {p50 * 1000:.1f} ms" if calls is not None and p50 else "no render samples (headless?)"


SCENARIOS = {
    "jank": ("app.jank events (log file)", jank),
    "slow_joker": ("slow balatro.card.evaluate spans (Jaeger)", slow_joker),
    "queue_flood": ("balatro.blind event_queue.max_length (Jaeger)", queue_flood),
    "leak": ("balatro.run lua.memory.live (Jaeger)", leak),
    "score_bug": ("blind score vs hands (Jaeger, as check_traces)", score_bug),
    "mod_error": ("ChaosMod log records (log file)", mod_error),
    "crash": ("app.crash event + failed spans", crash),
    "draw_heavy": ("Prometheus render draw calls/time", draw_heavy),
}


def main():
    global START, END
    START, END = int(sys.argv[1]), int(time.time()) + 60
    found = sessions()
    # "render" only switches a container to render mode; it is the baseline for draw_heavy
    baseline = next((s for _, s, chaos in found if not chaos), None)
    render_baseline = next((s for _, s, chaos in found if chaos == ["render"]), None)
    for container, session, chaos in found:
        faults = [c for c in chaos if c != "render"]
        if not faults:
            continue
        print(f"\n{container} (session {session[:8]}) injected: {', '.join(faults)}")
        for name in faults:
            where, measure = SCENARIOS[name]
            base = render_baseline if name == "draw_heavy" else baseline
            print(f"  {name:12} {where}")
            print(f"    with fault: {measure(session)}")
            if base:
                print(f"    baseline:   {measure(base)}")


if __name__ == "__main__":
    main()
