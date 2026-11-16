#!/usr/bin/env python3
"""Check client/server propagation and game links for a closed-world bot test run.

Usage: check_bot_traces.py <start-unix-seconds> [<end-unix-seconds>]
The default all-sampled test configuration is required. Standalone launcher health probes are valid.
"""

import sys
import time

from backends import failed, traces


def check(start, end):
    def spans(service):
        return [
            s
            for rows in traces(start, end, service=service).values()
            for s in rows
            if s["resource"].get("service.name") == service
        ]

    clients = {s["spanId"]: s for s in spans("balatro-autoplay") if s["attrs"].get("balatro.bot.role") == "client"}
    servers = {s["spanId"]: s for s in spans("balatrobot") if s["attrs"].get("balatro.bot.role") == "server"}
    game = spans("balatro")
    problems, matched = [], set()
    if not clients or not servers:
        problems.append("missing Python client or BalatroBot server spans")
    client_traces = {s["traceId"] for s in clients.values()}
    for server in servers.values():
        parent = server.get("parentSpanId")
        if parent in clients:
            if server["traceId"] != clients[parent]["traceId"]:
                problems.append(f"{server['name']}: client/server trace IDs differ")
            else:
                matched.add(parent)
        elif server["traceId"] in client_traces:
            problems.append(f"{server['name']}: server parent is not a captured client span")
    for sid, client in clients.items():
        if not failed(client) and sid not in matched:
            problems.append(f"{client['name']}: successful client call has no matching server span")
    sessions = {s["attrs"].get("session.id") for s in servers.values()} - {None}
    hands = [s for s in game if s["name"] == "balatro.hand" and s["attrs"].get("session.id") in sessions]
    linked = 0
    for hand in hands:
        related = [
            servers[l["spanId"]]
            for l in hand.get("links", [])
            if l["spanId"] in servers and l["traceId"] == servers[l["spanId"]]["traceId"]
        ]
        if any(s["attrs"].get("rpc.method") == "play" for s in related):
            linked += 1
        else:
            problems.append("a hand has no link to its play command")
    print(
        f"bot correlation: {len(clients)} client calls, {len(servers)} server calls, "
        f"{len(matched)} matched, {linked}/{len(hands)} hands linked"
    )
    for problem in problems:
        print("PROBLEM:", problem)
    print("bot correlation: ok" if not problems else f"bot correlation: {len(problems)} problem(s)")
    return problems


if __name__ == "__main__":
    start = int(sys.argv[1])
    end = int(sys.argv[2]) if len(sys.argv) > 2 else int(time.time()) + 60
    sys.exit(bool(check(start, end)))
