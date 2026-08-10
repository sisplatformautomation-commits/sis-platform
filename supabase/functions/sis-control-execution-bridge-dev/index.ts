import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const TEST_URL = "https://ohoqdlufghlhmceokgpv.supabase.co";
const TEST_API_KEY = "sb_publishable_5CsZItJwW4KvNnjdHSjV8w_F5hFHsTW";
const JOB_ID = "0e90d6ed-337d-4382-aae6-cef841c8a641";
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info",
  "Access-Control-Allow-Methods": "GET,POST,OPTIONS",
};
const json = (data: unknown, status=200) => new Response(JSON.stringify(data), {status, headers:{...cors,"Content-Type":"application/json","Cache-Control":"no-store"}});

async function subjectFromTestJwt(req: Request): Promise<string | null> {
  const authorization = req.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) return null;
  const r = await fetch(`${TEST_URL}/auth/v1/user`, {headers:{Authorization:authorization, apikey:TEST_API_KEY}});
  if (!r.ok) return null;
  const u = await r.json().catch(()=>null);
  return typeof u?.id === "string" ? u.id : null;
}

function route(req: Request) {
  const parts = new URL(req.url).pathname.split("/").filter(Boolean);
  const i = parts.lastIndexOf("sis-control-execution-bridge-dev");
  return "/" + (i >= 0 ? parts.slice(i+1).join("/") : (parts.at(-1) ?? ""));
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null,{status:204,headers:cors});
  const subject = await subjectFromTestJwt(req);
  if (!subject) return json({ok:false,error:"TEST_WORKER_JWT_REQUIRED"},401);
  const url = Deno.env.get("SUPABASE_URL");
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !service) return json({ok:false,error:"CONTROL_RUNTIME_CONFIGURATION_MISSING"},500);
  const db = createClient(url,service,{auth:{persistSession:false,autoRefreshToken:false}});
  const path = route(req);
  let body:any = {};
  if (req.method === "POST") { try { body = await req.json(); } catch { body = {}; } }
  const sid = typeof body.session_id === "string" ? body.session_id : null;
  let data:any, error:any;

  if (req.method === "POST" && (path === "/claim" || path === "/")) {
    ({data,error}=await db.rpc("sis_control_execution_claim_v1",{p_auth_subject:subject,p_environment_key:"dev",p_job_id:JOB_ID,p_lease_seconds:900}));
  } else if (req.method === "POST" && path === "/heartbeat") {
    if (!sid) return json({ok:false,error:"SESSION_REQUIRED"},400);
    ({data,error}=await db.rpc("sis_control_execution_heartbeat_v1",{p_auth_subject:subject,p_session_id:sid,p_extend_seconds:900}));
  } else if (req.method === "POST" && path === "/step") {
    if (!sid) return json({ok:false,error:"SESSION_REQUIRED"},400);
    ({data,error}=await db.rpc("sis_control_execution_step_v1",{p_auth_subject:subject,p_session_id:sid,p_operation:String(body.operation??""),p_status:String(body.status??""),p_summary:(body.summary&&typeof body.summary==="object"&&!Array.isArray(body.summary))?body.summary:{}}));
  } else if (req.method === "POST" && path === "/submit") {
    if (!sid) return json({ok:false,error:"SESSION_REQUIRED"},400);
    ({data,error}=await db.rpc("sis_control_execution_submit_v1",{p_auth_subject:subject,p_session_id:sid,p_result:(body.result&&typeof body.result==="object"&&!Array.isArray(body.result))?body.result:{}}));
  } else if (req.method === "POST" && path === "/fail") {
    if (!sid) return json({ok:false,error:"SESSION_REQUIRED"},400);
    ({data,error}=await db.rpc("sis_control_execution_fail_v1",{p_auth_subject:subject,p_session_id:sid,p_error_code:String(body.error_code??"WORKER_FAILED"),p_error_message:String(body.error_message??"Worker failed"),p_evidence:(body.evidence&&typeof body.evidence==="object"&&!Array.isArray(body.evidence))?body.evidence:{}}));
  } else if (req.method === "GET" && path === "/review-context") {
    ({data,error}=await db.rpc("sis_control_execution_review_context_v1",{p_auth_subject:subject,p_job_id:JOB_ID}));
  } else if (req.method === "POST" && path === "/review-submit") {
    ({data,error}=await db.rpc("sis_control_execution_review_submit_v1",{p_auth_subject:subject,p_job_id:JOB_ID,p_decision:String(body.decision??""),p_evidence:(body.evidence&&typeof body.evidence==="object"&&!Array.isArray(body.evidence))?body.evidence:{}}));
  } else return json({ok:false,error:"ROUTE_NOT_FOUND"},404);

  if (error) {
    const known=["CONTROL_EXECUTION_WORKER_BINDING_REQUIRED","P3_046_DEV_INTEGRATION_WORKER_REQUIRED","P3_046_JOB_REQUIRED","JOB_BINDING_MISMATCH","JOB_NOT_CLAIMABLE","APPROVAL_GATE_NOT_SATISFIED","P3_043_RESOURCE_BINDING_REQUIRED","MAX_ATTEMPTS_EXCEEDED","CONTROL_EXECUTION_SESSION_NOT_RUNNING","OPERATION_NOT_ALLOWED","INVALID_STEP_STATUS","CONTROL_EXECUTION_REVIEWER_BINDING_REQUIRED","REVIEW_NOT_READY"];
    const code=known.find(x=>String(error.message??"").includes(x))??"CONTROL_EXECUTION_BRIDGE_FAILED";
    return json({ok:false,error:code},409);
  }
  return json(data??{ok:true});
});