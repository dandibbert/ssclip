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
@dataclasses.dataclass
class NamedContent:
 name:str
 contents:str
class Machine:
 def __init__(self,files,save_fault=None,text_extension_policy='replace',shortcut_input=None):
  self.files=files;self.save_fault=save_fault;self.text_extension_policy=text_extension_policy;self.shortcut_input=shortcut_input;self.env={};self.outputs={};self.last=None
  self.imports=0;self.choosers=0;self.success=0;self.alerts=[];self.clipboard_reads=0;self.sends=0;self.network_requests=0;self.read_paths=[]
  self.groups={}
  for i,a in enumerate(A):
   q=a.get('WFWorkflowActionParameters',{})
   if 'GroupingIdentifier'in q:self.groups.setdefault(q['GroupingIdentifier'],{})[q['WFControlFlowMode']]=i
 def text(self,x):
  if isinstance(x,(File,NamedContent)):return x.contents
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
  elif t=='ExtensionInput':v=self.shortcut_input
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
   elif k=='setitemname':
    assert q['WFDontIncludeFileExtension'] is False,'Must name full file, including extension'
    out=NamedContent(self.val(q['WFName']),self.text(self.val(q['WFInput'])))
   elif k=='documentpicker.save':
    item=self.val(q['WFInput']);path=self.path(q['WFFileDestinationPath']);body=self.text(item)
    if isinstance(item,NamedContent):
     assert item.name==path[1].rsplit('/',1)[-1],'Explicit name must agree with save subpath'
    elif self.text_extension_policy=='replace':path=(path[0],path[1].rsplit('.',1)[0]+'.txt')
    elif self.text_extension_policy=='append' and not path[1].endswith('.txt'):path=(path[0],path[1]+'.txt')
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
    self.network_requests+=1
    url=self.val(q['WFURL'])
    if url.endswith('/register'):out={'device':{'id':'ios-shortcut-sender'}}
    elif url.endswith('/devices'):out={'devices':[]}
    else:self.sends+=1;raise AssertionError('Cold-start fixture must never send')
   elif k=='alert':
    message=self.text(self.val(q['WFAlertActionMessage']));assert FIXTURE['api_key'] not in message
    self.alerts.append(q.get('WFAlertActionTitle',''))
    if message=='连接已保存':self.success+=1
   elif k=='choosefromlist':
    assert q['WFChooseFromListActionPrompt']=='选择接收 Mac','Unexpected recovery selector'
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
  self.assertEqual([m.success for m in runs],[1,0,0]);self.assertEqual(runs[0].read_paths[-1],('Shortcuts','SSClip/connection-state.txt'))
  saved=json.loads(files[('Shortcuts','SSClip/connection-state.txt')]);self.assertEqual(saved,FIXTURE)
 def test_existing_legacy_state_without_format_needs_no_import(self):
  old=dict(FIXTURE);old.pop('format');old.update(target_id='obsolete',target_name='Old Mac')
  m=Machine({('Shortcuts','SSClip/connection-state.txt'):json.dumps(old)});self.assertEqual(m.run(),'selector');self.assertEqual(m.imports,0)
 def test_wrong_path_or_provider_never_claims_success(self):
  for fault in ['wrong-path','wrong-provider']:
   with self.subTest(fault=fault):
    m=Machine({},fault);self.assertEqual(m.run(),'exit');self.assertEqual(m.success,0);self.assertIn('保存校验失败',m.alerts)
 def test_all_readback_fields_checked(self):
  for field,value in [('format','wrong'),('version',2),('server_url','https://other.invalid'),('api_key','b'*64)]:
   with self.subTest(field=field):
    m=Machine({},(field,value));self.assertEqual(m.run(),'exit');self.assertEqual(m.success,0);self.assertIn('保存校验失败',m.alerts)
 def test_only_generated_actions_and_no_secret_feedback(self):
  self.assertEqual(len([a for a in A if a['WFWorkflowActionIdentifier']=='is.workflow.actions.documentpicker.open']),4)
  self.assertEqual(len([a for a in A if a['WFWorkflowActionIdentifier']=='is.workflow.actions.count' and a['WFWorkflowActionParameters'].get('WFCountType')=='Items']),4)
 def test_each_exact_legacy_filename_across_three_cold_runs(self):
  for name in ['connection-state.txt','connection-state.json.txt','connection-state.json']:
   with self.subTest(name=name):
    old=dict(FIXTURE);old.pop('format');path=('Shortcuts','SSClip/'+name);files={path:json.dumps(old)};before=dict(files)
    runs=[Machine(files)for _ in range(3)]
    self.assertEqual([m.run()for m in runs],['selector']*3)
    self.assertEqual(sum(m.imports for m in runs),0);self.assertEqual(files,before,'No automatic legacy migration or deletion')
 def test_canonical_wins_over_stale_legacy(self):
  stale=dict(FIXTURE,api_key='b'*64)
  files={('Shortcuts','SSClip/connection-state.txt'):json.dumps(FIXTURE),('Shortcuts','SSClip/connection-state.json'):json.dumps(stale)}
  m=Machine(files);self.assertEqual(m.run(),'selector');self.assertEqual(m.env['apiKey'],FIXTURE['api_key']);self.assertEqual(len(m.read_paths),1)
 def test_old_matching_file_cannot_mask_failed_canonical_save(self):
  for legacy in ['connection-state.json.txt','connection-state.json']:
   files={('Shortcuts','SSClip/'+legacy):json.dumps(FIXTURE)};before=dict(files)
   m=Machine(files,'wrong-path',shortcut_input='SSCLIP_REIMPORT_V2')
   self.assertEqual(m.run(),'exit');self.assertEqual(m.success,0);self.assertIn('保存校验失败',m.alerts)
   self.assertEqual(m.read_paths[-1],('Shortcuts','SSClip/connection-state.txt'))
   self.assertEqual(files[('Shortcuts','SSClip/'+legacy)],before[('Shortcuts','SSClip/'+legacy)])
 def test_explicit_name_survives_both_text_extension_models(self):
  for policy in ['replace','append']:
   files={};runs=[Machine(files,text_extension_policy=policy)for _ in range(3)]
   self.assertEqual([m.run()for m in runs],['exit','selector','selector'])
   self.assertEqual(set(files),{('Shortcuts','SSClip/connection-state.txt')})
   self.assertEqual([m.imports for m in runs],[1,0,0])
 def test_invalid_legacy_is_rejected_before_network_or_use(self):
  for field,value in [('version',99),('server_url','http://not-https.invalid'),('api_key','bad')]:
   files={('Shortcuts','SSClip/connection-state.json'):json.dumps(dict(FIXTURE,**{field:value}))}
   m=Machine(files)
   # A recovery selector is expected, never the normal receiver selector.
   with self.assertRaisesRegex(AssertionError,'Unexpected recovery selector'):m.run()
   self.assertEqual(m.imports,0);self.assertEqual(m.choosers,0);self.assertEqual(m.success,0);self.assertEqual(m.network_requests,0)
 def test_shipped_e4_unnamed_json_fixture_reproduces_filename_miss(self):
  fixture=json.loads((ROOT/'fixtures'/'e4a4182c-unnamed-json-state.json').read_text())
  self.assertEqual(fixture['source_commit'],'e4a4182cf3d1938cedcacc93860ecd43799dceec')
  self.assertEqual(fixture['source_resource_sha256'],'921166843c56bd0f5771cd3099d817b6cb59ab5a002835fbb712acd0749789c0')
  self.assertEqual(fixture['set_name_action_count'],0)
  old_read=fixture['loader']['WFWorkflowActionParameters']['WFGetFilePath'].lstrip('/')
  old_save=fixture['save']['WFWorkflowActionParameters']
  self.assertEqual(old_read,'SSClip/connection-state.json')
  self.assertEqual(old_save['WFFileDestinationPath'],'SSClip/connection-state.json')
  conversion=fixture['text_conversion'];binding=fixture['text_binding']['WFWorkflowActionParameters']
  self.assertEqual(conversion['WFWorkflowActionIdentifier'],'is.workflow.actions.detect.text')
  self.assertEqual(binding['WFInput']['Value']['OutputUUID'],conversion['WFWorkflowActionParameters']['UUID'])
  self.assertEqual(old_save['WFInput']['Value']['VariableName'],binding['WFVariableName'])
  for policy,actual_name in [('replace','SSClip/connection-state.txt'),('append','SSClip/connection-state.json.txt')]:
   files={};imports=0
   for _ in range(3):
    self.assertNotIn(('Shortcuts',old_read),files)
    imports+=1
    # Resolve the extracted real native File<-Text producer chain with fake state.
    m=Machine(files,text_extension_policy=policy);m.env['newState']=dict(FIXTURE)
    raw=m.text(m.val(conversion['WFWorkflowActionParameters']['WFInput']))
    m.outputs[conversion['WFWorkflowActionParameters']['UUID']]=raw
    m.env[binding['WFVariableName']]=m.val(binding['WFInput'])
    value=m.val(old_save['WFInput']);self.assertIsInstance(value,str)
    path=old_save['WFFileDestinationPath']
    actual=path.rsplit('.',1)[0]+'.txt' if policy=='replace'else path+'.txt'
    files[('Shortcuts',actual)]=value
   self.assertEqual(imports,3);self.assertEqual(set(files),{('Shortcuts',actual_name)})
if __name__=='__main__':unittest.main(verbosity=2)
