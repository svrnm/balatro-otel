"""OpenTelemetry bootstrap and bounded application observations for the Python player.

Uses upstream JSON-RPC conventions v1.44.0; custom signals are defined in telemetry/registry/bot.yaml.
No request parameters or game-state responses are exported.
"""

import atexit
import contextlib
import contextvars
import os
import time
import uuid

from opentelemetry import trace
from opentelemetry._logs import SeverityNumber
from opentelemetry.exporter.otlp.proto.http._log_exporter import OTLPLogExporter
from opentelemetry.exporter.otlp.proto.http.metric_exporter import OTLPMetricExporter
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk._logs import LoggerProvider
from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.metrics.view import ExplicitBucketHistogramAggregation, View
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.semconv._incubating.attributes import jsonrpc_attributes as JSONRPC
from opentelemetry.semconv._incubating.attributes import rpc_attributes as RPC
from opentelemetry.semconv.attributes import error_attributes as ERROR
from opentelemetry.semconv.attributes import server_attributes as SERVER
from opentelemetry.trace.propagation.tracecontext import TraceContextTextMapPropagator

VERSION = "0.4.0"
SCHEMA = "https://balatro-tracing.local/schemas/0.4.0"
METHODS = frozenset(
    (
        "health",
        "gamestate",
        "save",
        "load",
        "screenshot",
        "set",
        "add",
        "menu",
        "start",
        "skip",
        "select",
        "play",
        "discard",
        "cash_out",
        "next_round",
        "reroll",
        "buy",
        "pack",
        "rearrange",
        "sell",
        "use",
        "rpc.discover",
    )
)
STATES = frozenset(
    (
        "MENU",
        "BLIND_SELECT",
        "SELECTING_HAND",
        "ROUND_EVAL",
        "SHOP",
        "SMODS_BOOSTER_OPENED",
        "HAND_PLAYED",
        "DRAW_TO_HAND",
        "NEW_ROUND",
        "GAME_OVER",
    )
)
BOUNDS = (0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1, 5, 10, 30, 60, 120)
ERROR_CODES = frozenset((-32700, -32600, -32601, -32602, -32603))
_run_attributes = contextvars.ContextVar("bot_run_attributes", default=None)
_runtime = None


class Runtime:
    def __init__(self, *, span_exporter=None, metric_reader=None, log_exporter=None):
        resource = Resource.create(
            {
                "service.name": os.getenv("OTEL_SERVICE_NAME", "balatro-autoplay"),
                "service.version": VERSION,
                "service.instance.id": str(uuid.uuid4()),
            }
        )
        self.traces = TracerProvider(resource=resource, shutdown_on_exit=False)
        self.traces.add_span_processor(BatchSpanProcessor(span_exporter or OTLPSpanExporter(timeout=3)))
        self.metrics = MeterProvider(
            resource=resource,
            shutdown_on_exit=False,
            metric_readers=[
                metric_reader
                or PeriodicExportingMetricReader(OTLPMetricExporter(timeout=3), export_interval_millis=10000)
            ],
            views=[
                View(instrument_name="rpc.client.call.duration", aggregation=ExplicitBucketHistogramAggregation(BOUNDS))
            ],
        )
        self.logs = LoggerProvider(resource=resource, shutdown_on_exit=False)
        self.logs.add_log_record_processor(BatchLogRecordProcessor(log_exporter or OTLPLogExporter(timeout=3)))
        self.tracer = self.traces.get_tracer("balatro.autoplay", VERSION, schema_url=SCHEMA)
        meter = self.metrics.get_meter("balatro.autoplay", VERSION, schema_url=SCHEMA)
        self.duration = meter.create_histogram("rpc.client.call.duration", unit="s")
        self.decisions = meter.create_counter("balatro.bot.decisions", unit="{decision}")
        self.logger = self.logs.get_logger("balatro.autoplay", VERSION, schema_url=SCHEMA)
        self.closed = False

    def shutdown(self):
        if not self.closed:
            self.closed = True
            self.traces.shutdown()
            self.logs.shutdown()
            self.metrics.shutdown()


def runtime():
    global _runtime
    if _runtime is None:
        _runtime = Runtime()
        atexit.register(_runtime.shutdown)
    return _runtime


def failure(span, kind):
    span.set_attribute(ERROR.ERROR_TYPE, kind)
    span.set_status(trace.StatusCode.ERROR, "Bot operation failed")


@contextlib.contextmanager
def operation(name, attributes=None):
    attrs = dict(_run_attributes.get() or {})
    attrs.update(attributes or {})
    with runtime().tracer.start_as_current_span(
        name, attributes=attrs, record_exception=False, set_status_on_exception=False
    ) as span:
        try:
            yield span
        except BaseException as exc:
            failure(span, type(exc).__name__)
            raise


@contextlib.contextmanager
def run(seed, deck, stake):
    token = _run_attributes.set({"balatro.run.seed": seed})
    try:
        with operation("balatro.bot.run", {"balatro.bot.deck": deck, "balatro.bot.stake": stake}) as span:
            try:
                yield span
            except BaseException:
                span.set_attribute("balatro.bot.run.outcome", "error")
                raise
    finally:
        _run_attributes.reset(token)


@contextlib.contextmanager
def decision(state, forced):
    state = state if state in STATES else "OTHER"
    with operation("balatro.bot.decision", {"balatro.game.state": state, "balatro.bot.forced": forced}) as span:
        try:
            yield span
        finally:
            runtime().decisions.add(1, {"balatro.game.state": state})


@contextlib.contextmanager
def client_call(port, method, request_id):
    canonical = method if method in METHODS else "_OTHER"
    attrs = {
        RPC.RPC_SYSTEM_NAME: "jsonrpc",
        RPC.RPC_METHOD: canonical,
        JSONRPC.JSONRPC_PROTOCOL_VERSION: "2.0",
        JSONRPC.JSONRPC_REQUEST_ID: str(request_id),
        SERVER.SERVER_ADDRESS: "127.0.0.1",
        SERVER.SERVER_PORT: port,
        "balatro.bot.role": "client",
        **(_run_attributes.get() or {}),
    }
    if canonical == "_OTHER":
        attrs[RPC.RPC_METHOD_ORIGINAL] = method
    started = time.perf_counter()
    metric_attrs = {
        RPC.RPC_SYSTEM_NAME: "jsonrpc",
        RPC.RPC_METHOD: canonical,
        SERVER.SERVER_ADDRESS: "127.0.0.1",
        SERVER.SERVER_PORT: port,
    }
    with runtime().tracer.start_as_current_span(
        method if canonical != "_OTHER" else "jsonrpc",
        kind=trace.SpanKind.CLIENT,
        attributes=attrs,
        record_exception=False,
        set_status_on_exception=False,
    ) as span:
        headers = {}
        TraceContextTextMapPropagator().inject(headers)
        try:
            yield span, headers
        except Exception as exc:
            kind = getattr(exc, "kind", "transport_error")
            failure(span, kind)
            metric_attrs[ERROR.ERROR_TYPE] = kind
            code = getattr(exc, "code", None)
            if code is not None:
                span.set_attribute(RPC.RPC_RESPONSE_STATUS_CODE, str(code))
                metric_attrs[RPC.RPC_RESPONSE_STATUS_CODE] = str(code) if code in ERROR_CODES else "_OTHER"
            raise
        finally:
            runtime().duration.record(time.perf_counter() - started, metric_attrs)


def recovery(state):
    runtime().logger.emit(
        event_name="balatro.bot.recovery",
        severity_number=SeverityNumber.WARN,
        attributes={
            "balatro.bot.recovery.action": "reread_state",
            "balatro.game.state": state if state in STATES else "OTHER",
            ERROR.ERROR_TYPE: "rpc_error",
            **(_run_attributes.get() or {}),
        },
    )
