#!/usr/bin/env python3
"""Execute a bounded native-action subset from the generated plist.
The virtual provider follows observed modern Shortcuts-root file-path semantics;
it DOES NOT emulate iOS migration, permissions, iCloud, or prove device behavior.
Only fabricated config is used. Fresh runs share the virtual file map, nothing else.
"""
import dataclasses,json,pathlib,plistlib,re,sys,unittest
from urllib.parse import urlsplit
ROOT=pathlib.Path(__file__).parent
RESOURCE=next(path for path in [ROOT/'SSClip发送_unsigned.shortcut',ROOT/'SSClip-Send.unsigned.shortcut',ROOT.parent/'Resources'/'SSClip-Send.unsigned.shortcut'] if path.exists())
P=plistlib.loads(RESOURCE.read_bytes())
A=P['WFWorkflowActions']
FIXTURE={'format':'ssclip-connection','version':1,'server_url':'https://fixture.invalid','api_key':'a'*64}
@dataclasses.dataclass
class File:
 path:str
 contents:str
class Machine:
 def __init__(self,files,save_fault=None):
  self.files=files;self.save_fault=save_fault;self.env={};self.outputs={};self.last=None
  self.imports=0;self.choosers=0;self.success=0;self.alerts=[];self.clipboard_reads=0;self.sends=0;self.read_paths=[]
  self.groups={}
  for i,a in enumerate(A):
   q=a.get('WFWorkflowActionParameters',{})
   if 'GroupingIdentifier'in q:self.groups.setdefault(q['GroupingIdentifier'],{})[q['WFControlFlowMode']]=i
 def text(self,x):
  if isinstance(x,File):return x.contents
  if isinstance(x,dict):return json.dumps(x,ensure_ascii=False)
  if x is None:return ''
  return str(x)
 def val(self,x):
  if not isinstance(x,dict):return x
  if x.get('Type')=='Variable' and 'Variable'in x:return self.val(x['Variable'])
  if 'Value'in x:return self.val(x['Value'])
  t=x.get('Type')
  if t=='Variable':v=self.env.get(x['VariableName'])
  elif t=='ActionOutput':v=self.outputs[x['OutputUUID']]
  elif t=='ExtensionInput':v=None
  elif 'string'in x:
   v=x['string']
   for span,tok in sorted(x.get('attachmentsByRange',{}).items(),key=lambda z:int(z[0].split(',')[0][1:]),reverse=True):
    start,length=map(int,span.strip('{}').split(','));v=v[:start]+self.text(self.val(tok))+v[start+length:]
  elif 'WFDictionaryFieldValueItems'in x:
   out={}
   for item in x['WFDictionaryFieldValueItems']:
    value=self.val(item['WFValue'])
    if item.get('WFItemType')==3:value=float(value);value=int(value)if value.is_integer()else value
    out[self.val(item['WFKey'])]=value
   return out
  elif not x:return {}
  else:raise AssertionError('Unsupported token shape')
  for ag in x.get('Aggrandizements',[]):
   if ag.get('CoercionItemClass')=='WFNumberContentItem':v=float(v or 0)
   elif ag.get('CoercionItemClass')=='WFStringContentItem':v=self.text(v)
   else:raise AssertionError('Unsupported coercion')
  return v
 def path(self,p):return ('Shortcuts',p.lstrip('/'))
 def run(self):
  i=0
  while i<len(A):
   a=A[i];k=a['WFWorkflowActionIdentifier'].removeprefix('is.workflow.actions.');q=a.get('WFWorkflowActionParameters',{});out=None
   if k=='conditional':
    group=self.groups[q['GroupingIdentifier']];mode=q['WFControlFlowMode']
    if mode==0:
     left=self.val(q['WFInput']);code=q['WFCondition'];right=self.val(q.get('WFConditionalActionString',q.get('WFNumberValue')))
     if code==100:result=left is not None and left!='' and left!=[]
     elif code==101:result=left is None or left=='' or left==[]
     elif code==4:result=left==right
     elif code==5:result=left!=right
     elif code==0:result=float(left or 0)<float(right)
     elif code==2:result=float(left or 0)>float(right)
     elif code==99:result=self.text(right) in self.text(left)
     else:raise AssertionError('Unsupported condition')
     if not result:i=group.get(1,group[2])+1;continue
    elif mode==1:i=group[2]+1;continue
   elif k=='repeat.each':
    if q['WFControlFlowMode']==0:
     assert self.val(q['WFInput'])==[], 'This bounded cold-start fixture uses an empty device list'
     i=self.groups[q['GroupingIdentifier']][2]+1;continue
   elif k=='setvariable':self.env[q['WFVariableName']]=self.val(q['WFInput'])if 'WFInput'in q else self.last
   elif k=='appendvariable':
    old=self.env.get(q['WFVariableName'])or[];self.env[q['WFVariableName']]=old+[self.val(q['WFInput'])]
   elif k=='gettext':out=self.val(q['WFTextActionText'])
   elif k=='number':out=q['WFNumberActionNumber']
   elif k=='count':
    value=self.val(q['Input']);out=len(value)if q['WFCountType']=='Characters'else (len(value)if isinstance(value,list)else 0 if value is None else 1)
   elif k=='documentpicker.open':
    path=self.path(q['WFGetFilePath']);self.read_paths.append(path)
    if path in self.files:out=File(path[1],self.files[path])
   elif k=='documentpicker.save':
    path=self.path(q['WFFileDestinationPath']);body=self.text(self.val(q['WFInput']))
    if self.save_fault=='wrong-provider':path=('OtherProvider',path[1])
    elif self.save_fault=='wrong-path':path=(path[0],'Elsewhere/state.json')
    elif isinstance(self.save_fault,tuple):
     field,value=self.save_fault;obj=json.loads(body);obj[field]=value;body=json.dumps(obj)
    self.files[path]=body;out=File(path[1],body)
   elif k=='detect.text':out=self.text(self.val(q['WFInput']))
   elif k=='detect.dictionary':
    value=self.val(q['WFInput']);out=value if isinstance(value,dict)else json.loads(self.text(value))
   elif k=='dictionary':out=self.val(q['WFItems'])
   elif k=='getvalueforkey':out=self.val(q['WFInput']).get(self.val(q['WFDictionaryKey']),'')
   elif k=='text.match':out=re.findall(q['WFMatchTextPattern'].replace(r'\z',r'\Z'),self.text(self.val(q['text'])))
   elif k=='text.replace':out=re.sub(self.val(q['WFReplaceTextFind']),self.val(q['WFReplaceTextReplace']),self.text(self.val(q['WFInput'])))
   elif k=='geturlcomponent':
    u=urlsplit(self.val(q['WFURL']));out=u.hostname if q['WFURLComponent']=='Host'else u.port
   elif k=='file.select':self.imports+=1;out=File('fixture.json',json.dumps(FIXTURE))
   elif k=='downloadurl':
    url=self.val(q['WFURL'])
    if url.endswith('/register'):out={'device':{'id':'ios-shortcut-sender'}}
    elif url.endswith('/devices'):out={'devices':[]}
    else:self.sends+=1;raise AssertionError('Cold-start fixture must never send')
   elif k=='alert':
    message=self.text(self.val(q['WFAlertActionMessage']));assert FIXTURE['api_key'] not in message
    self.alerts.append(q.get('WFAlertActionTitle',''))
    if '已保存并读回校验'in message:self.success+=1
   elif k=='choosefromlist':
    assert q['WFChooseFromListActionPrompt']=='选择本次接收设备；取消不会发送','Unexpected recovery selector'
    self.choosers+=1;return 'selector'
   elif k=='getclipboard':self.clipboard_reads+=1;raise AssertionError('Should stop at chooser, not read clipboard')
   elif k=='exit':return 'exit'
   elif k in ['comment','nothing','file.createfolder']:pass
   else:raise AssertionError('Unsupported native action '+k)
   if 'UUID'in q:self.outputs[q['UUID']]=out
   self.last=out;i+=1
  return 'end'
class PersistenceTests(unittest.TestCase):
 def test_three_cold_runs_share_files_only(self):
  files={};runs=[Machine(files)for _ in range(3)]
  self.assertEqual([m.run()for m in runs],['exit','selector','selector'])
  self.assertEqual([m.imports for m in runs],[1,0,0]);self.assertEqual([m.choosers for m in runs],[0,1,1])
  self.assertEqual([m.success for m in runs],[1,0,0]);self.assertEqual(len(set(runs[0].read_paths)),1)
  saved=json.loads(files[('Shortcuts','SSClip/connection-state.json')]);self.assertEqual(saved,FIXTURE)
 def test_existing_legacy_state_without_format_needs_no_import(self):
  old=dict(FIXTURE);old.pop('format');old.update(target_id='obsolete',target_name='Old Mac')
  m=Machine({('Shortcuts','SSClip/connection-state.json'):json.dumps(old)});self.assertEqual(m.run(),'selector');self.assertEqual(m.imports,0)
 def test_wrong_path_or_provider_never_claims_success(self):
  for fault in ['wrong-path','wrong-provider']:
   with self.subTest(fault=fault):
    m=Machine({},fault);self.assertEqual(m.run(),'exit');self.assertEqual(m.success,0);self.assertIn('保存校验失败',m.alerts)
 def test_all_readback_fields_checked(self):
  for field,value in [('format','wrong'),('version',2),('server_url','https://other.invalid'),('api_key','b'*64)]:
   with self.subTest(field=field):
    m=Machine({},(field,value));self.assertEqual(m.run(),'exit');self.assertEqual(m.success,0);self.assertIn('保存校验失败',m.alerts)
 def test_only_generated_actions_and_no_secret_feedback(self):
  self.assertEqual(len([a for a in A if a['WFWorkflowActionIdentifier']=='is.workflow.actions.documentpicker.open']),2)
  self.assertEqual(len([a for a in A if a['WFWorkflowActionIdentifier']=='is.workflow.actions.count' and a['WFWorkflowActionParameters'].get('WFCountType')=='Items']),2)
if __name__=='__main__':unittest.main(verbosity=2)
