"""Independent, simplified policy-rule simulator, NOT the polispec engine.
Based on SteveBenner/polispec examples/policy.shop.yml as inspected 2026-10-14.
Models first matching rule for illustrative actions, not hooks, authorization,
installation, sealed planes or native harness enforcement.
"""
import csv
from pathlib import Path

rules = [
 ('R-PROD-GIT', 'prod', {'git.commit','git.push','git.tag','git.merge','git.rewrite','git.branch','release.publish'}, 'deny'),
 ('R-PROD-SVC', 'prod', {'service.control','service.config','deploy','promote'}, 'deny'),
 ('R-PROD-FS', 'prod', {'fs.write'}, 'deny'),
 ('R-PROD-DATA', 'prod', {'data.write'}, 'warn'),
 ('R-PROD-SECRET', 'prod', {'secrets.read'}, 'deny'),
 ('R-XENV-COPY', None, {'data.copy'}, 'deny'),
 ('R-TEST-DIRECT', 'test', {'git.push','git.merge','git.commit','git.tag'}, 'deny'),
 ('R-TEST-REWRITE', 'test', {'git.rewrite'}, 'deny'),
 ('R-TEST-PROMOTE', 'test', {'promote'}, 'allow'),
 ('R-TEST-OPS', 'test', {'deploy','service.control','data.write','fs.write'}, 'allow'),
 ('R-POLICY', None, {'policy.edit'}, 'warn'),
 ('R-DEV-REWRITE', 'dev', {'git.rewrite'}, 'warn'),
 ('R-DEV', 'dev', None, 'allow'),
]
scenarios = [
 ('S01','Agent edits production code','prod','fs.write',False,True,'deny'),
 ('S02','Agent reads production secret','prod','secrets.read',False,True,'deny'),
 ('S03','Agent pushes production branch','prod','git.push',False,True,'deny'),
 ('S04','Agent writes live user data','prod','data.write',False,True,'warn'),
 ('S05','Agent commits directly in test','test','git.commit',False,True,'deny'),
 ('S06','Agent deploys to test','test','deploy',False,True,'allow'),
 ('S07','Agent promotes to test with gates satisfied','test','promote',False,True,'allow'),
 ('S08','Agent promotes to test with failed gates','test','promote',False,False,'deny (gate)'),
 ('S09','Agent copies PII to development','dev','data.copy',True,True,'deny'),
 ('S10','Agent edits policy in test','test','policy.edit',False,True,'warn'),
 ('S11','Agent rewrites main history','dev','git.rewrite',False,True,'warn'),
 ('S12','Agent changes dev source file','dev','fs.write',False,True,'allow'),
 ('S13','Agent asks to promote production','prod','promote',False,True,'deny'),
]
def resolve(env, action, crosses, gates):
    for name, rule_env, classes, verdict in rules:
        if rule_env is not None and env != rule_env: continue
        if classes is not None and action not in classes: continue
        if name == 'R-XENV-COPY' and not crosses: continue
        if name == 'R-TEST-PROMOTE' and not gates: return 'deny (gate)', name
        return verdict, name
    return 'unmatched', 'none'
rows=[]
for case,label,env,action,crosses,gates,expected in scenarios:
    result,rule=resolve(env,action,crosses,gates)
    assert result == expected, (case,result,expected)
    rows.append(dict(id=case,scenario=label,environment=env,action=action,simulated_verdict=result,matched_rule=rule,status='SIMULATED ONLY'))
out=Path(__file__).with_name('polispec_simulation_results.csv')
with out.open('w',newline='') as f:
    w=csv.DictWriter(f,fieldnames=rows[0]);w.writeheader();w.writerows(rows)
for r in rows:print(r['id'],r['simulated_verdict'],r['matched_rule'],r['scenario'])
print('SIMULATED CASES:',len(rows))
