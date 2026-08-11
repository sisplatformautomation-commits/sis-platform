import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import {
  getGlobalTraceProvider,
  setTraceProcessors,
  setTracingDisabled,
  withCustomSpan,
  withTrace,
  type Span,
  type Trace,
  type TracingProcessor,
} from "@openai/agents";

const SDK_VERSION = "0.14.0";
const WORK_ITEM = "P3-049";
const OBSERVED_WORK_ITEM = "GMA-002";

function adminClient(): SupabaseClient {
  const url = Deno.env.get("SUPABASE_URL");
  const newKeys = Deno.env.get("SUPABASE_SECRET_KEYS");
  const legacyKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const key = newKeys ? JSON.parse(newKeys)?.default : legacyKey;
  if (!url || !key) throw new Error("TRACE_RUNTIME_CONFIGURATION_MISSING");
  return createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

function safeValue(value: unknown, depth = 0): unknown {
  if (depth > 4) return "[depth_limited]";
  if (value === null || typeof value === "boolean" || typeof value === "number") return value;
  if (typeof value === "string") return value.slice(0, 500);
  if (Array.isArray(value)) return value.slice(0, 30).map((v) => safeValue(v, depth + 1));
  if (typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value as Record<string, unknown>).slice(0, 40)) {
      const key = k.toLowerCase();
      if (
        key.includes("token") || key.includes("secret") || key.includes("password") ||
        key.includes("authorization") || key.includes("body") || key.includes("content") ||
        key.includes("prompt")
      ) continue;
      out[k] = safeValue(v, depth + 1);
    }
    return out;
  }
  return String(value).slice(0, 500);
}

function spanName(span: Span<any>) {
  const data = span.spanData as Record<string, unknown>;
  return String(data?.name ?? data?.type ?? "span").slice(0, 160);
}

function spanKind(span: Span<any>) {
  const data = span.spanData as Record<string, unknown>;
  return String(data?.type ?? "unknown").slice(0, 80);
}

class SisTraceProcessor implements TracingProcessor {
  private chains = new Map<string, Promise<void>>();

  constructor(private db: SupabaseClient) {}

  private serialize(key: string, task: () => Promise<void>): Promise<void> {
    const previous = this.chains.get(key) ?? Promise.resolve();
    const current = previous.catch(() => undefined).then(task);
    this.chains.set(key, current);
    current.finally(() => {
      if (this.chains.get(key) === current) this.chains.delete(key);
    });
    return current;
  }

  async onTraceStart(trace: Trace): Promise<void> {
    const md = safeValue(trace.metadata ?? {}) as Record<string, unknown>;
    await this.serialize(`trace:${trace.traceId}`, async () => {
      const { error } = await this.db.from("sis_agent_trace_runs").upsert({
        trace_id: trace.traceId,
        workflow_name: trace.name,
        group_id: trace.groupId,
        work_item_key: String(md.work_item_key ?? WORK_ITEM),
        observed_work_item_key: String(md.observed_work_item_key ?? OBSERVED_WORK_ITEM),
        environment_key: String(md.environment_key ?? "test"),
        status: "running",
        sdk_name: "@openai/agents",
        sdk_version: SDK_VERSION,
        source: "agents_sdk_custom_processor",
        started_at: new Date().toISOString(),
        metadata: md,
        updated_at: new Date().toISOString(),
      }, { onConflict: "trace_id" });
      if (error) throw new Error(`TRACE_START_PERSIST_FAILED:${error.message}`);
    });
  }

  async onTraceEnd(trace: Trace): Promise<void> {
    await this.serialize(`trace:${trace.traceId}`, async () => {
      const { error } = await this.db.from("sis_agent_trace_runs").update({
        status: "completed",
        ended_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      }).eq("trace_id", trace.traceId);
      if (error) throw new Error(`TRACE_END_PERSIST_FAILED:${error.message}`);
    });
  }

  async onSpanStart(span: Span<any>): Promise<void> {
    const raw = span.spanData as Record<string, unknown>;
    const data = safeValue(raw?.data ?? raw ?? {}) as Record<string, unknown>;
    await this.serialize(`span:${span.spanId}`, async () => {
      const { error } = await this.db.from("sis_agent_trace_spans").upsert({
        span_id: span.spanId,
        trace_id: span.traceId,
        parent_span_id: span.parentId,
        span_name: spanName(span),
        span_kind: spanKind(span),
        status: "running",
        started_at: span.startedAt ?? new Date().toISOString(),
        data,
        updated_at: new Date().toISOString(),
      }, { onConflict: "span_id" });
      if (error) throw new Error(`SPAN_START_PERSIST_FAILED:${error.message}`);
    });
  }

  async onSpanEnd(span: Span<any>): Promise<void> {
    const raw = span.spanData as Record<string, unknown>;
    const data = safeValue(raw?.data ?? raw ?? {}) as Record<string, unknown>;
    await this.serialize(`span:${span.spanId}`, async () => {
      const { error } = await this.db.from("sis_agent_trace_spans").upsert({
        span_id: span.spanId,
        trace_id: span.traceId,
        parent_span_id: span.parentId,
        span_name: spanName(span),
        span_kind: spanKind(span),
        status: span.error ? "failed" : "completed",
        started_at: span.startedAt ?? new Date().toISOString(),
        ended_at: span.endedAt ?? new Date().toISOString(),
        data,
        error_summary: span.error ? "span_failed_redacted" : null,
        updated_at: new Date().toISOString(),
      }, { onConflict: "span_id" });
      if (error) throw new Error(`SPAN_END_PERSIST_FAILED:${error.message}`);
    });
  }

  async forceFlush(): Promise<void> {
    while (this.chains.size > 0) {
      await Promise.allSettled([...this.chains.values()]);
    }
  }

  async shutdown(): Promise<void> {
    await this.forceFlush();
  }
}

const db = adminClient();
setTracingDisabled(false);
// Phase 1 intentionally replaces the default exporter. Trace data is projected only into SIS.
setTraceProcessors([new SisTraceProcessor(db)]);

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

function number01(value: unknown): number | null {
  const n = Number(value);
  return Number.isFinite(n) && n >= 0 && n <= 1 ? n : null;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ ok: false, error: "METHOD_NOT_ALLOWED" }, 405);

  let body: Record<string, any>;
  try {
    body = await req.json();
  } catch {
    return json({ ok: false, error: "JSON_REQUIRED" }, 400);
  }

  const environment = String(body.environment_key ?? "").toLowerCase();
  const execution = body.execution ?? {};
  const classification = body.classification ?? {};
  const authorization = body.authorization ?? {};
  const confidence = number01(classification.confidence);

  if (body.work_item_key !== WORK_ITEM || body.observed_work_item_key !== OBSERVED_WORK_ITEM) {
    return json({ ok: false, error: "TRACE_SCOPE_INVALID" }, 400);
  }
  if (!["dev", "test"].includes(environment)) {
    return json({ ok: false, error: "ENVIRONMENT_OUT_OF_SCOPE" }, 400);
  }
  if (!/^[0-9a-f]{32}$/.test(String(execution.make_execution_id ?? ""))) {
    return json({ ok: false, error: "MAKE_EXECUTION_ID_INVALID" }, 400);
  }
  if (!Number.isInteger(Number(execution.make_scenario_id)) || Number(execution.make_scenario_id) <= 0) {
    return json({ ok: false, error: "MAKE_SCENARIO_ID_INVALID" }, 400);
  }
  if (confidence === null) return json({ ok: false, error: "CONFIDENCE_INVALID" }, 400);
  if (classification.mail_write_allowed !== false) {
    return json({ ok: false, error: "OBSERVABILITY_REQUIRES_MAIL_WRITE_FALSE" }, 409);
  }
  if (body.provider_write_performed !== false) {
    return json({ ok: false, error: "OBSERVABILITY_REQUIRES_PROVIDER_WRITE_FALSE" }, 409);
  }

  const trace = getGlobalTraceProvider().createTrace({
    name: "SIS GMA-002 Phase 1 Observability",
    groupId: "P3-049:GMA-002",
    metadata: {
      work_item_key: WORK_ITEM,
      observed_work_item_key: OBSERVED_WORK_ITEM,
      environment_key: environment,
      phase: "phase_1_agents_sdk_trace_observability",
      data_policy: "sanitized_metadata_only",
      execution_gate_changes: false,
      approval_gate_changes: false,
      provider_write_performed: false,
    },
  });

  try {
    await withTrace(trace, async () => {
      await withCustomSpan(async () => {
        await withCustomSpan(async () => {}, {
          data: {
            type: "custom",
            name: "gma.fixture_runner",
            data: {
              scenario_id: Number(execution.make_scenario_id),
              execution_id: String(execution.make_execution_id),
              execution_status: String(execution.status ?? "UNKNOWN").slice(0, 40),
              provider_write_performed: false,
            },
          },
        });
        await withCustomSpan(async () => {}, {
          data: {
            type: "custom",
            name: "gma.classification",
            data: {
              category: String(classification.category ?? "unknown").slice(0, 80),
              confidence,
              recommended_action: String(classification.recommended_action ?? "none").slice(0, 80),
            },
          },
        });
        await withCustomSpan(async () => {}, {
          data: {
            type: "custom",
            name: "gma.policy",
            data: {
              policy_decision: String(classification.policy_decision ?? "unknown").slice(0, 80),
              approval_required: Boolean(classification.approval_required),
              mail_write_allowed: false,
              delete_semantics: String(classification.delete_semantics ?? "none").slice(0, 80),
            },
          },
        });
        await withCustomSpan(async () => {}, {
          data: {
            type: "custom",
            name: "p3_048.authorization_boundary",
            data: {
              legacy_decision: String(authorization.legacy_decision ?? "unknown").slice(0, 80),
              shadow_decision: String(authorization.shadow_decision ?? "unknown").slice(0, 80),
              enforcement_changed: false,
              approval_gate_changed: false,
            },
          },
        });
      }, {
        data: {
          type: "custom",
          name: "sis.worker.integration",
          data: {
            worker_key: "sis.worker.integration",
            environment_key: environment,
            observed_work_item_key: OBSERVED_WORK_ITEM,
          },
        },
      });
    });
    await getGlobalTraceProvider().forceFlush();
  } catch (error) {
    return json({ ok: false, error: "TRACE_EMIT_FAILED", detail: String(error).slice(0, 300) }, 500);
  }

  return json({
    ok: true,
    trace_id: trace.traceId,
    group_id: trace.groupId,
    workflow_name: trace.name,
    sdk: `@openai/agents@${SDK_VERSION}`,
    export_mode: "sis_custom_processor_only",
    provider_write_performed: false,
    mail_write_performed: false,
    execution_gate_changes: false,
    approval_gate_changes: false,
  });
});
