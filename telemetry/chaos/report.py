#!/usr/bin/env python3
"""After a chaos run: for every injected scenario, show where it surfaced in Tempo, Loki and
Prometheus, next to the same measurement for the baseline session (no chaos).
Sessions and scenarios come from the per-container game logs (telemetry/live-check-report/container-*).
Usage: report.py <start-unix-seconds>
"""
import glob
import json
import re
import sys
import time

sys.path.insert(0, __file__.rsplit("/", 2)[0])
from check_traces import FORCED_SCORE, get, spans_of  # noqa: E402


# session_id, scope_name and event_name are structured metadata in Loki, not stream labels, so they
# are filtered in the pipeline (| session_id="...") rather than in the {selector}.
def loki(query, start, end, limit=1000):
    data = get("loki/loki/api/v1/query_range", query=query, start=start * 10**9, end=end * 10**9, limit=limit)
    return [(s["stream"], line) for s in data["data"]["result"] for _, line in s["values"]]


def prom(query):
    result = get("prometheus/api/v1/query", query=query)["data"]["result"]
    return float(result[0]["value"][1]) if result else None


def tempo(q, start, end):
    # Tempo caps spans per span set (spss) at 100
    return get("tempo/api/search", q=q, start=start, end=end, limit=1000, spss=100).get("traces", [])


def matched_spans(q, start, end):
    return [s for t in tempo(q, start, end) for ss in t.get("spanSets", [t.get("spanSet") or {}]) for s in ss.get("spans", [])]


def span_attr(span, key):
    for a in span.get("attributes", []):
        if a["key"] == key:
            v = a["value"]
            return v.get("stringValue") or v.get("intValue") or v.get("doubleValue")
    return None


def sessions():
    found = []
    for d in sorted(glob.glob("telemetry/live-check-report/container-*") + glob.glob("telemetry/live-check-report/wave-*/container-*")):
        log = "".join(open(f, errors="replace").read() for f in glob.glob(f"{d}/lovely-log/*.log"))
        session = re.search(r"\[otel\] loaded, session ([0-9a-f-]{36})", log)
        chaos = re.search(r"\[chaos\] scenarios: (\S+)", log)
        if session:
            found.append((d.split("live-check-report/", 1)[1], session.group(1), chaos.group(1).split(",") if chaos else []))
    return found


# Each measurement: (where it shows up, function(session, start, end) -> printable value)
def jank(s, a, b):
    events = loki(f'{{service_name="balatro"}} | session_id="{s}" | event_name="app.jank"', a, b)
    if not events:
        return "0 app.jank events"
    states = sorted({lbl.get("balatro_game_state") for lbl, _ in events})
    worst = max(float(lbl.get("app_jank_period", 0)) for lbl, _ in events)
    upd = max(float(lbl.get("balatro_frame_update_duration", 0)) for lbl, _ in events)
    return f"{len(events)} app.jank events, states {states}, worst frame {worst:.2f}s (update {upd:.2f}s)"


def slow_joker(s, a, b):
    spans = matched_spans(f'{{ span.session.id = "{s}" && name = "balatro.card.evaluate" && duration > 20ms }} '
                          f'| select(span.balatro.card.name)', a, b)
    names = sorted({span_attr(x, "balatro.card.name") for x in spans} - {None})
    return f"{len(spans)} card evaluations > 20 ms" + (f": {names[:5]}" if names else "")


def queue_flood(s, a, b):
    spans = matched_spans(f'{{ span.session.id = "{s}" && name = "balatro.blind" }} '
                          f'| select(span.balatro.event_queue.max_length)', a, b)
    lengths = [int(span_attr(x, "balatro.event_queue.max_length") or 0) for x in spans]
    return f"max event queue {max(lengths) if lengths else '-'} over {len(spans)} blinds"


def leak(s, a, b):
    # balatro.lua.memory.live: heap after a full GC at run start; sampled memory includes garbage
    spans = matched_spans(f'{{ span.session.id = "{s}" && name = "balatro.run" }} '
                          f'| select(span.balatro.lua.memory.live)', a, b)
    live = [(int(x.get("startTimeUnixNano", 0)), int(span_attr(x, "balatro.lua.memory.live") or 0)) for x in spans]
    return f"live lua heap at run start: {[round(m / 2**20, 1) for _, m in sorted(live)]} MiB"


def score_bug(s, a, b):
    # by blind, not by run: an interrupted run never sends its balatro.run span
    bad = total = 0
    for t in tempo(f'{{ span.session.id = "{s}" && name = "balatro.blind" }}', a, b):
        spans = list(spans_of(get(f"tempo/api/traces/{t['traceID']}")))
        for blind in (x for x in spans if x["name"] == "balatro.blind"):
            score = blind["attrs"].get("balatro.blind.score")
            if score is None or score >= FORCED_SCORE:
                continue
            hands = sum(h["attrs"].get("balatro.hand.score", 0) for h in spans
                        if h["name"] == "balatro.hand" and h.get("parentSpanId") == blind["spanId"])
            total += 1
            bad += abs(hands - score) > 1e-6 * max(score, 1)
    return f"{bad}/{total} blinds where score != sum of hands"


def mod_error(s, a, b):
    logs = loki(f'{{service_name="balatro"}} | session_id="{s}" | scope_name="ChaosMod"', a, b)
    linked = sum(1 for lbl, _ in logs if lbl.get("trace_id"))
    levels = sorted({lbl.get("severity_text") for lbl, _ in logs})
    sample = logs[0][1] if logs else ""
    return f"{len(logs)} ChaosMod log records {levels}, {linked} linked to a trace" + (f'; e.g. "{sample}"' if sample else "")


def crash(s, a, b):
    events = loki(f'{{service_name="balatro"}} | session_id="{s}" | event_name="app.crash"', a, b)
    failed = matched_spans(f'{{ span.session.id = "{s}" && status = error }}', a, b)
    if not events:
        return f"no app.crash; {len(failed)} failed spans"
    lbl = events[0][0]
    frames = [ln.strip() for ln in lbl.get("exception_stacktrace", "").splitlines() if "otel-chaos" in ln][:1]
    # last_over_time: an instant query only looks back 5 minutes, and the session is over
    crashes = prom('sum(last_over_time(balatro_crashes_total{instance="%s"}[3h]))' % s)
    return (f'app.crash "{lbl.get("exception_message")}" in state {lbl.get("balatro_game_state")}, '
            f"stack {frames}; {len(failed)} failed spans; balatro_crashes_total={crashes}")


def draw_heavy(s, a, b):
    calls = prom(f'max_over_time(balatro_render_draw_calls{{instance="{s}"}}[2h])')
    p50 = prom(f'histogram_quantile(0.5, sum by (le) (balatro_frame_draw_duration_seconds_bucket{{instance="{s}"}}))')
    return f"max draw calls {calls}, median draw {p50 * 1000:.1f} ms" if calls is not None and p50 else "no render samples (headless?)"


SCENARIOS = {
    "jank": ("Loki app.jank events", jank),
    "slow_joker": ("Tempo slow balatro.card.evaluate spans", slow_joker),
    "queue_flood": ("Tempo balatro.blind event_queue.max_length", queue_flood),
    "leak": ("Tempo balatro.run lua.memory.live", leak),
    "score_bug": ("Tempo blind score vs hands (check_traces)", score_bug),
    "mod_error": ("Loki ChaosMod logs", mod_error),
    "crash": ("Loki app.crash + Tempo failed spans", crash),
    "draw_heavy": ("Prometheus render draw calls/time", draw_heavy),
}


def main():
    start, end = int(sys.argv[1]), int(time.time()) + 60
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
            print(f"    with fault: {measure(session, start, end)}")
            if base:
                print(f"    baseline:   {measure(base, start, end)}")


if __name__ == "__main__":
    main()
