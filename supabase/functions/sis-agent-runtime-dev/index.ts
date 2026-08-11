import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const SLUG = "sis-agent-runtime-dev";
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info",
  "Access-Control-Allow-Methods": "GET,POST,OPTIONS",
};

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...cors, "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

function routePath(req: Request) {
  const parts = new URL(req.url).pathname.split("/").filter(Boolean);
  const idx = parts.lastIndexOf(SLUG);
  return "/" + (idx >= 0 ? parts.slice(idx + 1).join("/") : parts.at(-1) ?? "");
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  const authorization = req.headers.get("Authorization");
  if (!authorization) return json({ ok: false, error: "AUTHORIZATION_REQUIRED" }, 401);
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  if (!supabaseUrl || !anonKey) return json({ ok: false, error: "RUNTIME_CONFIGURATION_MISSING" }, 500);
  const db = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const path = routePath(req);
  let body: Record<string, unknown> = {};
  if (req.method === "POST") { try { body = await req.json(); } catch { body = {}; } }
  let rpc = "";
  let args: Record<string, unknown> | undefined;

  if (req.method === "POST" && path === "/claim") { rpc = "sis_agent_runtime_claim_v1"; args = { p_lease_seconds: Number(body.lease_seconds ?? 900) }; }
  else if (req.method === "GET" && path === "/context") rpc = "sis_agent_runtime_context_v1";
  else if (req.method === "POST" && path === "/heartbeat") { rpc = "sis_agent_runtime_heartbeat_v1"; args = { p_extend_seconds: Number(body.extend_seconds ?? 900) }; }
  else if (req.method === "POST" && path === "/submit") { rpc = "sis_agent_runtime_submit_v1"; args = { p_result: body.result ?? {} }; }
  else if (req.method === "POST" && path === "/fail") { rpc = "sis_agent_runtime_fail_v1"; args = { p_error_code: String(body.error_code ?? "WORKER_FAILED"), p_error_message: String(body.error_message ?? "Worker failed"), p_evidence: body.evidence ?? {} }; }
  else if (req.method === "GET" && path === "/review/context") rpc = "sis_agent_runtime_reviewer_context_v1";
  else if (req.method === "POST" && path === "/review/submit") { rpc = "sis_agent_runtime_reviewer_submit_v1"; args = { p_decision: String(body.decision ?? ""), p_evidence: body.evidence ?? {} }; }
  else if (req.method === "POST" && path === "/orchestration/claim") { rpc = "sis_supervisor_dispatch_claim_v1"; args = { p_lease_seconds: Number(body.lease_seconds ?? 300) }; }
  else if (req.method === "POST" && path === "/orchestration/heartbeat") { rpc = "sis_supervisor_dispatch_heartbeat_v1"; args = { p_dispatch_id: String(body.dispatch_id ?? ""), p_lease_token: String(body.lease_token ?? ""), p_extend_seconds: Number(body.extend_seconds ?? 300) }; }
  else if (req.method === "POST" && path === "/orchestration/submit-plan") { rpc = "sis_supervisor_dispatch_submit_plan_v1"; args = { p_dispatch_id: String(body.dispatch_id ?? ""), p_lease_token: String(body.lease_token ?? ""), p_plan: body.plan ?? {} }; }
  else return json({ ok: false, error: "ROUTE_NOT_FOUND" }, 404);

  const { data, error } = args ? await db.rpc(rpc, args) : await db.rpc(rpc);
  if (error) {
    const known = [
      "UNAUTHENTICATED", "RUNTIME_BINDING_NOT_ACTIVE", "WORKER_BINDING_REQUIRED",
      "REVIEWER_BINDING_REQUIRED", "NO_ACTIVE_RUNTIME_SESSION", "NO_REVIEW_REQUIRED_JOB",
      "LEASE_NOT_VALID", "WORKER_NOT_ACTIVE", "INVALID_LEASE_SECONDS",
      "P3_054_SUPERVISOR_LEASE_INVALID", "P3_054_SUPERVISOR_LEASE_NOT_VALID",
      "P3_054_DISPATCH_NOT_FOUND", "P3_054_CAPABILITY_NOT_IN_DEV_TEST_AUTONOMY_ALLOWLIST",
      "P3_054_RISKY_CAPABILITY_BLOCKED"
    ];
    const code = known.find((x) => error.message.includes(x)) ?? "RUNTIME_RPC_FAILED";
    return json({ ok: false, error: code }, code === "UNAUTHENTICATED" ? 401 : 409);
  }
  return json(data ?? { ok: true });
});
