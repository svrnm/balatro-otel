#!/usr/bin/env python3
"""Build integrations/bronto/dashboard.yaml in Bronto without `bronto dashboards apply`.

Fallback for when `apply` cannot run: it reads every widget in the org (GET /widgets), and that list
returned 500 for this org on 2026-10-28. This does what apply does, with the installed `bronto`
CLI (`bronto api`) and `yq`: one metric definition and one widget per manifest widget, built the
way bronto-cli 0.9.0 builds them (same from_expr, aggregation, units, definition marker and
ownership tags), so a later real `bronto dashboards apply -f dashboard.yaml` adopts them as its own.

Run it once, on a dashboard without apply-managed widgets: it detaches the dashboard's current
widgets (prints their ids) and attaches new ones. Once GET /widgets works again, use apply.
Usage: apply_fallback.py [integrations/bronto/dashboard.yaml]
"""
import json
import re
import subprocess
import sys
import tempfile

TIME_FUNCTIONS = {"sum", "avg", "average", "min", "max", "mean", "count", "median",
                  "p25", "p50", "p75", "p90", "p95", "p99", "p999", "histogram", "rate"}
UNIT_TYPES = {"nanoseconds": "time", "microseconds": "time", "milliseconds": "time", "seconds": "time",
              "minutes": "time", "hours": "time", "days": "time", "bytes": "data_size",
              "kilobytes": "data_size", "megabytes": "data_size", "gigabytes": "data_size",
              "percent": "percentage", "fraction": "percentage"}


def bronto(method, path, body=None):
    cmd = ["bronto", "api", method, path]
    with tempfile.NamedTemporaryFile("w", suffix=".json") as f:
        if body is not None:
            json.dump(body, f)
            f.flush()
            cmd += ["--input", f.name]
        proc = subprocess.run(cmd, capture_output=True, text=True, check=False)  # returncode is checked below
    reply = json.loads(proc.stdout) if proc.stdout.strip() else {}  # 204s have no body
    if proc.returncode != 0 or (isinstance(reply, dict) and "error" in reply):
        raise SystemExit(f"{method} {path}: {reply.get('error') if isinstance(reply, dict) else proc.stderr}")
    return reply


def unit_config(unit):
    t = UNIT_TYPES.get(unit)
    if not t:
        return None
    return {"type": t, "input": unit} if t == "percentage" else {"type": t, "input": unit, "output": "auto"}


def from_expr(dataset):
    collection, name = dataset.rsplit("/", 1)  # manifest datasets are written collection/name
    return f"\"collection\" = '{collection}' AND \"dataset\" = '{name}'"


def definition(widget, dash_id):
    queries = []
    for i, q in enumerate(widget["queries"], 1):
        func = re.match(r"^([A-Za-z][A-Za-z0-9]*)\s*\(.*\)$", q["select"].strip())
        default_agg = func.group(1).lower() if func and func.group(1).lower() in TIME_FUNCTIONS else ""
        aq = {"name": q.get("name", f"q{i}"), "select": [q["select"]], "where": q.get("where", ""),
              "groups": q.get("group_by", []),
              "aggregation": [{"time": q.get("agg", default_agg), "reduce_to": "avg"}],
              "from_expr": from_expr(q["dataset"]) if "dataset" in q else q["from_expr"]}
        uc = unit_config(q.get("unit") or widget.get("unit"))
        if uc:
            aq["unit_config"] = uc
        queries.append(aq)
    # the marker apply writes, so apply recognizes the definition as its own
    return {"name": widget["name"], "description": f"Managed by bronto-cli for dashboard {dash_id}.",
            "queries": queries}


def tag(entity, entity_id, name, value):
    bronto("POST", "/tags", {"name": name, "value": value, "entity": {"type": entity, "id": entity_id}})


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "integrations/bronto/dashboard.yaml"
    manifest = json.loads(subprocess.run(["yq", "-o=json", ".", path], capture_output=True, text=True, check=True).stdout)

    dashboards = [d for d in bronto("GET", "/dashboards").get("dashboards", []) if d["name"] == manifest["name"]]
    if len(dashboards) > 1:
        raise SystemExit(f"{len(dashboards)} dashboards are named {manifest['name']!r}")
    if dashboards:
        dash_id = dashboards[0]["id"]
    else:
        created = bronto("POST", "/dashboards", {"name": manifest["name"]})
        dash_id = created.get("id") or created.get("dashboard_id")
    current = bronto("GET", f"/dashboards/{dash_id}").get("widget_ids", [])
    for wid in current:
        bronto("DELETE", f"/dashboards/{dash_id}/widgets/{wid}")
        print(f"detached {wid}")

    ids = {}
    for w in manifest["widgets"]:
        def_id = bronto("POST", "/metrics/definitions", definition(w, dash_id))["id"]
        body = {"name": w["name"], "type": w.get("type", "line"), "metric_ids": [def_id]}
        if "sort" in w:
            by, _, direction = w["sort"].partition(" ")
            body["aux"] = {"sortBy": by, "sortDirection": direction or {"value": "desc", "name": "asc"}[by]}
        wid = bronto("POST", "/widgets", body)["id"]
        tag("widget", wid, "managed-by", "bronto-cli")
        tag("widget", wid, "bronto-cli-owner", dash_id)
        ids[w["name"]] = wid
        print(f"widget {wid}  {w['name']}")

    bronto("POST", f"/dashboards/{dash_id}/widgets", {"widget_ids": list(ids.values())})
    if "layout" in manifest:
        bronto("PATCH", f"/dashboards/{dash_id}", {"layout": {"widget_layouts": [
            {"id": ids[pos["widget"]], "x": pos["x"], "y": pos["y"], "w": pos["w"], "h": pos["h"]}
            for pos in manifest["layout"]]}})
    for name, value in (manifest.get("tags") or {}).items():
        tag("dashboard", dash_id, name, value)
    print(f"dashboard {dash_id}: {len(ids)} widgets")


if __name__ == "__main__":
    main()
