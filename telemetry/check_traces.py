#!/usr/bin/env python3
"""Consistency checks on what reached the backends (Tempo, Loki via Grafana), beyond naming:
- every balatro.run trace has an outcome and at least one blind
- each blind's score equals the sum of its hands' scores (blinds forced by autoplay are skipped)
- each hand added to its blind what it scored (balatro.hand.blind_score_added == balatro.hand.score)
- balatro.blind.won agrees with score >= target
- no span failed (status ERROR)
- no "otel hook failed" warnings in the logs
- soak (>= 4 runs in one game session): the live Lua heap at run start (after a full GC) does not
  keep growing from run to run
Usage: check_traces.py <start-unix-seconds> [<end-unix-seconds>]
"""
import collections
import json
import statistics
import sys
import time
import urllib.parse
import urllib.request

GRAFANA = "http://localhost:3000/api/datasources/proxy/uid"
FORCED_SCORE = 1e9  # autoplay's `set chips` before the last hand


def get(path, **params):
    url = f"{GRAFANA}/{path}?{urllib.parse.urlencode(params)}"
    with urllib.request.urlopen(url, timeout=30) as resp:
        return json.load(resp)


def value(v):
    for k in ("stringValue", "boolValue", "doubleValue"):
        if k in v:
            return v[k]
    if "intValue" in v:
        return int(v["intValue"])
    return None


def spans_of(trace):
    for batch in trace.get("batches", trace.get("resourceSpans", [])):
        for scope in batch.get("scopeSpans", []):
            for s in scope["spans"]:
                s["attrs"] = {a["key"]: value(a["value"]) for a in s.get("attributes", [])}
                yield s


def main():
    start = int(sys.argv[1])
    end = int(sys.argv[2]) if len(sys.argv) > 2 else int(time.time()) + 60
    problems, memory = [], collections.defaultdict(list)  # session.id -> [(run start, live bytes)]
    checked = forced = 0

    found = get("tempo/api/search", q='{ resource.service.name = "balatro" && name = "balatro.run" }',
                start=start, end=end, limit=1000)
    trace_ids = [t["traceID"] for t in found.get("traces", [])]
    print(f"run traces: {len(trace_ids)}")
    if not trace_ids:
        problems.append("no balatro.run traces in the window")

    for tid in trace_ids:
        spans = list(spans_of(get(f"tempo/api/traces/{tid}")))
        run = next(s for s in spans if s["name"] == "balatro.run")
        label = f"run {run['attrs'].get('balatro.run.seed')} ({tid[:8]})"
        if "balatro.lua.memory.live" in run["attrs"]:
            memory[run["attrs"].get("session.id")].append((int(run["startTimeUnixNano"]), run["attrs"]["balatro.lua.memory.live"]))
        if "balatro.run.outcome" not in run["attrs"]:
            problems.append(f"{label}: no balatro.run.outcome")
        for s in spans:
            if s.get("status", {}).get("code") in (2, "STATUS_CODE_ERROR"):
                problems.append(f"{label}: span {s['name']} failed: {s['status'].get('message')}")
        blinds = [s for s in spans if s["name"] == "balatro.blind"]
        if not blinds and not run["attrs"].get("balatro.run.resumed"):  # a resumed run may end in the shop
            problems.append(f"{label}: no blinds")
        for b in sorted(blinds, key=lambda s: int(s["startTimeUnixNano"])):
            a = b["attrs"]
            hands = [s for s in spans if s["name"] == "balatro.hand" and s.get("parentSpanId") == b["spanId"]]
            score, target = a.get("balatro.blind.score"), a.get("balatro.blind.target")
            if score is None or target is None:
                continue  # blind ended by game over or a new run, not by end of round
            if score >= FORCED_SCORE:
                forced += 1
            else:
                checked += 1
                total = sum(h["attrs"].get("balatro.hand.score", 0) for h in hands)
                if abs(total - score) > 1e-6 * max(score, 1):
                    problems.append(f"{label}: {a.get('balatro.blind.name')} score {score} != sum of {len(hands)} hands {total}")
            for h in hands:
                ha = h["attrs"]
                added, scored = ha.get("balatro.hand.blind_score_added"), ha.get("balatro.hand.score")
                if added is not None and scored is not None and abs(added - scored) > 1e-6 * max(abs(scored), 1) and added < FORCED_SCORE / 10:
                    problems.append(f"{label}: {a.get('balatro.blind.name')}: a {ha.get('balatro.hand.type')} scored {scored} but the blind gained {added}")
            if "balatro.blind.won" in a and a["balatro.blind.won"] != (score >= target):
                problems.append(f"{label}: {a.get('balatro.blind.name')} won={a['balatro.blind.won']} but score {score} vs target {target}")

    hook_failures = get("loki/loki/api/v1/query_range", query='{service_name="balatro"} |= "otel hook failed"',
                        start=start * 10**9, end=end * 10**9, limit=100)["data"]["result"]
    for stream in hook_failures:
        for _, line in stream["values"]:
            problems.append(f"log: {line}")

    for session, points in memory.items():
        if len(points) < 4:
            continue
        live = [m for _, m in sorted(points)]
        half = len(live) // 2
        first, last = statistics.median(live[:half]), statistics.median(live[-half:])
        print(f"session {session[:8]}: live lua heap at run start {[round(m / 2**20, 1) for m in live]} MiB")
        if last > 1.5 * first:
            problems.append(f"session {session[:8]}: live lua heap grows across runs: {first / 2**20:.1f} -> {last / 2**20:.1f} MiB")

    print(f"blinds: {checked} score-checked against their hands, {forced} forced by autoplay")
    if trace_ids and not checked:
        problems.append("no blind could be score-checked")
    for p in problems:
        print("PROBLEM:", p)
    print("consistency: ok" if not problems else f"consistency: {len(problems)} problem(s)")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
