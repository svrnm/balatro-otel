"""Read back what the local stack (telemetry/stack) received: traces from Jaeger's API v3 (OTLP/JSON),
logs from the collector's file exporter, metrics from Prometheus."""
import datetime
import json
import os
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

JAEGER = os.environ.get("JAEGER_URL", "http://localhost:16686")
PROMETHEUS = os.environ.get("PROMETHEUS_URL", "http://localhost:9090")
LOGS_FILE = Path(os.environ.get("LOGS_FILE", Path(__file__).parent / "stack/data/logs.jsonl"))
SERVICE = "balatro"


def _get(url, **params):
    with urllib.request.urlopen(f"{url}?{urllib.parse.urlencode(params)}", timeout=60) as resp:
        return resp.read().decode()


def value(v):
    for k in ("stringValue", "boolValue", "doubleValue"):
        if k in v:
            return v[k]
    if "intValue" in v:
        return int(v["intValue"])
    return None


def attrs(items):
    return {a["key"]: value(a["value"]) for a in items or []}


def _rfc3339(unix):
    return datetime.datetime.fromtimestamp(unix, datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def failed(span):
    return span.get("status", {}).get("code") in (2, "STATUS_CODE_ERROR")


def traces(start, end, limit=1000):
    """{trace id: [span]} for every balatro trace that started in [start, end] (unix seconds).
    Each span is OTLP/JSON plus "attrs" (its attributes) and "resource" (resource attributes)."""
    try:
        raw = _get(f"{JAEGER}/api/v3/traces", **{
            "query.service_name": SERVICE, "query.start_time_min": _rfc3339(start),
            "query.start_time_max": _rfc3339(end), "query.search_depth": limit})
    except urllib.error.HTTPError as e:
        if e.code == 404:  # Jaeger's answer to "no traces found"
            return {}
        raise
    found, decoder, i = {}, json.JSONDecoder(), 0
    while i < len(raw):  # grpc-gateway may stream several {"result": ...} objects back to back
        chunk, i = decoder.raw_decode(raw, i)
        while i < len(raw) and raw[i].isspace():
            i += 1
        for rs in chunk.get("result", {}).get("resourceSpans", []):
            resource = attrs(rs.get("resource", {}).get("attributes"))
            for scope in rs.get("scopeSpans", []):
                for s in scope.get("spans", []):
                    s["attrs"], s["resource"] = attrs(s.get("attributes")), resource
                    found.setdefault(s["traceId"], []).append(s)
    return found


def logs(start, end):
    """Log records from the collector's file in [start, end] (unix seconds), flattened: OTLP/JSON
    plus "attrs", "resource" and "scope" (the instrumentation scope name)."""
    if not LOGS_FILE.exists():
        return []
    lo, hi, out = start * 10**9, end * 10**9, []
    for line in LOGS_FILE.read_text().splitlines():
        for rl in json.loads(line).get("resourceLogs", []):
            resource = attrs(rl.get("resource", {}).get("attributes"))
            for sl in rl.get("scopeLogs", []):
                for r in sl.get("logRecords", []):
                    if lo <= int(r.get("timeUnixNano") or r.get("observedTimeUnixNano") or 0) <= hi:
                        r["attrs"], r["resource"], r["scope"] = attrs(r.get("attributes")), resource, sl.get("scope", {}).get("name")
                        out.append(r)
    return out


def prom(query):
    """First value of an instant PromQL query, or None."""
    result = json.loads(_get(f"{PROMETHEUS}/api/v1/query", query=query))["data"]["result"]
    return float(result[0]["value"][1]) if result else None
