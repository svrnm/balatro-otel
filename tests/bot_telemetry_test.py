"""Exercise real Python SDK exports and bot RPC behavior against a controlled HTTP server."""

import contextlib
import http.server
import io
import json
import os
import sys
import threading
import unittest
from pathlib import Path
from typing import ClassVar
from unittest.mock import patch

from google.protobuf.json_format import MessageToDict
from opentelemetry.exporter.otlp.proto.common._log_encoder import encode_logs
from opentelemetry.exporter.otlp.proto.common.metrics_encoder import encode_metrics
from opentelemetry.exporter.otlp.proto.common.trace_encoder import encode_spans
from opentelemetry.sdk._logs.export import InMemoryLogRecordExporter
from opentelemetry.sdk.metrics.export import InMemoryMetricReader
from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter
from opentelemetry.trace import SpanKind, StatusCode

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "telemetry"))
import autoplay
import bot_telemetry as telemetry
import check_bot_traces


class Handler(http.server.BaseHTTPRequestHandler):
    requests: ClassVar[list] = []
    mode = "ok"

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.requests.append((request, dict(self.headers)))
        if self.mode == "invalid_json":
            body = b"not json"
        else:
            reply = {"jsonrpc": "2.0", "id": request["id"]}
            if self.mode == "error":
                reply["error"] = {"code": -32602, "message": "Rejected"}
            elif self.mode == "wrong_id":
                reply.update(id=-100, result={})
            else:
                reply["result"] = {"state": "SELECTING_HAND"}
            body = json.dumps(reply).encode()
        self.send_response(200)
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


class BotTelemetryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.spans = InMemorySpanExporter()
        cls.logs = InMemoryLogRecordExporter()
        cls.metrics = InMemoryMetricReader()
        cls.runtime = telemetry.Runtime(span_exporter=cls.spans, metric_reader=cls.metrics, log_exporter=cls.logs)
        telemetry._runtime = cls.runtime
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.port = cls.server.server_port

    @classmethod
    def tearDownClass(cls):
        cls.runtime.traces.force_flush()
        cls.runtime.logs.force_flush()
        data = cls.metrics.get_metrics_data()
        out = os.getenv("BOT_TEST_OUTPUT")
        if out:
            folder = Path(out)
            folder.mkdir(parents=True, exist_ok=True)
            exports = {
                "bot-client-traces": encode_spans(cls.spans.get_finished_spans()),
                "bot-client-logs": encode_logs(cls.logs.get_finished_logs()),
                "bot-client-metrics": encode_metrics(data),
            }
            for name, payload in exports.items():
                (folder / f"{name}.json").write_text(json.dumps(MessageToDict(payload)))
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()
        cls.runtime.shutdown()
        telemetry._runtime = None

    def setUp(self):
        Handler.mode = "ok"

    def finished(self):
        self.runtime.traces.force_flush()
        return self.spans.get_finished_spans()

    def test_success_parentage_and_header(self):
        with telemetry.run("BOTTEST", "BLUE", "WHITE") as root:
            with telemetry.decision("SELECTING_HAND", False) as decision:
                result = autoplay.rpc(self.port, "play", cards=[0, 1])
            root.set_attribute("balatro.bot.run.outcome", "game_over")
        self.assertEqual(result["state"], "SELECTING_HAND")
        spans = self.finished()
        call = next(s for s in reversed(spans) if s.kind == SpanKind.CLIENT)
        self.assertEqual(call.parent.span_id, decision.get_span_context().span_id)
        self.assertEqual(call.context.trace_id, root.get_span_context().trace_id)
        request, headers = Handler.requests[-1]
        parent = headers["Traceparent"].split("-")
        self.assertEqual(int(parent[1], 16), call.context.trace_id)
        self.assertEqual(int(parent[2], 16), call.context.span_id)
        self.assertEqual(call.attributes["jsonrpc.request.id"], str(request["id"]))
        self.assertNotIn("cards", call.attributes)
        self.assertEqual(call.attributes["balatro.run.seed"], "BOTTEST")

    def test_rpc_error_and_recovery_log(self):
        Handler.mode = "error"
        with telemetry.decision("SHOP", False):
            with self.assertRaises(autoplay.RPCError) as caught:
                autoplay.rpc(self.port, "buy", card=0)
            self.assertEqual(caught.exception.kind, "jsonrpc_error")
            telemetry.recovery("SHOP")
        call = next(s for s in reversed(self.finished()) if s.kind == SpanKind.CLIENT)
        self.assertEqual(call.status.status_code, StatusCode.ERROR)
        self.assertEqual(call.attributes["rpc.response.status_code"], "-32602")
        self.runtime.logs.force_flush()
        record = self.logs.get_finished_logs()[-1].log_record
        self.assertEqual(record.event_name, "balatro.bot.recovery")
        self.assertEqual(record.trace_id, call.context.trace_id)

    def test_protocol_and_transport_errors(self):
        for mode in ("wrong_id", "invalid_json"):
            Handler.mode = mode
            with self.assertRaises(autoplay.RPCError):
                autoplay.rpc(self.port, "health")
        before = len(Handler.requests)
        with patch("urllib.request.urlopen", side_effect=TimeoutError()), self.assertRaises(autoplay.RPCError):
            autoplay.rpc(self.port, "play", cards=[0])
        self.assertEqual(len(Handler.requests), before, "no transparent replay of an uncertain action")
        calls = [s for s in self.finished() if s.kind == SpanKind.CLIENT]
        self.assertTrue(all(s.status.status_code == StatusCode.ERROR for s in calls[-3:]))

    def test_unknown_method_bounded_metrics(self):
        for method in ("custom_a", "custom_b"):
            autoplay.rpc(self.port, method)
        spans = [s for s in self.finished() if s.attributes.get("rpc.method_original")]
        self.assertEqual([s.name for s in spans[-2:]], ["jsonrpc", "jsonrpc"])
        data = self.metrics.get_metrics_data()
        points = [
            p
            for resource in data.resource_metrics
            for scope in resource.scope_metrics
            for metric in scope.metrics
            if metric.name == "rpc.client.call.duration"
            for p in metric.data.data_points
        ]
        unknown = [p for p in points if p.attributes["rpc.method"] == "_OTHER"]
        self.assertEqual(len(unknown), 1)
        self.assertGreaterEqual(unknown[0].count, 2)
        for point in points:
            self.assertNotIn("rpc.method_original", point.attributes)
            self.assertNotIn("jsonrpc.request.id", point.attributes)
            self.assertNotIn("balatro.run.seed", point.attributes)

    def test_heuristic_is_explained_and_ids_are_unique(self):
        cards = [{"value": {"rank": rank, "suit": "Hearts"}} for rank in "23456"]
        self.assertEqual(autoplay.best_hand(cards), [4, 3, 2, 1, 0])
        selection = next(s for s in reversed(self.finished()) if s.name == "balatro.bot.choose_hand")
        self.assertEqual(selection.attributes["balatro.bot.strategy"], "flush")
        autoplay.rpc(self.port, "health")
        autoplay.rpc(self.port, "health")
        self.assertNotEqual(Handler.requests[-1][0]["id"], Handler.requests[-2][0]["id"])

    def test_correlation_gate_rejects_missing_links_and_wrong_parents(self):
        client = {
            "spanId": "client",
            "traceId": "command",
            "name": "play",
            "resource": {"service.name": "balatro-autoplay"},
            "attrs": {"balatro.bot.role": "client"},
        }
        server = {
            "spanId": "server",
            "traceId": "command",
            "parentSpanId": "client",
            "name": "play",
            "resource": {"service.name": "balatrobot"},
            "attrs": {"balatro.bot.role": "server", "rpc.method": "play", "session.id": "session"},
        }
        hand = {
            "spanId": "hand",
            "traceId": "game",
            "name": "balatro.hand",
            "resource": {"service.name": "balatro"},
            "attrs": {"session.id": "session"},
            "links": [{"spanId": "server", "traceId": "command"}],
        }
        with (
            patch.object(check_bot_traces, "traces", return_value={"trace": [client, server, hand]}),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            self.assertEqual(check_bot_traces.check(0, 1), [])
            hand["links"] = []
            self.assertTrue(check_bot_traces.check(0, 1))
            server["parentSpanId"] = "wrong"
            self.assertTrue(check_bot_traces.check(0, 1))


if __name__ == "__main__":
    unittest.main()
