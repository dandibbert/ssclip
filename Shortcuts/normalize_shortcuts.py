#!/usr/bin/env python3
"""Normalize Cherri's unreferenced control-flow output UUIDs; never alter references."""
import pathlib, plistlib, uuid
ROOT=pathlib.Path(__file__).parent

def walk(x):
 yield x
 if isinstance(x,dict):
  for v in x.values():yield from walk(v)
 elif isinstance(x,list):
  for v in x:yield from walk(v)

for filename in ['SSClip发送_unsigned.shortcut','SSClip设置_unsigned.shortcut']:
 path=ROOT/filename;p=plistlib.loads(path.read_bytes())
 references={v['OutputUUID'] for v in walk(p) if isinstance(v,dict) and 'OutputUUID' in v}
 seen=set()
 for i,a in enumerate(p['WFWorkflowActions']):
  q=a.get('WFWorkflowActionParameters',{});old=q.get('UUID')
  if old in seen:
   assert old not in references, 'Ambiguous referenced duplicate UUID; refusing to guess'
   assert a['WFWorkflowActionIdentifier'] in ['is.workflow.actions.conditional','is.workflow.actions.choosefrommenu','is.workflow.actions.repeat.each']
   q['UUID']=str(uuid.uuid5(uuid.NAMESPACE_URL,'ssclip-shortcut-v1/'+filename+'/'+str(i)))
  if old:seen.add(old)
  if a['WFWorkflowActionIdentifier']=='is.workflow.actions.base64encode':
   q.pop('input',None);q['WFEncodeMode']='Encode'
 path.write_bytes(plistlib.dumps(p,fmt=plistlib.FMT_XML,sort_keys=True))
