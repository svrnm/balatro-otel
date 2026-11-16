#!/usr/bin/env python3
"""Convert the offline tests' OTLP/JSON exports to Weaver v0.28 live-check samples.

Usage: weaver_samples.py /tmp/otlp/*.json > /tmp/samples.json
This adapter covers this exporter's signal shapes; it is not a general OTLP converter.
"""

import json
import sys


def attributes(items):
    types = {
        "stringValue": ("string", str),
        "boolValue": ("boolean", bool),
        "intValue": ("int", int),
        "doubleValue": ("double", float),
    }
    result = []
    for item in items:
        value = item["value"]
        field = next(iter(value))
        kind, convert = types[field]
        result.append({"name": item["key"], "type": kind, "value": convert(value[field])})
    return result


def samples(payload):
    for resource in payload.get("resourceSpans", []):
        yield {"resource": {"attributes": attributes(resource["resource"]["attributes"])}}
        for scope in resource["scopeSpans"]:
            for span in scope["spans"]:
                yield {
                    "span": {
                        "name": span["name"],
                        "kind": {
                            1: "internal",
                            2: "server",
                            3: "client",
                            "SPAN_KIND_INTERNAL": "internal",
                            "SPAN_KIND_SERVER": "server",
                            "SPAN_KIND_CLIENT": "client",
                        }[span["kind"]],
                        "attributes": attributes(span.get("attributes", [])),
                    }
                }
    for resource in payload.get("resourceLogs", []):
        yield {"resource": {"attributes": attributes(resource["resource"]["attributes"])}}
        for scope in resource["scopeLogs"]:
            for record in scope["logRecords"]:
                severity = record["severityNumber"]
                if isinstance(severity, str):
                    severity = {
                        "SEVERITY_NUMBER_INFO": 9,
                        "SEVERITY_NUMBER_WARN": 13,
                        "SEVERITY_NUMBER_ERROR": 17,
                        "SEVERITY_NUMBER_FATAL": 21,
                    }[severity]
                yield {
                    "log": {
                        "event_name": record.get("eventName", ""),
                        "severity_number": severity,
                        "severity_text": record.get("severityText", ""),
                        "body": record.get("body", {}).get("stringValue", ""),
                        "attributes": attributes(record.get("attributes", [])),
                    }
                }
    for resource in payload.get("resourceMetrics", []):
        yield {"resource": {"attributes": attributes(resource["resource"]["attributes"])}}
        for scope in resource["scopeMetrics"]:
            for metric in scope["metrics"]:
                kind = next(k for k in ("sum", "gauge", "histogram") if k in metric)
                instrument = kind
                if kind == "sum":
                    instrument = "counter" if metric[kind]["isMonotonic"] else "updowncounter"
                points = []
                for point in metric[kind]["dataPoints"]:
                    output = {"attributes": attributes(point.get("attributes", []))}
                    if kind == "histogram":
                        output.update(
                            count=int(point["count"]),
                            sum=point["sum"],
                            min=point["min"],
                            max=point["max"],
                            bucket_counts=[int(x) for x in point["bucketCounts"]],
                        )
                    else:
                        output["value"] = point["asDouble"] if "asDouble" in point else int(point["asInt"])
                    points.append(output)
                yield {
                    "metric": {
                        "name": metric["name"],
                        "unit": metric["unit"],
                        "instrument": instrument,
                        "data_points": points,
                    }
                }


def main():
    result = []
    for path in sys.argv[1:]:
        with open(path) as source:
            result.extend(samples(json.load(source)))
    if not result:
        sys.exit("no telemetry samples")
    json.dump(result, sys.stdout, indent=2)
    print()


if __name__ == "__main__":
    main()
