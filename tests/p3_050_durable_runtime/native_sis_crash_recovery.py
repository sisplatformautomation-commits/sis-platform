import hashlib, json, os, sqlite3, subprocess, sys, tempfile, time, uuid

SCHEMA = '''
create table if not exists runs(
 id text primary key,
 status text not null,
 state text,
 state_hash text,
 tool_execution_count integer not null default 0 check(tool_execution_count between 0 and 1),
 resolution text,
 runtime_version integer,
 action_fingerprint text,
 approval_expires_at real,
 approval_recovery_state text not null default 'none',
 approval_recovery_count integer not null default 0,
 updated_at real not null
);
create table if not exists effects(
 action_fingerprint text primary key,
 run_id text not null,
 result_code text not null,
 replay_count integer not null default 0,
 committed_at real not null,
 updated_at real not null
);
'''

def db(path):
    con=sqlite3.connect(path)
    con.execute('pragma journal_mode=WAL')
    con.executescript(SCHEMA)
    return con

def fingerprint(rid):
    return hashlib.sha256(json.dumps({'v':1,'run_id':rid,'resource':'shadow','action':'evidence','tool':'evidence'},sort_keys=True).encode()).hexdigest()

def start(path, runtime_version, lease_seconds=3600):
    con=db(path); rid=str(uuid.uuid4()); state=json.dumps({'run_id':rid,'interruptions':[{'tool':'evidence'}]})
    h=hashlib.sha256(state.encode()).hexdigest(); now=time.time()
    con.execute('insert into runs(id,status,state,state_hash,runtime_version,approval_expires_at,approval_recovery_state,updated_at) values(?,?,?,?,?,?,?,?)',(rid,'pending_approval',state,h,runtime_version,now+lease_seconds,'active',now)); con.commit(); con.close();
    return rid

def commit_effect(con,rid):
    fp=fingerprint(rid); now=time.time()
    row=con.execute('select run_id,result_code,replay_count from effects where action_fingerprint=?',(fp,)).fetchone()
    if row:
        if row[0] != rid: raise RuntimeError('FINGERPRINT_COLLISION')
        con.execute('update effects set replay_count=replay_count+1,updated_at=? where action_fingerprint=?',(now,fp))
        con.execute('update runs set tool_execution_count=1,action_fingerprint=?,updated_at=? where id=?',(fp,now,rid))
        return {'replay':True,'result_code':row[1]}
    con.execute('insert into effects(action_fingerprint,run_id,result_code,replay_count,committed_at,updated_at) values(?,?,?,?,?,?)',(fp,rid,'EVIDENCE_ONLY_EXECUTED_NO_PROVIDER_WRITE',0,now,now))
    con.execute('update runs set tool_execution_count=1,action_fingerprint=?,updated_at=? where id=?',(fp,now,rid))
    return {'replay':False,'result_code':'EVIDENCE_ONLY_EXECUTED_NO_PROVIDER_WRITE'}

def resolve(path,rid,decision,runtime_version,crash_after_commit=False):
    con=db(path); row=con.execute('select status,state,state_hash,approval_expires_at,approval_recovery_state from runs where id=?',(rid,)).fetchone()
    if not row: raise RuntimeError('RUN_NOT_FOUND')
    status,state,h,expires,recovery=row
    if status!='pending_approval' or not state: raise RuntimeError('RUN_NOT_PENDING')
    if recovery!='active': raise RuntimeError('APPROVAL_NOT_ACTIVE')
    if expires is not None and expires <= time.time(): raise RuntimeError('APPROVAL_LEASE_EXPIRED')
    if hashlib.sha256(state.encode()).hexdigest()!=h: raise RuntimeError('STATE_HASH_MISMATCH')
    if decision=='approve':
        commit_effect(con,rid); con.commit()
        if crash_after_commit:
            con.close(); os._exit(73)
    status2='approved_resumed' if decision=='approve' else 'rejected_resumed'
    cur=con.execute('update runs set status=?,resolution=?,state=null,runtime_version=?,approval_expires_at=null,approval_recovery_state="none",updated_at=? where id=? and status="pending_approval" and approval_recovery_state="active"',(status2,decision,runtime_version,time.time(),rid))
    if cur.rowcount != 1: raise RuntimeError('FINALIZE_RACE')
    con.commit(); con.close()

def sweep(path, now):
    con=db(path)
    cur=con.execute('update runs set approval_recovery_state="expired_recoverable",updated_at=? where status="pending_approval" and approval_recovery_state="active" and approval_expires_at is not null and approval_expires_at<=?',(now,now))
    con.commit(); n=cur.rowcount; con.close(); return n

def recover(path,rid,extend=3600):
    con=db(path); row=con.execute('select status,state,state_hash,approval_recovery_state,approval_recovery_count from runs where id=?',(rid,)).fetchone()
    if not row or row[0]!='pending_approval' or row[3]!='expired_recoverable' or not row[1] or not row[2]: raise RuntimeError('RUN_NOT_EXPIRED_RECOVERABLE')
    now=time.time(); con.execute('update runs set approval_recovery_state="active",approval_recovery_count=approval_recovery_count+1,approval_expires_at=?,updated_at=? where id=?',(now+extend,now,rid)); con.commit(); con.close()

def row(path,rid):
    con=db(path); r=con.execute('select status,tool_execution_count,resolution,runtime_version,action_fingerprint,approval_expires_at,approval_recovery_state,approval_recovery_count,state is not null from runs where id=?',(rid,)).fetchone(); e=con.execute('select count(*),coalesce(max(replay_count),0) from effects where run_id=?',(rid,)).fetchone(); con.close()
    return {'status':r[0],'tool_execution_count':r[1],'resolution':r[2],'runtime_version':r[3],'fingerprint_set':r[4] is not None,'approval_expires_at':r[5],'approval_recovery_state':r[6],'approval_recovery_count':r[7],'state_present':bool(r[8]),'effect_rows':e[0],'effect_replay_count':e[1]}

def child():
    op,path=sys.argv[2],sys.argv[3]
    if op=='start': print(start(path,int(sys.argv[4])))
    elif op=='resolve': resolve(path,sys.argv[4],sys.argv[5],int(sys.argv[6]),False); print('ok')
    elif op=='resolve_crash': resolve(path,sys.argv[4],'approve',int(sys.argv[5]),True)

def main():
    if len(sys.argv)>1 and sys.argv[1]=='child': child(); return
    fd,path=tempfile.mkstemp(prefix='p3050_hardened_',suffix='.sqlite'); os.close(fd); os.remove(path)
    results=[]
    p=subprocess.run([sys.executable,__file__,'child','start',path,'5'],capture_output=True,text=True,check=True); rid=p.stdout.strip(); before=row(path,rid); q=subprocess.run([sys.executable,__file__,'child','resolve',path,rid,'approve','5']); after=row(path,rid); results.append({'case':'pause_process_exit_then_resume','pass':q.returncode==0 and before['state_present'] and after['status']=='approved_resumed' and after['effect_rows']==1})
    rid=start(path,4); before=row(path,rid); resolve(path,rid,'approve',5); after=row(path,rid); results.append({'case':'resume_after_runtime_version_change','pass':before['runtime_version']==4 and after['runtime_version']==5 and after['status']=='approved_resumed'})
    rid=start(path,5); resolve(path,rid,'approve',5); err=None
    try: resolve(path,rid,'approve',5)
    except Exception as e: err=str(e)
    after=row(path,rid); results.append({'case':'duplicate_approval_idempotency','pass':err=='RUN_NOT_PENDING' and after['tool_execution_count']==1 and after['effect_rows']==1})
    rid=start(path,5); crash=subprocess.run([sys.executable,__file__,'child','resolve_crash',path,rid,'5']); after_crash=row(path,rid); resolve(path,rid,'approve',5); after_retry=row(path,rid); results.append({'case':'crash_after_effect_commit_before_ack','pass':crash.returncode==73 and after_crash['status']=='pending_approval' and after_crash['effect_rows']==1 and after_retry['status']=='approved_resumed' and after_retry['effect_rows']==1 and after_retry['effect_replay_count']==1,'after_crash':after_crash,'after_retry':after_retry})
    rid=start(path,5,lease_seconds=-1); swept=sweep(path,time.time()); expired=row(path,rid); recover(path,rid,3600); recovered=row(path,rid); resolve(path,rid,'reject',5); final=row(path,rid); results.append({'case':'orphan_pending_timeout_recovery','pass':swept>=1 and expired['approval_recovery_state']=='expired_recoverable' and expired['state_present'] and recovered['approval_recovery_state']=='active' and recovered['approval_recovery_count']==1 and final['status']=='rejected_resumed' and final['effect_rows']==0,'expired':expired,'recovered':recovered,'final':final})
    out={'suite':'P3-050 SIS-native hardened crash/recovery tests','passed':sum(1 for r in results if r['pass']),'total':len(results),'results':results,'provider_writes':False,'gmail_writes':False,'prod_changes':False}
    print(json.dumps(out,indent=2)); os.remove(path)

if __name__=='__main__': main()
