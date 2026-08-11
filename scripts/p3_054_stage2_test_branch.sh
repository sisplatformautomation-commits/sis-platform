#!/usr/bin/env bash
set -euo pipefail
umask 077
set +x

MODE="${1:-preflight}"
PARENT_REF="${P3_054_PARENT_PROJECT_REF:-uwgkwyxjuikqxsezkezj}"
TEST_BRANCH_NAME="${P3_054_TEST_BRANCH_NAME:-sis-platform-test}"
TEST_REF="${P3_054_TEST_PROJECT_REF:-ohoqdlufghlhmceokgpv}"
MODEL="${SIS_SUPERVISOR_MODEL:-gpt-5.6-terra}"
RUN_TAG="${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
TMP_DIR="${RUNNER_TEMP:-/tmp}/p3-054-stage2-${RUN_TAG}"
BRANCH_ENV_FILE="${TMP_DIR}/branch.env"
mkdir -p "${TMP_DIR}"

fail() {
  echo "P3-054 FAIL: $*" >&2
  exit 1
}

summary() {
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '%s\n' "$*" >> "${GITHUB_STEP_SUMMARY}"
  else
    printf '%s\n' "$*"
  fi
}

mask_value() {
  local value="${1:-}"
  if [ -n "${value}" ] && [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "::add-mask::${value}"
  fi
}

branch_ref_from_json() {
  jq -r '
    .project_ref // .project_id // .preview_project.project_ref // .preview_project.ref //
    (.branch.project_ref // empty) // empty
  ' 2>/dev/null | head -n 1
}

load_branch_context() {
  [ -n "${SUPABASE_ACCESS_TOKEN:-}" ] || fail "SUPABASE_ACCESS_TOKEN is missing"
  [ "${PARENT_REF}" != "${TEST_REF}" ] || fail "TEST ref must never equal parent/PROD ref"
  export SUPABASE_PROJECT_ID="${PARENT_REF}"

  local branch_json actual_ref
  branch_json="$(supabase --experimental branches get "${TEST_BRANCH_NAME}" -o json)"
  actual_ref="$(printf '%s' "${branch_json}" | branch_ref_from_json)"
  if [ -z "${actual_ref}" ]; then
    local list_json
    list_json="$(supabase --experimental branches list -o json)"
    actual_ref="$(printf '%s' "${list_json}" | jq -r --arg name "${TEST_BRANCH_NAME}" '
      (if type == "array" then . else (.branches // []) end)[]? |
      select((.name // .branch_name // .git_branch // "") == $name) |
      (.project_ref // .project_id // .preview_project.project_ref // .preview_project.ref // empty)
    ' | head -n 1)"
  fi
  [ "${actual_ref}" = "${TEST_REF}" ] || fail "branch target mismatch: expected ${TEST_REF}, got ${actual_ref:-unknown}"

  supabase --experimental branches get "${TEST_BRANCH_NAME}" -o env > "${BRANCH_ENV_FILE}"
  while IFS= read -r line; do
    case "${line}" in
      *TOKEN=*|*KEY=*|*PASSWORD=*|*SECRET=*)
        mask_value "${line#*=}"
        ;;
    esac
  done < "${BRANCH_ENV_FILE}"

  set -a
  # shellcheck disable=SC1090
  source "${BRANCH_ENV_FILE}"
  set +a

  [ -n "${POSTGRES_URL_NON_POOLING:-}" ] || fail "branch credentials did not expose POSTGRES_URL_NON_POOLING"
  mask_value "${POSTGRES_URL_NON_POOLING}"

  summary "### P3-054 TEST branch target"
  summary "- branch: \`${TEST_BRANCH_NAME}\`"
  summary "- project ref: \`${actual_ref}\`"
  summary "- parent/PROD ref: \`${PARENT_REF}\` (explicitly excluded from mutation)"
  summary "- branch env names: \`$(sed -E 's/^export[[:space:]]+//' "${BRANCH_ENV_FILE}" | cut -d= -f1 | tr '\n' ' ' | sed -E 's/[[:space:]]+$//')\`"
}

psql_scalar() {
  psql "${POSTGRES_URL_NON_POOLING}" -X -v ON_ERROR_STOP=1 -Atqc "$1"
}

check_contracts() {
  local object_json migration_count required_extra auth_type
  object_json="$(psql_scalar "select jsonb_build_object(
    'runtime_bindings',to_regclass('public.sis_agent_runtime_bindings') is not null,
    'controller_state',to_regclass('public.sis_controller_runtime_state') is not null,
    'controller_dispatches',to_regclass('public.sis_controller_dispatches') is not null,
    'controller_start',to_regprocedure('public.sis_execution_controller_start_v1(text,text,text,text,jsonb)') is not null,
    'controller_tick',to_regprocedure('public.sis_controller_consumer_tick_v1(text,timestamptz,integer,integer)') is not null,
    'dispatch_claim',to_regprocedure('public.sis_supervisor_dispatch_claim_v1(integer)') is not null,
    'submit_plan',to_regprocedure('public.sis_supervisor_dispatch_submit_plan_v1(uuid,uuid,jsonb)') is not null,
    'controller_stop',to_regprocedure('public.sis_controller_consumer_stop_v1(uuid,text)') is not null,
    'programs',to_regclass('public.sis_programs') is not null,
    'business_cases',to_regclass('public.sis_business_cases') is not null,
    'work_items',to_regclass('public.sis_work_items') is not null
  )::text;")"
  printf '%s' "${object_json}" | jq -e 'to_entries | all(.value == true)' >/dev/null || fail "required P3-054 TEST schema/RPC contract is incomplete: ${object_json}"

  migration_count="$(psql_scalar "select count(*) from supabase_migrations.schema_migrations where version='20260811072300';")"
  [ "${migration_count}" = "1" ] || fail "canonical P3-054 Stage1 migration 20260811072300 is not recorded in TEST"

  required_extra="$(psql_scalar "select coalesce(string_agg(column_name,',' order by ordinal_position),'') from information_schema.columns where table_schema='public' and table_name='sis_agent_runtime_bindings' and is_nullable='NO' and column_default is null and column_name not in ('id','worker_key','environment_key','auth_subject','status','metadata');")"
  [ -z "${required_extra}" ] || fail "runtime binding has unsupported required columns: ${required_extra}"

  auth_type="$(psql_scalar "select data_type from information_schema.columns where table_schema='public' and table_name='sis_agent_runtime_bindings' and column_name='auth_subject';")"
  [ "${auth_type}" = "uuid" ] || fail "runtime binding auth_subject must be uuid"

  local openai_secret_json
  openai_secret_json="$(supabase secrets list --project-ref "${TEST_REF}" -o json)"
  printf '%s' "${openai_secret_json}" | jq -e '.. | strings | select(. == "OPENAI_API_KEY")' >/dev/null || fail "OPENAI_API_KEY is not configured on the TEST branch"

  local supervisor_binding_count runtime_state
  supervisor_binding_count="$(psql_scalar "select count(*) from public.sis_agent_runtime_bindings where worker_key='sis.supervisor' and environment_key='test' and status='active';")"
  runtime_state="$(psql_scalar "select coalesce(jsonb_build_object('status',status,'heartbeat_at',heartbeat_at,'lease_expires_at',lease_expires_at,'last_tick_at',last_tick_at,'recovery_count',recovery_count)::text,'null') from public.sis_controller_runtime_state where environment_key='test';")"

  summary "### P3-054 TEST schema preflight"
  summary "- required objects/RPCs: PASS"
  summary "- canonical Stage1 migration 20260811072300: present"
  summary "- OPENAI_API_KEY: present (value not read)"
  summary "- active TEST supervisor bindings: ${supervisor_binding_count}"
  summary "- controller runtime state: \`${runtime_state}\`"
}

preflight() {
  load_branch_context
  check_contracts
  summary "- preflight result: **PASS**"
}

pick_api_keys() {
  PUBLISHABLE_KEY="${SUPABASE_PUBLISHABLE_KEY:-${SUPABASE_ANON_KEY:-${ANON_KEY:-}}}"
  SECRET_KEY="${SUPABASE_SECRET_KEY:-${SUPABASE_SERVICE_ROLE_KEY:-${SERVICE_ROLE_KEY:-}}}"
  [ -n "${PUBLISHABLE_KEY}" ] || fail "branch credentials did not expose a publishable/anon API key"
  [ -n "${SECRET_KEY}" ] || fail "branch credentials did not expose a secret/service-role API key"
  mask_value "${PUBLISHABLE_KEY}"
  mask_value "${SECRET_KEY}"
  BRANCH_URL="${SUPABASE_URL:-https://${TEST_REF}.supabase.co}"
}

SMOKE_USER_ID=""
SMOKE_WORK_ITEM_KEY=""
SMOKE_ACTIVATION_ID=""
SMOKE_BINDING_CREATED="false"

cleanup_smoke() {
  set +e
  if [ -n "${SMOKE_ACTIVATION_ID}" ] && [ -n "${POSTGRES_URL_NON_POOLING:-}" ]; then
    psql "${POSTGRES_URL_NON_POOLING}" -X -v ON_ERROR_STOP=0 -Atqc "select public.sis_controller_consumer_stop_v1('${SMOKE_ACTIVATION_ID}'::uuid,'P3-054 Stage2 CI smoke cleanup');" >/dev/null 2>&1
  fi
  if [ -n "${SMOKE_WORK_ITEM_KEY}" ] && [ -n "${POSTGRES_URL_NON_POOLING:-}" ]; then
    psql "${POSTGRES_URL_NON_POOLING}" -X -v ON_ERROR_STOP=0 -Atqc "update public.sis_work_items set status='cancelled',completed_at=coalesce(completed_at,now()),metadata=metadata||jsonb_build_object('p3_054_smoke_cleanup',true,'p3_054_smoke_run','${RUN_TAG}'),updated_at=now() where item_key='${SMOKE_WORK_ITEM_KEY}' and status not in ('done','cancelled');" >/dev/null 2>&1
  fi
  if [ "${SMOKE_BINDING_CREATED}" = "true" ] && [ -n "${SMOKE_USER_ID}" ] && [ -n "${POSTGRES_URL_NON_POOLING:-}" ]; then
    psql "${POSTGRES_URL_NON_POOLING}" -X -v ON_ERROR_STOP=0 -Atqc "delete from public.sis_agent_runtime_bindings where worker_key='sis.supervisor' and environment_key='test' and auth_subject='${SMOKE_USER_ID}'::uuid and metadata->>'p3_054_smoke_run'='${RUN_TAG}';" >/dev/null 2>&1
  fi
  if [ -n "${SMOKE_USER_ID}" ] && [ -n "${SECRET_KEY:-}" ] && [ -n "${BRANCH_URL:-}" ]; then
    curl -sS -o /dev/null -X DELETE "${BRANCH_URL}/auth/v1/admin/users/${SMOKE_USER_ID}" \
      -H "apikey: ${SECRET_KEY}" -H "Authorization: Bearer ${SECRET_KEY}" >/dev/null 2>&1
  fi
  set -e
}

create_smoke_fixture() {
  local program_key bc_key bc_id
  program_key="P3_054_STAGE2_SMOKE_PROGRAM"
  bc_key="P3_054_STAGE2_SMOKE"
  SMOKE_WORK_ITEM_KEY="P3-054-STAGE2-SMOKE-${RUN_TAG//[^A-Za-z0-9_-]/-}"

  psql "${POSTGRES_URL_NON_POOLING}" -X -v ON_ERROR_STOP=1 \
    -v program_key="${program_key}" -v bc_key="${bc_key}" -v work_key="${SMOKE_WORK_ITEM_KEY}" -v run_tag="${RUN_TAG}" <<'SQL' >/dev/null
insert into public.sis_programs(program_key,name,description,status,metadata)
select :'program_key','P3-054 Stage2 TEST Smoke Program','Synthetic DEV/TEST-only P3-054 reasoner smoke fixture','active',jsonb_build_object('synthetic',true,'p3','P3-054')
where not exists(select 1 from public.sis_programs where program_key=:'program_key');

insert into public.sis_business_cases(program_id,business_case_key,name,description,metadata)
select p.id,:'bc_key','P3-054 Stage2 TEST Smoke','Synthetic read-only autonomous supervisor smoke fixture',jsonb_build_object('synthetic',true,'p3','P3-054')
from public.sis_programs p
where p.program_key=:'program_key'
  and not exists(select 1 from public.sis_business_cases where business_case_key=:'bc_key');

insert into public.sis_work_items(
  business_case_id,item_key,title,description,status,priority,assigned_to,
  execution_mode,requires_approval,input,metadata
)
select b.id,:'work_key','P3-054 Stage2 reasoner smoke',
  'Plan exactly one small read-only evidence job. Prefer runtime.read. Do not request provider writes, migrations, repository changes, destructive actions, financial writes, PROD, or P3-048 cutover.',
  'in_progress','critical','sis.supervisor','dev_test_autonomous_controller_runtime',false,
  jsonb_build_object('synthetic',true,'environment','test'),
  jsonb_build_object('synthetic',true,'p3','P3-054','p3_054_smoke_run',:'run_tag','current_stage','stage2_reasoner_smoke')
from public.sis_business_cases b
where b.business_case_key=:'bc_key'
  and not exists(select 1 from public.sis_work_items where item_key=:'work_key');
SQL

  bc_id="$(psql_scalar "select id from public.sis_business_cases where business_case_key='${bc_key}' order by created_at limit 1;")"
  [ -n "${bc_id}" ] || fail "failed to resolve smoke business case"
}

deploy_smoke() {
  [ "${P3_054_CONFIRM_TEST_REF:-}" = "${TEST_REF}" ] || fail "deploy-smoke requires exact confirm_test_ref=${TEST_REF}"
  preflight
  pick_api_keys
  trap cleanup_smoke EXIT

  summary "### P3-054 Stage2 deploy-smoke"
  summary "- model requested: \`${MODEL}\`"

  supabase secrets set --project-ref "${TEST_REF}" "SIS_SUPERVISOR_MODEL=${MODEL}" >/dev/null
  supabase functions deploy sis-agent-runtime-dev --project-ref "${TEST_REF}" --use-api >/dev/null
  supabase functions deploy sis-agent-runtime-test --project-ref "${TEST_REF}" --use-api >/dev/null

  local unauth_code
  unauth_code="$(curl -sS -o "${TMP_DIR}/unauth.json" -w '%{http_code}' -X POST \
    "${BRANCH_URL}/functions/v1/sis-agent-runtime-test/orchestration/reason" \
    -H 'Content-Type: application/json' -d '{}')"
  [ "${unauth_code}" = "401" ] || fail "JWT-only guard failed; unauthenticated reason route returned HTTP ${unauth_code}"
  summary "- JWT-only unauthenticated guard: PASS (401)"

  local smoke_email smoke_password create_user_json login_json access_token
  smoke_email="p3-054-stage2-${RUN_TAG}@example.invalid"
  smoke_password="$(openssl rand -base64 36 | tr -d '\n' | tr '/+' '_-')Aa1!"
  mask_value "${smoke_password}"

  create_user_json="$(curl -fsS -X POST "${BRANCH_URL}/auth/v1/admin/users" \
    -H "apikey: ${SECRET_KEY}" -H "Authorization: Bearer ${SECRET_KEY}" -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg e "${smoke_email}" --arg p "${smoke_password}" '{email:$e,password:$p,email_confirm:true,user_metadata:{p3_054_smoke:true}}')")"
  SMOKE_USER_ID="$(printf '%s' "${create_user_json}" | jq -r '.id // empty')"
  [ -n "${SMOKE_USER_ID}" ] || fail "failed to create ephemeral TEST auth subject"

  local has_id
  has_id="$(psql_scalar "select count(*) from information_schema.columns where table_schema='public' and table_name='sis_agent_runtime_bindings' and column_name='id';")"
  if [ "${has_id}" = "1" ]; then
    psql_scalar "insert into public.sis_agent_runtime_bindings(id,worker_key,environment_key,auth_subject,status,metadata) values(gen_random_uuid(),'sis.supervisor','test','${SMOKE_USER_ID}'::uuid,'active',jsonb_build_object('synthetic',true,'p3','P3-054','p3_054_smoke_run','${RUN_TAG}')) returning auth_subject;" >/dev/null
  else
    psql_scalar "insert into public.sis_agent_runtime_bindings(worker_key,environment_key,auth_subject,status,metadata) values('sis.supervisor','test','${SMOKE_USER_ID}'::uuid,'active',jsonb_build_object('synthetic',true,'p3','P3-054','p3_054_smoke_run','${RUN_TAG}')) returning auth_subject;" >/dev/null
  fi
  SMOKE_BINDING_CREATED="true"

  login_json="$(curl -fsS -X POST "${BRANCH_URL}/auth/v1/token?grant_type=password" \
    -H "apikey: ${PUBLISHABLE_KEY}" -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg e "${smoke_email}" --arg p "${smoke_password}" '{email:$e,password:$p}')")"
  access_token="$(printf '%s' "${login_json}" | jq -r '.access_token // empty')"
  [ -n "${access_token}" ] || fail "failed to obtain ephemeral TEST supervisor JWT"
  mask_value "${access_token}"

  create_smoke_fixture

  local activation_json tick_json
  activation_json="$(psql_scalar "select public.sis_execution_controller_start_v1('${SMOKE_WORK_ITEM_KEY}','test','execute','p3-054-ci-smoke',jsonb_build_object('reasoner_mode','read_only_autonomous','synthetic',true,'p3_054_smoke_run','${RUN_TAG}','prod',false,'provider_writes',false,'p3_048_cutover',false))::text;")"
  SMOKE_ACTIVATION_ID="$(printf '%s' "${activation_json}" | jq -r '.activation_id // empty')"
  [ -n "${SMOKE_ACTIVATION_ID}" ] || fail "execution controller did not create smoke activation"
  tick_json="$(psql_scalar "select public.sis_controller_consumer_tick_v1('test',now(),10,120)::text;")"
  printf '%s' "${tick_json}" | jq -e '.ok == true' >/dev/null || fail "controller tick failed"

  local reason_file reason_code reason_json smoke_job_id
  reason_file="${TMP_DIR}/reason.json"
  reason_code="$(curl -sS -o "${reason_file}" -w '%{http_code}' -X POST \
    "${BRANCH_URL}/functions/v1/sis-agent-runtime-test/orchestration/reason" \
    -H "apikey: ${PUBLISHABLE_KEY}" -H "Authorization: Bearer ${access_token}" -H 'Content-Type: application/json' -d '{}')"
  reason_json="$(cat "${reason_file}")"
  [ "${reason_code}" = "200" ] || fail "Stage2 reasoner smoke failed HTTP ${reason_code}: $(printf '%s' "${reason_json}" | jq -c '{error,detail,status}' 2>/dev/null || true)"
  printf '%s' "${reason_json}" | jq -e --arg m "${MODEL}" '.ok == true and .status == "observing" and .model == $m' >/dev/null || fail "Stage2 reasoner did not reach observing with expected model"
  smoke_job_id="$(printf '%s' "${reason_json}" | jq -r 'if (.job_ids|type)=="array" then .job_ids[0] else .job_ids end // empty')"
  [ -n "${smoke_job_id}" ] || fail "Stage2 reasoner returned no job id"

  local job_evidence
  job_evidence="$(psql_scalar "select jsonb_build_object(
    'job_id',j.id,'job_status',j.status,'assigned_worker_key',a.assigned_worker_key,
    'required_capabilities',to_jsonb(a.required_capabilities),'required_resource_keys',to_jsonb(a.required_resource_keys),
    'approval_required',a.approval_required,'review_required',a.review_required,
    'risky_capability_count',(select count(*) from public.sis_agent_capabilities c where c.capability_key=any(a.required_capabilities) and (c.provider_write or c.external_financial_write or c.destructive)),
    'outside_allowlist_count',(select count(*) from unnest(a.required_capabilities) cap where cap not in ('database.read','runtime.read','finance.read','integration.provider_read'))
  )::text from public.sis_jobs j join public.sis_agent_job_assignments a on a.job_id=j.id where j.id='${smoke_job_id}'::uuid;")"
  printf '%s' "${job_evidence}" | jq -e '.risky_capability_count == 0 and .outside_allowlist_count == 0 and .approval_required == false' >/dev/null || fail "reasoner created a job outside the Stage2 safety contract"

  psql_scalar "select public.sis_controller_consumer_stop_v1('${SMOKE_ACTIVATION_ID}'::uuid,'P3-054 Stage2 TEST smoke passed; cancel synthetic job before execution')::text;" >/dev/null
  psql_scalar "update public.sis_work_items set status='cancelled',completed_at=coalesce(completed_at,now()),metadata=metadata||jsonb_build_object('p3_054_smoke_result','PASS','p3_054_smoke_run','${RUN_TAG}'),updated_at=now() where item_key='${SMOKE_WORK_ITEM_KEY}' and status not in ('done','cancelled') returning item_key;" >/dev/null
  SMOKE_ACTIVATION_ID=""

  summary "- Stage2 function deploy to TEST ref only: PASS"
  summary "- ephemeral JWT supervisor binding: PASS"
  summary "- real OpenAI reasoner call and one-job plan: PASS"
  summary "- plan allowlist/risk guard: PASS"
  summary "- synthetic job stopped before worker execution: PASS"
  summary "- PROD mutation: none"
  summary "- P3-048 cutover: none"
  summary "- continuous scheduler: **not activated by this workflow**; remains separately gated on the reviewed scheduler-identity design"
}

case "${MODE}" in
  preflight) preflight ;;
  deploy-smoke) deploy_smoke ;;
  *) fail "unknown mode: ${MODE}" ;;
esac
