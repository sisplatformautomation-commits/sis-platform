import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import {
  Agent,
  RunState,
  Usage,
  getGlobalTraceProvider,
  run,
  setTraceProcessors,
  setTracingDisabled,
  tool,
  type Span,
  type Trace,
  type TracingProcessor,
} from "@openai/agents";

const SDK_VERSION = "0.14.0";
const WORK_ITEM = "P3-049";
const OBSERVED_WORK_ITEM = "GMA-002";
const STARTER = "sis.worker.integration";
const RESOLVER = "sis.supervisor";
const ENVIRONMENT = "test";
const CAPABILITY = "integration.provider_write";
const RESOURCE_KEY = "make.gmail_trash.test.sis_internal_hospitality";
const ACTION_KEY = "gmail.trash";
const TOOL_NAME = "gma_gmail_trash_shadow_action";

function projectKey(jsonName: string, legacyName: string): string | null {
  const value = Deno.env.get(jsonName);
  if (value) {
    try { return JSON.parse(value)?.default ?? null; } catch { return null; }
  }
  return Deno.env.get(legacyName) ?? null;
}

function clients(authorization: string) {
  const url = Deno.env.get("SUPABASE_URL");
  const publishable = projectKey("SUPABASE_PUBLISHABLE_KEYS", "SUPABASE_ANON_KEY");
  const secret = projectKey("SUPABASE_SECRET_KEYS", "SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !publishable || !secret) throw new Error("HITL_RUNTIME_CONFIGURATION_MISSING");
  return {
    user: createClient(url, publishable, {
      global: { headers: { Authorization: authorization } },
      auth: { persistSession: false, autoRefreshToken: false },
    }),
    admin: createClient(url, secret, { auth: { persistSession: false, autoRefreshToken: false } }),
  };
}

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

function routePath(req: Request) {
  const parts = new URL(req.url).pathname.split("/").filter(Boolean);
  const idx = parts.lastIndexOf("sis-agent-hitl-test");
  return "/" + (idx >= 0 ? parts.slice(idx + 1).join("/") : parts.at(-1) ?? "");
}

function safeValue(value: unknown, depth = 0): unknown {
  if (depth > 3) return "[depth_limited]";
  if (value === null || typeof value === "boolean" || typeof value === "number") return value;
  if (typeof value === "string") return value.slice(0, 200);
  if (Array.isArray(value)) return value.slice(0, 12).map((x) => safeValue(x, depth + 1));
  if (typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const [key, nested] of Object.entries(value as Record<string, unknown>).slice(0, 20)) {
      const normalized = key.toLowerCase();
      if (["token", "secret", "password", "authorization", "body", "content", "prompt", "input", "output", "instructions"].some((term) => normalized.includes(term))) continue;
      out[key] = safeValue(nested, depth + 1);
    }
    return out;
  }
  return String(value).slice(0, 200);
}

class SisTraceProcessor implements TracingProcessor {
  private chains = new Map<string, Promise<void>>();
  constructor(private db: SupabaseClient) {}

  private serialize(key: string, task: () => Promise<void>) {
    const previous = this.chains.get(key) ?? Promise.resolve();
    const current = previous.catch(() => undefined).then(task);
    this.chains.set(key, current);
    current.finally(() => { if (this.chains.get(key) === current) this.chains.delete(key); });
    return current;
  }

  async onTraceStart(trace: Trace) {
    const metadata = safeValue(trace.metadata ?? {}) as Record<string, unknown>;
    await this.serialize(`trace:${trace.traceId}`, async () => {
      const { error } = await this.db.from("sis_agent_trace_runs").upsert({
        trace_id: trace.traceId,
        workflow_name: trace.name,
        group_id: trace.groupId,
        work_item_key: String(metadata.work_item_key ?? WORK_ITEM),
        observed_work_item_key: String(metadata.observed_work_item_key ?? OBSERVED_WORK_ITEM),
        environment_key: String(metadata.environment_key ?? ENVIRONMENT),
        status: "running",
        sdk_name: "@openai/agents",
        sdk_version: SDK_VERSION,
        source: "agents_sdk_custom_processor",
        started_at: new Date().toISOString(),
        metadata,
        updated_at: new Date().toISOString(),
      }, { onConflict: "trace_id" });
      if (error) throw new Error(`TRACE_START_PERSIST_FAILED:${error.message}`);
    });
  }

  async onTraceEnd(trace: Trace) {
    await this.serialize(`trace:${trace.traceId}`, async () => {
      const { error } = await this.db.from("sis_agent_trace_runs")
        .update({ status: "completed", ended_at: new Date().toISOString(), updated_at: new Date().toISOString() })
        .eq("trace_id", trace.traceId);
      if (error) throw new Error(`TRACE_END_PERSIST_FAILED:${error.message}`);
    });
  }

  async onSpanStart(span: Span<any>) {
    const raw = span.spanData as Record<string, unknown>;
    await this.serialize(`span:${span.spanId}`, async () => {
      const { error } = await this.db.from("sis_agent_trace_spans").upsert({
        span_id: span.spanId,
        trace_id: span.traceId,
        parent_span_id: span.parentId,
        span_name: String(raw?.name ?? raw?.type ?? "span").slice(0, 160),
        span_kind: String(raw?.type ?? "unknown").slice(0, 80),
        status: "running",
        started_at: span.startedAt ?? new Date().toISOString(),
        data: safeValue(raw?.data ?? {}),
        updated_at: new Date().toISOString(),
      }, { onConflict: "span_id" });
      if (error) throw new Error(`SPAN_START_PERSIST_FAILED:${error.message}`);
    });
  }

  async onSpanEnd(span: Span<any>) {
    const raw = span.spanData as Record<string, unknown>;
    await this.serialize(`span:${span.spanId}`, async () => {
      const { error } = await this.db.from("sis_agent_trace_spans").upsert({
        span_id: span.spanId,
        trace_id: span.traceId,
        parent_span_id: span.parentId,
        span_name: String(raw?.name ?? raw?.type ?? "span").slice(0, 160),
        span_kind: String(raw?.type ?? "unknown").slice(0, 80),
        status: span.error ? "failed" : "completed",
        started_at: span.startedAt ?? new Date().toISOString(),
        ended_at: span.endedAt ?? new Date().toISOString(),
        data: safeValue(raw?.data ?? {}),
        error_summary: span.error ? "span_failed_redacted" : null,
        updated_at: new Date().toISOString(),
      }, { onConflict: "span_id" });
      if (error) throw new Error(`SPAN_END_PERSIST_FAILED:${error.message}`);
    });
  }

  async forceFlush() {
    while (this.chains.size > 0) await Promise.allSettled([...this.chains.values()]);
  }
  async shutdown() { await this.forceFlush(); }
}

async function sha256(text: string) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return Array.from(new Uint8Array(digest)).map((x) => x.toString(16).padStart(2, "0")).join("");
}

function serializedTraceId(state: string) {
  try { return String(JSON.parse(state)?.trace?.id ?? "") || null; } catch { return null; }
}

function newTraceId() { return `trace_${crypto.randomUUID().replaceAll("-", "")}`; }

async function authorizeCaller(req: Request, expectedWorker: string) {
  const authorization = req.headers.get("Authorization");
  if (!authorization) throw new Error("AUTHORIZATION_REQUIRED");
  const { user, admin } = clients(authorization);
  const { data, error } = await user.auth.getUser();
  if (error || !data.user) throw new Error("AUTHENTICATED_SUBJECT_REQUIRED");
  const { data: binding, error: bindingError } = await admin.from("sis_agent_runtime_bindings")
    .select("worker_key")
    .eq("worker_key", expectedWorker)
    .eq("environment_key", ENVIRONMENT)
    .eq("status", "active")
    .eq("auth_subject", data.user.id)
    .maybeSingle();
  if (bindingError || !binding) throw new Error("BOUND_RUNTIME_SUBJECT_REQUIRED");
  return admin;
}

async function p3048Decision(db: SupabaseClient, hitlId: string) {
  const { data, error } = await db.rpc("sis_authorization_shadow_evaluate_v2", {
    p_actor: STARTER,
    p_environment: ENVIRONMENT,
    p_capability_key: CAPABILITY,
    p_action: ACTION_KEY,
    p_resource_key: RESOURCE_KEY,
    p_risk_context: {
      provider_write: true,
      approval_required: true,
      destructive: false,
      external_financial_write: false,
    },
    p_metadata: {
      work_item: WORK_ITEM,
      phase: "phase_2_agents_sdk_hitl",
      hitl_id: hitlId,
      observed_work_item: OBSERVED_WORK_ITEM,
    },
  });
  if (error || !data) throw new Error(`P3_048_EVALUATION_FAILED:${error?.message ?? "NO_RESULT"}`);
  if (data.decision !== "APPROVAL_REQUIRED" || data.approval_required !== true || data.shadow_only_resource !== true || data.policy_version !== "p3_048_shadow_v2") {
    throw new Error("P3_048_APPROVAL_REQUIRED_NOT_CONFIRMED");
  }
  return data as Record<string, any>;
}

function modelHasToolResult(input: unknown) {
  const serialized = JSON.stringify(input ?? []);
  return serialized.includes("function_call_result") || serialized.includes("function_call_output") || serialized.includes("EVIDENCE_ONLY_EXECUTED_NO_PROVIDER_WRITE") || serialized.includes("P3-049 TEST rejection") || serialized.includes("Tool execution was not approved");
}

function buildAgent(db: SupabaseClient, hitlId: string, authorizationDecision: string) {
  const evidenceTool = tool({
    name: TOOL_NAME,
    description: "P3-049 TEST-only evidence action. It never calls Gmail, Make write APIs, or any provider write path.",
    parameters: {
      type: "object",
      properties: {
        hitl_id: { type: "string" },
        resource_key: { type: "string" },
        action: { type: "string" },
      },
      required: ["hitl_id", "resource_key", "action"],
      additionalProperties: false,
    } as any,
    needsApproval: async () => authorizationDecision === "APPROVAL_REQUIRED",
    execute: async (args: any) => {
      if (args.hitl_id !== hitlId || args.resource_key !== RESOURCE_KEY || args.action !== ACTION_KEY) throw new Error("HITL_TOOL_SCOPE_MISMATCH");
      const { data, error } = await db.from("sis_agent_hitl_runs")
        .update({ tool_execution_count: 1, updated_at: new Date().toISOString() })
        .eq("id", hitlId)
        .eq("status", "pending_approval")
        .eq("tool_execution_count", 0)
        .select("id")
        .maybeSingle();
      if (error || !data) throw new Error("HITL_EVIDENCE_TOOL_NOT_IDEMPOTENT");
      return "EVIDENCE_ONLY_EXECUTED_NO_PROVIDER_WRITE";
    },
  });

  const model: any = {
    name: "p3-049-deterministic-hitl-model-v1",
    async getResponse(request: any) {
      if (!modelHasToolResult(request.input)) {
        return {
          usage: new Usage(),
          output: [{
            type: "function_call",
            name: TOOL_NAME,
            arguments: JSON.stringify({ hitl_id: hitlId, resource_key: RESOURCE_KEY, action: ACTION_KEY }),
            callId: `call_${hitlId.replaceAll("-", "")}`,
            status: "completed",
          }],
        } as any;
      }
      return {
        usage: new Usage(),
        output: [{
          type: "message",
          role: "assistant",
          status: "completed",
          content: [{ type: "output_text", text: "P3-049 HITL pilot resumed and completed." }],
        }],
      } as any;
    },
    async *getStreamedResponse() {
      yield { type: "response.completed", response: { output: [], usage: new Usage() } } as any;
    },
  };

  return new Agent({
    name: "P3-049 HITL Pilot Agent",
    instructions: "Run only the TEST-only evidence tool. Never call external providers or perform Gmail writes.",
    model,
    tools: [evidenceTool],
  });
}

async function startHitl(db: SupabaseClient) {
  const hitlId = crypto.randomUUID();
  const authorization = await p3048Decision(db, hitlId);
  const requestedTraceId = newTraceId();
  const groupId = `P3-049:HITL:GMA-002:${hitlId.slice(0, 8)}`;
  const now = new Date().toISOString();

  const { error: insertError } = await db.from("sis_agent_hitl_runs").insert({
    id: hitlId,
    work_item_key: WORK_ITEM,
    observed_work_item_key: OBSERVED_WORK_ITEM,
    environment_key: ENVIRONMENT,
    actor_key: STARTER,
    capability_key: CAPABILITY,
    resource_key: RESOURCE_KEY,
    action_key: ACTION_KEY,
    authorization_policy_version: String(authorization.policy_version),
    authorization_decision: String(authorization.decision),
    authorization_evaluation_id: authorization.evaluation_id ?? null,
    status: "created",
    sdk_version: SDK_VERSION,
    trace_id: requestedTraceId,
    trace_group_id: groupId,
    metadata: {
      p3_048_reason_codes: authorization.reason_codes ?? [],
      shadow_only_resource: true,
      evidence_only_tool: true,
    },
    created_at: now,
    updated_at: now,
  });
  if (insertError) throw new Error(`HITL_ROW_CREATE_FAILED:${insertError.message}`);

  const agent = buildAgent(db, hitlId, String(authorization.decision));
  try {
    const result = await run(agent, "Execute the P3-049 TEST-only evidence action.", {
      workflowName: "SIS P3-049 HITL Phase 2",
      traceId: requestedTraceId,
      groupId,
      traceIncludeSensitiveData: false,
      traceMetadata: {
        work_item_key: WORK_ITEM,
        observed_work_item_key: OBSERVED_WORK_ITEM,
        environment_key: ENVIRONMENT,
        hitl_id: hitlId,
        p3_048_decision: "APPROVAL_REQUIRED",
      },
      maxTurns: 3,
    } as any);

    await getGlobalTraceProvider().forceFlush();
    const interruptions = result.interruptions ?? [];
    if (interruptions.length !== 1) throw new Error(`EXPECTED_ONE_INTERRUPTION_GOT_${interruptions.length}`);

    const state = result.state.toString({ includeTracingApiKey: false });
    const canonicalTraceId = serializedTraceId(state);
    if (!canonicalTraceId) throw new Error("SERIALIZED_TRACE_ID_MISSING_AT_INTERRUPTION");
    const stateHash = await sha256(state);
    const interruption: any = interruptions[0];
    const toolCallId = interruption.rawItem?.callId ?? interruption.rawItem?.call_id ?? null;

    const { error } = await db.from("sis_agent_hitl_runs").update({
      status: "pending_approval",
      sdk_state: state,
      state_sha256: stateHash,
      interruption_count: 1,
      tool_name: String(interruption.name ?? TOOL_NAME),
      tool_call_id: toolCallId,
      updated_at: new Date().toISOString(),
    }).eq("id", hitlId).eq("status", "created");
    if (error) throw new Error(`HITL_PENDING_PERSIST_FAILED:${error.message}`);

    return {
      ok: true,
      hitl_id: hitlId,
      status: "pending_approval",
      p3_048_decision: authorization.decision,
      interruption_count: 1,
      tool_name: String(interruption.name ?? TOOL_NAME),
      trace_id: canonicalTraceId,
      trace_group_id: groupId,
      state_sha256: stateHash,
      tool_execution_count: 0,
      provider_write_performed: false,
      mail_write_performed: false,
    };
  } catch (error) {
    await db.from("sis_agent_hitl_runs").update({
      status: "failed",
      error_summary: String(error).slice(0, 300),
      updated_at: new Date().toISOString(),
    }).eq("id", hitlId);
    throw error;
  }
}

async function resolveHitl(db: SupabaseClient, hitlId: string, decision: "approve" | "reject") {
  const { data: row, error } = await db.from("sis_agent_hitl_runs").select("*").eq("id", hitlId).maybeSingle();
  if (error || !row) throw new Error("HITL_RUN_NOT_FOUND");
  if (row.status !== "pending_approval" || !row.sdk_state || !row.state_sha256) throw new Error("HITL_RUN_NOT_PENDING");
  if (row.authorization_decision !== "APPROVAL_REQUIRED") throw new Error("HITL_AUTHORIZATION_STATE_INVALID");
  if (await sha256(row.sdk_state) !== row.state_sha256) throw new Error("HITL_SERIALIZED_STATE_HASH_MISMATCH");

  const agent = buildAgent(db, hitlId, row.authorization_decision);
  const state = await RunState.fromString(agent, row.sdk_state);
  const interruptions = state.getInterruptions();
  if (interruptions.length !== 1) throw new Error(`RESTORED_INTERRUPTION_COUNT_${interruptions.length}`);

  const restoredSerialized = state.toString({ includeTracingApiKey: false });
  const restoredTraceId = serializedTraceId(restoredSerialized);
  if (restoredTraceId !== row.trace_id) throw new Error("RESTORED_SERIALIZED_TRACE_ID_MISMATCH");

  if (decision === "approve") state.approve(interruptions[0]);
  else state.reject(interruptions[0], { message: "P3-049 TEST rejection: no provider action executed." });

  const result = await run(agent, state, { traceIncludeSensitiveData: false, maxTurns: 3 } as any);
  await getGlobalTraceProvider().forceFlush();
  if ((result.interruptions ?? []).length !== 0) throw new Error("HITL_RESUME_STILL_INTERRUPTED");

  const resumedSerialized = result.state.toString({ includeTracingApiKey: false });
  const resumedTraceId = serializedTraceId(resumedSerialized);
  if (resumedTraceId !== row.trace_id) throw new Error("RESUMED_SERIALIZED_TRACE_ID_MISMATCH");
  const resumedHash = await sha256(resumedSerialized);

  const { data: countRow } = await db.from("sis_agent_hitl_runs").select("tool_execution_count").eq("id", hitlId).single();
  const toolCount = Number(countRow?.tool_execution_count ?? 0);
  if (decision === "approve" && toolCount !== 1) throw new Error("APPROVED_TOOL_DID_NOT_EXECUTE_EXACTLY_ONCE");
  if (decision === "reject" && toolCount !== 0) throw new Error("REJECTED_TOOL_EXECUTED");

  const finalOutput = String(result.finalOutput ?? "").slice(0, 300);
  const status = decision === "approve" ? "approved_resumed" : "rejected_resumed";
  const { error: updateError } = await db.from("sis_agent_hitl_runs").update({
    status,
    resolution: decision,
    resolver_worker_key: RESOLVER,
    resumed_state_sha256: resumedHash,
    sdk_state: null,
    final_output: finalOutput,
    resolved_at: new Date().toISOString(),
    updated_at: new Date().toISOString(),
  }).eq("id", hitlId).eq("status", "pending_approval");
  if (updateError) throw new Error(`HITL_RESOLUTION_PERSIST_FAILED:${updateError.message}`);

  return {
    ok: true,
    hitl_id: hitlId,
    resolution: decision,
    status,
    trace_id: row.trace_id,
    same_trace_resumed: true,
    interruption_count_after_resume: 0,
    tool_execution_count: toolCount,
    final_output: finalOutput,
    provider_write_performed: false,
    mail_write_performed: false,
  };
}

const traceDb = clients("Bearer bootstrap").admin;
setTracingDisabled(false);
setTraceProcessors([new SisTraceProcessor(traceDb)]);

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ ok: false, error: "METHOD_NOT_ALLOWED" }, 405);
  const path = routePath(req);
  try {
    if (path === "/start") return json(await startHitl(await authorizeCaller(req, STARTER)));
    if (path === "/resolve") {
      const db = await authorizeCaller(req, RESOLVER);
      let body: Record<string, unknown> = {};
      try { body = await req.json(); } catch { return json({ ok: false, error: "JSON_REQUIRED" }, 400); }
      const hitlId = String(body.hitl_id ?? "");
      const decision = String(body.decision ?? "");
      if (!/^[0-9a-f-]{36}$/i.test(hitlId) || !["approve", "reject"].includes(decision)) return json({ ok: false, error: "RESOLUTION_INPUT_INVALID" }, 400);
      return json(await resolveHitl(db, hitlId, decision as "approve" | "reject"));
    }
    return json({ ok: false, error: "ROUTE_NOT_FOUND" }, 404);
  } catch (error) {
    const message = String(error instanceof Error ? error.message : error).slice(0, 300);
    const authError = message.includes("AUTHORIZATION_REQUIRED") || message.includes("AUTHENTICATED_SUBJECT_REQUIRED") || message.includes("BOUND_RUNTIME_SUBJECT_REQUIRED");
    return json({ ok: false, error: message }, authError ? 401 : 409);
  }
});
