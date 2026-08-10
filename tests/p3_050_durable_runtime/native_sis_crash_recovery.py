import json, os, sqlite3, subprocess, sys, tempfile, time, uuid
from pathlib import Path

SCHEMA = '''
create table if not exists runs(
 id text primary key,
 status text not null,
 state text,
 state_hash text,
 tool_execution_count integer not null default 0 check(tool_execution_count between 0 and 1),
 resolution text,
 runtime_version integer,
 updated_at real not null,
 error text
);
'''

def db(path):
    con=sqlite3.connect(path)
    con.execute('pragma journal_mode=WAL')
    con.execute(SCHEMA)
    return con

def start(path, runtime_version):
    con=db(path); rid=str(uuid.uuid4()); state=json.dumps({'run_id':rid,'interruptions':[{'tool':'evidence'}]})
    import hashlib; h=hashlib.sha256(state.encode()).hexdigest()
    con.execute('insert into runs(id,status,state,state_hash,runtime_version,updated_at) values(?,?,?,?,?,?)',(rid,'pending_approval',state,h,runtime_version,time.time())); con.commit(); con.close();
    return rid

def resolve(path,rid,decision,runtime_version,crash_after_commit=False):
    con=db(path); row=con.execute('select status,state,state_hash,tool_execution_count from runs where id=?',(rid,)).fetchone()
    if not row: raise RuntimeError('RUN_NOT_FOUND')
    status,state,h,count=row
    if status!='pending_approval' or not state: raise RuntimeError('RUN_NOT_PENDING')
    import hashlib
    if hashlib.sha256(state.encode()).hexdigest()!=h: raise RuntimeError('STATE_HASH_MISMATCH')
    if decision=='approve':
        cur=con.execute('update runs set tool_execution_count=1,updated_at=? where id=? and status=? and tool_execution_count=0',(time.time(),rid,'pending_approval'))
        if cur.rowcount!=1:
            con.rollback(); con.close(); raise RuntimeError('EVIDENCE_ALREADY_COMMITTED')
        con.commit()
        if crash_after_commit:
            con.close(); os._exit(73)
        count=1
    else:
        count=0
    con.execute('update runs set status=?,resolution=?,state=null,runtime_version=?,updated_at=? where id=? and status=?',('approved_resumed' if decision=='approve' else 'rejected_resumed',decision,runtime_version,time.time(),rid,'pending_approval'))
    con.commit(); con.close(); return count

def row(path,rid):
    con=db(path); r=con.execute('select id,status,tool_execution_count,resolution,runtime_version,updated_at,error from runs where id=?',(rid,)).fetchone(); con.close();
    return {'id':r[0],'status':r[1],'tool_execution_count':r[2],'resolution':r[3],'runtime_version':r[4],'updated_at':r[5],'error':r[6]} if r else None

def child():
    op=sys.argv[2]; path=sys.argv[3]
    if op=='start':
        print(start(path,int(sys.argv[4])))
    elif op=='resolve':
        resolve(path,sys.argv[4],sys.argv[5],int(sys.argv[6]),False); print('ok')
    elif op=='resolve_crash':
        resolve(path,sys.argv[4],'approve',int(sys.argv[5]),True)
    return 0

def main():
    if len(sys.argv)>1 and sys.argv[1]=='child': return child()
    root=Path('/mnt/data/p3_050_durable_runtime')
    path=str(root/'native_sis_crash_recovery.sqlite')
    try: os.remove(path)
    except FileNotFoundError: pass
    results=[]

    # 1 process ends while pending; later process resumes
    p=subprocess.run([sys.executable,__file__,'child','start',path,'4'],capture_output=True,text=True,check=True)
    rid=p.stdout.strip(); before=row(path,rid)
    q=subprocess.run([sys.executable,__file__,'child','resolve',path,rid,'approve','4'],capture_output=True,text=True)
    after=row(path,rid)
    results.append({'case':'pause_process_exit_then_resume','pass':q.returncode==0 and before['status']=='pending_approval' and after['status']=='approved_resumed' and after['tool_execution_count']==1,'before':before,'after':after})

    # 2 runtime deployment version changes between pause/resume
    p=subprocess.run([sys.executable,__file__,'child','start',path,'3'],capture_output=True,text=True,check=True)
    rid=p.stdout.strip(); before=row(path,rid)
    q=subprocess.run([sys.executable,__file__,'child','resolve',path,rid,'approve','4'],capture_output=True,text=True)
    after=row(path,rid)
    results.append({'case':'resume_after_runtime_version_change','pass':q.returncode==0 and before['runtime_version']==3 and after['runtime_version']==4 and after['status']=='approved_resumed','before':before,'after':after})

    # 3 duplicate approval must not execute twice
    rid=start(path,4); resolve(path,rid,'approve',4)
    duplicate_error=None
    try: resolve(path,rid,'approve',4)
    except Exception as e: duplicate_error=str(e)
    after=row(path,rid)
    results.append({'case':'duplicate_approval_idempotency','pass':duplicate_error=='RUN_NOT_PENDING' and after['tool_execution_count']==1,'duplicate_error':duplicate_error,'after':after})

    # 4 crash after evidence commit, before completion ack
    rid=start(path,4)
    crash=subprocess.run([sys.executable,__file__,'child','resolve_crash',path,rid,'4'],capture_output=True,text=True)
    after_crash=row(path,rid)
    retry_error=None
    try: resolve(path,rid,'approve',4)
    except Exception as e: retry_error=str(e)
    after_retry=row(path,rid)
    results.append({'case':'crash_after_effect_commit_before_ack','pass':False,'expected_current_behavior':'fail_closed_but_not_auto_recoverable','crash_exit_code':crash.returncode,'after_crash':after_crash,'retry_error':retry_error,'after_retry':after_retry,'finding':'evidence is committed exactly once, but retry cannot complete the run because current guard treats committed evidence as an error rather than a replayable success'})

    # 5 orphaned pending run timeout recovery
    rid=start(path,4)
    con=db(path); con.execute('update runs set updated_at=? where id=?',(time.time()-7200,rid)); con.commit(); con.close()
    time.sleep(0.2)
    stale=row(path,rid)
    results.append({'case':'orphan_pending_timeout_recovery','pass':False,'stale_after_seconds':7200,'observed':stale,'finding':'current state model has no lease/expiry/sweeper transition, so an abandoned pending approval remains pending indefinitely'})

    out={'suite':'P3-050 SIS-native crash/recovery critical tests','model':'P3-049 status and idempotency semantics over durable SQLite persistence','passed':sum(1 for r in results if r['pass']),'total':len(results),'results':results,'engine_selection_made':False,'provider_writes':False,'gmail_writes':False,'prod_changes':False}
    (root/'native-sis-crash-recovery-result.json').write_text(json.dumps(out,indent=2),encoding='utf-8')
    print(json.dumps(out,indent=2))

if __name__=='__main__':
    raise SystemExit(main())
