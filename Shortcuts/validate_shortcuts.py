#!/usr/bin/env python3
"""Structural/privacy checks, not a substitute for an actual iOS runtime test."""
import base64, collections, hashlib, json, pathlib, plistlib, re
ROOT=pathlib.Path(__file__).parent
ORIGIN='https://ssclip-relay-lab.sgah81.chatgpt.site'
checks=0
def check(condition, message):
 global checks
 assert condition,message
 checks+=1

def walk(x):
 yield x
 if isinstance(x,dict):
  for v in x.values():yield from walk(v)
 elif isinstance(x,list):
  for v in x:yield from walk(v)

def resource():
 for path in [ROOT/'SSClip发送_unsigned.shortcut', ROOT/'SSClip-Send.unsigned.shortcut', ROOT.parent/'Resources'/'SSClip-Send.unsigned.shortcut']:
  if path.exists(): return path
 raise FileNotFoundError('SSClip-Send.unsigned.shortcut')
main=plistlib.loads(resource().read_bytes())
for name,p in [('main',main)]:
 acts=p['WFWorkflowActions']; ids=set()
 for a in acts:
  check(a['WFWorkflowActionIdentifier'].startswith('is.workflow.actions.'),f'{name}: nonnative action')
  q=a.get('WFWorkflowActionParameters',{})
  if 'UUID' in q:
   check(q['UUID'] not in ids,f'{name}: duplicate output UUID');ids.add(q['UUID'])
 for node in walk(p):
  if isinstance(node,dict) and node.get('Type')=='ActionOutput':
   check(node.get('OutputUUID') in ids,f'{name}: dangling output reference')
 check(not any('runjavascriptonwebpage' in a['WFWorkflowActionIdentifier'] for a in acts),'No webpage JS')
 check(not any('setclipboard' in a['WFWorkflowActionIdentifier'] for a in acts),'Never write clipboard')
 check(not p.get('WFWorkflowImportQuestions'),'No user manual key-entry question')

acts=main['WFWorkflowActions']
http=[a['WFWorkflowActionParameters'] for a in acts if a['WFWorkflowActionIdentifier']=='is.workflow.actions.downloadurl']
check(len(http)==3,'Exactly registration, discovery, send; no automatic retry actions')
for q,route in zip(http,['register','devices','send']):
 u=q['WFURL']['Value']
 check(u['string']=='\ufffc/api/service/'+route,'Only confirmed origin plus fixed route')
 check(list(u['attachmentsByRange'].values())==[{'Type':'Variable','VariableName':'server'}],'URL token is origin, never key')
for q in http:
 check('?' not in q['WFURL']['Value']['string'],'No secret query')
 h=q['WFHTTPHeaders']['Value']['WFDictionaryFieldValueItems']
 check(len(h)==1 and h[0]['WFKey']['Value']['string']=='Authorization','Only Authorization header')
 v=h[0]['WFValue']['Value']
 check(v['string']=='Bearer \ufffc','Bearer token is a variable, never embedded')
 check(next(iter(v['attachmentsByRange'].values()))['VariableName']=='apiKey','Runtime key variable')
check(http[0]['WFHTTPBodyType']=='JSON' and http[2]['WFHTTPBodyType']=='JSON','Native structured JSON escaping')
body=http[2]['WFJSONValues']['Value']['WFDictionaryFieldValueItems']
fields={f['WFKey']['Value']['string']:f['WFValue'] for f in body}
check(set(fields)=={'id','source','target','text','ttl_seconds'},'Complete protocol send fields')
text=fields['text']['Value']
check(text['string']=='\ufffc' and next(iter(text['attachmentsByRange'].values()))['VariableName']=='text','Text JSON value uses native magic variable')
reads=[a['WFWorkflowActionParameters'] for a in acts if a['WFWorkflowActionIdentifier']=='is.workflow.actions.documentpicker.open']
check(len(reads)==1,'Shared connection state only; no physical phone identity')
for q in reads:
 check(q['WFFileStorageService']=='iCloud Drive' and q['WFShowFilePicker'] is False and q['WFFileErrorIfNotFound'] is False,'Private persistent file lookup is noninteractive and missing-safe')
writes=[a['WFWorkflowActionParameters'] for a in acts if a['WFWorkflowActionIdentifier']=='is.workflow.actions.documentpicker.save']
check({q['WFFileDestinationPath'] for q in writes}=={'SSClip/connection-state.json'},'No clipboard body persistence')
for q in writes:check(q['WFAskWhereToSave'] is False and q['WFFileStorageService']=='iCloud Drive','No public config sharing')
alerts=[a['WFWorkflowActionParameters'] for a in acts if a['WFWorkflowActionIdentifier']=='is.workflow.actions.alert']
for q in alerts:
 for node in walk(q):
  if isinstance(node,dict) and node.get('Type')=='Variable':
   check(node['VariableName'] not in ['apiKey','text','clipboard','configText','state','newStateText'],'No secret or clipboard in alerts')
check(sum(a['WFWorkflowActionIdentifier']=='is.workflow.actions.getclipboard' for a in acts)==1,'Read clipboard once, only send path')
check(any(a['WFWorkflowActionIdentifier']=='is.workflow.actions.getitemtype' for a in acts),'Explicit type gate before text conversion')
source=(ROOT/'SSClip-send.cherri').read_text()
check(source.index('if @setupInput.text')<source.index('@state = getDictionary'),'Corrupt state recoverable via reimport setup before decode')
check(source.index('@newState =')<source.index('@clipboard = getClipboard()'),'Setup completes before clipboard access')
check('if !@targetID {' in source,'Missing target fails closed, no fallback')
check('if @returnedID.text == @messageID' in source and 'if @sendState.text == "pending"' in source,'Success requires matching message ID and state')
check('@senderID = "ios-shortcut-sender"' in source and '@senderName = "iOS 快捷指令"' in source,'Explicit shared logical sender identity')
check('phone-id.txt' not in source and 'getDeviceDetail' not in source,'No physical-device identity claims or persistence')
# Port and anchored origin validation is mirrored from the native regex + numeric guard.
from urllib.parse import urlsplit
origin_pattern=re.search(r"@originMatch = matchText\('([^']+)'",source).group(1).replace(r"\z",r"\Z")
def valid_origin(value):
 if not re.match(origin_pattern,value):return False
 u=urlsplit(value)
 return len(u.hostname or '')<=253 and (u.port is None or 1<=u.port<=65535)
for value in ['https://example.com','https://example.com/','https://a.local:8443','https://127.0.0.1:443','https://xn--bcher-kva.example']:
 check(valid_origin(value),'Expected supported HTTPS root')
for value in ['http://example.com','https://user:pass@example.com','https://user@example.com','https://example.com/path','https://example.com?key=a','https://example.com#x','https://example.com\n','https://example.com:0','https://example.com:70000','https://[::1]','https://-bad.example','https://'+('x'*64)+'.example']:
 try: valid=valid_origin(value)
 except ValueError:valid=False
 check(not valid,'Expected malformed or unsupported origin rejection')
check('if @needsConfig == 1 {\n confirm("将连接：{@server}' in source,'Actual target origin explicitly confirmed before first use')
# Regression for the first real-iPhone failure: dictionary brackets compiled as
# object-property aggrandizements; derived UUIDs also aliased independent If groups.
for name,p in [('main',main)]:
 stack=[]; opened=set()
 for a in p['WFWorkflowActions']:
  q=a.get('WFWorkflowActionParameters',{})
  if 'GroupingIdentifier' not in q: continue
  group=q['GroupingIdentifier'];mode=q['WFControlFlowMode'];kind=a['WFWorkflowActionIdentifier']
  if mode==0:
   check(group not in opened,f'{name}: reused independent control-flow group')
   opened.add(group);stack.append((group,kind))
  else:
   check(bool(stack) and stack[-1]==(group,kind),f'{name}: improperly nested control-flow boundary')
   if mode==2:stack.pop()
   else:check(mode==1,f'{name}: unknown control-flow mode')
 check(not stack,f'{name}: unclosed control-flow group')
 for node in walk(p):
  if isinstance(node,dict):
   check(node.get('Type')!='WFPropertyVariableAggrandizement','Never confuse object properties with dictionary keys')
   if node.get('Type')=='Variable':check('OutputUUID' not in node,'Named variable must not contain stale output UUID')

# A bounded interpreter of the ACTUAL emitted native dictionary/text/set-variable
# actions. This is a serialization regression test, NOT an iOS runtime emulator.
def read_token(token,env,outputs):
 value=token.get('Value',token)
 if value.get('Type')=='Variable':return env[value['VariableName']]
 if value.get('Type')=='ActionOutput':return outputs[value['OutputUUID']]
 raise AssertionError('Unexpected token shape')
def run_dictionary_pipeline(start_variable,input_value,end_variable):
 env={start_variable:input_value};outputs={};active=False
 for a in acts:
  kind=a['WFWorkflowActionIdentifier'];q=a.get('WFWorkflowActionParameters',{})
  if kind=='is.workflow.actions.getvalueforkey':
   token=q['WFInput']['Value']
   if token.get('VariableName') not in env:continue
   check(q['WFGetDictionaryValueType']=='Value','Explicit dictionary value operation')
   key=q['WFDictionaryKey']
   if not isinstance(key,str):continue
   obj=read_token(q['WFInput'],env,outputs)
   outputs[q['UUID']]=obj.get(key,'');active=True
  elif active and kind=='is.workflow.actions.detect.text':
   try:value=read_token(q['WFInput'],env,outputs)
   except KeyError:continue
   outputs[q['UUID']]=str(value)
  elif active and kind=='is.workflow.actions.setvariable':
   try:value=read_token(q['WFInput'],env,outputs)
   except (KeyError,AssertionError):continue
   env[q['WFVariableName']]=value
   if q['WFVariableName']==end_variable:return env
 raise AssertionError('Expected native dictionary pipeline not found')
fixture=json.loads('{"format":"ssclip-connection","version":1,"server_url":"https://example.com","api_key":"'+'a'*64+'"}')
values=run_dictionary_pipeline('config',fixture,'apiKey')
for key in ['format','version']:
 check(values[key]==fixture[key],'Generated config field lookup must preserve value')
check(values['server']==fixture['server_url'] and values['apiKey']==fixture['api_key'],'Generated config origin/key lookup')
for bad in [{},dict(fixture,format='wrong')]:
 check(run_dictionary_pipeline('config',bad,'apiKey')['format']!='ssclip-connection','Bad config must fail format gate')
missing=run_dictionary_pipeline('config',{},'apiKey')
check(missing['format']=='' and missing['version']=='','Missing metadata remains distinguishable from mismatch')
check(run_dictionary_pipeline('config',dict(fixture,version=2),'apiKey')['version']==2,'Unsupported version preserves value for rejection')
check('if !@format {' in source and 'if !@version {' in source,'Missing metadata has specific safe feedback')
check(run_dictionary_pipeline('registeredDevice',{'id':'ios-fixture-id'},'registeredID')['registeredID']=='ios-fixture-id','Registration dictionary id lookup')
check(run_dictionary_pipeline('sent',{'id':'msg-fixture-id','state':'pending'},'sendState')['sendState']=='pending','Send dictionary state lookup')
# Validate actual regex bytes, not only source spellings.
patterns=[a['WFWorkflowActionParameters']['WFMatchTextPattern'] for a in acts if a['WFWorkflowActionIdentifier']=='is.workflow.actions.text.match']
check(origin_pattern.replace(r'\Z',r'\z') in patterns,'Emitted origin regex matches tested source')
check(r'"format"\s*:\s*"ssclip-connection"' in patterns,'Credential marker has correct native regex escaping')
check(not any(a['WFWorkflowActionIdentifier'] in ['is.workflow.actions.math','is.workflow.actions.base64encode'] for a in acts),'Server owns byte limit; no fragile native arithmetic')
check(any(a['WFWorkflowActionIdentifier']=='is.workflow.actions.appendvariable' and a['WFWorkflowActionParameters'].get('WFVariableName')=='choices' for a in acts),'Device selection accumulates instead of overwriting list')
for pattern in patterns:
 check('\\\\' not in pattern,'No doubled regex escape')
# Single-shortcut daily destination selection and old state compatibility.
old_state={'version':1,'server_url':'https://example.com','api_key':'a'*64,'target_id':'OLD-DO-NOT-USE','target_name':'Old Mac'}
loaded=run_dictionary_pipeline('state',old_state,'apiKey')
check(loaded['server']==old_state['server_url'] and loaded['apiKey']==old_state['api_key'],'Old state retains connection')
lookups=[a['WFWorkflowActionParameters'] for a in acts if a['WFWorkflowActionIdentifier']=='is.workflow.actions.getvalueforkey']
check(not any(q['WFDictionaryKey'] in ['target_id','target_name'] for q in lookups if isinstance(q['WFDictionaryKey'],str)),'Never load stale target')
check('"target_id"' not in source and '"target_name"' not in source,'No default target persisted')
selects=[i for i,a in enumerate(acts) if a['WFWorkflowActionIdentifier']=='is.workflow.actions.choosefromlist' and a['WFWorkflowActionParameters'].get('WFChooseFromListActionPrompt')=='选择本次接收设备；取消不会发送']
check(len(selects)==1,'Exactly one destination selector')
clip_index=next(i for i,a in enumerate(acts) if a['WFWorkflowActionIdentifier']=='is.workflow.actions.getclipboard')
check(selects[0]<clip_index,'Selection precedes clipboard access')
check('if !@choice { stop() }' in source,'Explicit cancellation early exit')
check(source.index('saveSSClipState(@newStateText)')<source.index('stop()',source.index('saveSSClipState(@newStateText)'))<source.index('@devicesRaw ='),'Import stops before selection/clipboard/send')
check('@targetID = ""' in source,'Target initialized empty every run')
check('@label = "{@name} · {@id}"' in source and '@changeConnection = "更换连接配置…"' in source,'Config entry cannot equal full-ID device label')
runs=[a['WFWorkflowActionParameters'] for a in acts if a['WFWorkflowActionIdentifier']=='is.workflow.actions.runworkflow']
check(len(runs)==8 and all(q['WFWorkflowName']=='SSClip发送' for q in runs),'Recovery and list entry only self reimport, no helper dependency')
check('SSClip设置' not in source and 'SSCLIP_SETUP_V1' not in source,'No separate settings shortcut')
# Native selection is unconditional for configured daily runs, not a saved-target branch.
stack=[];contexts={}
for index,a in enumerate(acts):
 q=a.get('WFWorkflowActionParameters',{})
 if q.get('WFControlFlowMode')==0:stack.append(q['GroupingIdentifier'])
 contexts[index]=list(stack)
 if q.get('WFControlFlowMode')==2:stack.pop()
check(not contexts[selects[0]],'Daily selector is top-level, never skipped via cached target')
state_save=next(i for i,a in enumerate(acts) if a['WFWorkflowActionIdentifier']=='is.workflow.actions.documentpicker.save' and a['WFWorkflowActionParameters'].get('WFFileDestinationPath')=='SSClip/connection-state.json')
check(bool(contexts[state_save]),'State save only within import branch')
check(any(a['WFWorkflowActionIdentifier']=='is.workflow.actions.exit' for a in acts[state_save:selects[0]]),'Import branch exits before daily chooser/send')
choice_guard=acts[selects[0]+2]
check(choice_guard['WFWorkflowActionIdentifier']=='is.workflow.actions.conditional','Native empty-choice guard follows selected variable assignment')
check(acts[selects[0]+3]['WFWorkflowActionIdentifier']=='is.workflow.actions.exit','Native empty-choice branch immediately exits')
check(next(i for i,a in enumerate(acts) if a['WFWorkflowActionIdentifier']=='is.workflow.actions.downloadurl' and a['WFWorkflowActionParameters']['WFURL']['Value']['string'].endswith('/devices'))<selects[0],'Native devices fetch precedes every chooser')
# Bounded execution of emitted label -> native dictionary setter -> selected key getter.
def render_native(value,env):
 if isinstance(value,str):return value
 value=value.get('Value',value)
 if value.get('Type')=='Variable':return env[value['VariableName']]
 if 'string' in value:
  text=value['string']
  for span,token in sorted(value.get('attachmentsByRange',{}).items(),key=lambda pair:int(pair[0].split(',')[0][1:]),reverse=True):
   start,length=map(int,span.strip('{}').split(','))
   text=text[:start]+str(env[token['VariableName']])+text[start+length:]
  return text
 raise AssertionError('Unsupported fixture token')
setter=next(a['WFWorkflowActionParameters'] for a in acts if a['WFWorkflowActionIdentifier']=='is.workflow.actions.setvalueforkey')
selected_getter=next(q for q in lookups if isinstance(q['WFDictionaryKey'],dict))
check(selected_getter['WFInput']['Value']['VariableName']=='choiceMap','Selected ID comes from fresh choice map')
check(list(selected_getter['WFDictionaryKey']['Value']['attachmentsByRange'].values())==[{'Type':'Variable','VariableName':'choice'}],'Lookup key is current user selection')
label_action=next(acts[i-1]['WFWorkflowActionParameters'] for i,a in enumerate(acts) if a.get('WFWorkflowActionParameters',{}).get('WFVariableName')=='label')
def map_snapshot(devices):
 env={'choiceMap':{}}
 for device in devices:
  env.update(name=device['name'],id=device['id'])
  env['label']=render_native(label_action['WFTextActionText'],env)
  key=render_native(setter['WFDictionaryKey'],env);value=render_native(setter['WFDictionaryValue'],env)
  env['choiceMap'][key]=value
 return env['choiceMap']
snapshot1=map_snapshot([{'name':'Same Mac','id':'mac-old-111'},{'name':'Same Mac','id':'mac-live-222'}])
snapshot2=map_snapshot([{'name':'Same Mac','id':'mac-live-222'},{'name':'Same Mac','id':'mac-new-333'}])
check(len(snapshot1)==2 and len(snapshot2)==2,'Same-name devices remain unambiguous')
def resolve_selected(choice,mapping):
 if not choice or choice=='更换连接配置…':return None
 env={'choice':choice}
 return mapping.get(render_native(selected_getter['WFDictionaryKey'],env))
for label,device_id in snapshot2.items():check(resolve_selected(label,snapshot2)==device_id,'Current selection resolves current ID')
check(resolve_selected('Same Mac · mac-old-111',snapshot2) is None,'Removed old target cannot resolve')
for choice in ['',None,'更换连接配置…']:
 check(resolve_selected(choice,snapshot2) is None,'Cancellation/config entry yields no send target')
check(acts[selects[0]+2]['WFWorkflowActionParameters']['WFCondition']==101,'Actual selection guard is has-no-value')
recovery_selects=[i for i,a in enumerate(acts) if a['WFWorkflowActionIdentifier']=='is.workflow.actions.choosefromlist' and a['WFWorkflowActionParameters']['WFInput']['Value'].get('VariableName')=='recoveryOptions']
check(len(recovery_selects)==7,'All recoverable connection errors offer in-shortcut reimport')
for i in recovery_selects:
 guard=acts[i+2]['WFWorkflowActionParameters']
 check(guard['WFCondition']==4 and guard['WFConditionalActionString']=='重新导入连接配置','Only explicit reimport selection invokes self')
 call=acts[i+5]['WFWorkflowActionParameters']
 check(call['WFWorkflowName']=='SSClip发送' and call['WFInput']['Value']['VariableName']=='reimportMarker','Recovery passes harmless marker only')
 check(acts[i+9]['WFWorkflowActionIdentifier']=='is.workflow.actions.exit','Cancel/empty selection exits recovery branch without save/send')
check('删除 Shortcuts/SSClip/connection-state.json' not in source,'Do not require deleting state to recover bad credentials')
register_fields={q['WFKey']['Value']['string']:q for q in http[0]['WFJSONValues']['Value']['WFDictionaryFieldValueItems']}
capability=register_fields['can_receive']
check(capability['WFItemType']==4,'can_receive is native boolean dictionary type, not string or number')
check(capability['WFValue']['Value'] is False and capability['WFValue']['WFSerializationType']=='WFNumberSubstitutableState','can_receive serializes false, never string false')
check(register_fields['platform']['WFValue']['Value']['string']=='ios','Shared sender platform remains ios')
check(next(iter(register_fields['id']['WFValue']['Value']['attachmentsByRange'].values()))['VariableName']=='senderID','Register uses logical sender ID')
check(next(iter(fields['source']['Value']['attachmentsByRange'].values()))['VariableName']=='senderID','Send source matches logical sender')
check(any(q['WFDictionaryKey']=='transport' for q in lookups if isinstance(q['WFDictionaryKey'],str)),'Read transport via native dictionary action')
check('if @platform.text == "ios" {\n  if @transport.text == "bark"' in source,'Only Bark transport qualifies ios receiver')
check('if @id.text != @senderID' in source,'Reserved send-only sender always excluded')
# Protocol fixtures include explicit disabled receivers, missing capability is compatible.
receiver_fixtures=[({'id':'mac-recv-111','platform':'macos','transport':'relay','can_receive':True},True),({'id':'bark-ios-222','platform':'ios','transport':'bark','can_receive':True},True),({'id':'old-ios-333','platform':'ios','transport':'relay','can_receive':True},False),({'id':'ios-shortcut-sender','platform':'ios','transport':'relay','can_receive':False},False),({'id':'disabled-bark','platform':'ios','transport':'bark','can_receive':False},False),({'id':'disabled-mac','platform':'macos','transport':'relay','can_receive':False},False)]
for row,expected in receiver_fixtures:
 eligible=(row['platform']=='macos' or (row['platform']=='ios' and row['transport']=='bark')) and row['id']!='ios-shortcut-sender' and row.get('can_receive') is not False
 check(eligible==expected,'Current protocol receiver eligibility fixture')
# Execute the emitted minimal eligibility block rather than only mirror source.
eligible_start=next(i-1 for i,a in enumerate(acts) if a.get('WFWorkflowActionParameters',{}).get('WFVariableName')=='eligible')
def native_receiver_type(row):
 env={'platform':row['platform'],'transport':row.get('transport',''),'item':row};outputs={};enabled=[True]
 for a in acts[eligible_start:]:
  kind=a['WFWorkflowActionIdentifier'];q=a.get('WFWorkflowActionParameters',{})
  if kind=='is.workflow.actions.conditional':
   mode=q['WFControlFlowMode']
   if mode==0:
    variable=q['WFInput']['Variable']['Value']['VariableName']
    if variable=='eligible':return env['eligible']==1
    if q['WFCondition']==100:
     enabled.append(enabled[-1] and bool(env[variable]))
    else:
     check(q['WFCondition']==4,'Eligibility uses native exact string equality')
     enabled.append(enabled[-1] and env[variable]==q['WFConditionalActionString'])
   elif mode==2:enabled.pop()
   else:raise AssertionError('Unexpected eligibility branch shape')
  elif enabled[-1] and kind=='is.workflow.actions.detect.text':outputs[q['UUID']]=json.dumps(read_token(q['WFInput'],env,outputs),ensure_ascii=False)
  elif enabled[-1] and kind=='is.workflow.actions.text.match':outputs[q['UUID']]=re.findall(q['WFMatchTextPattern'],render_native(q['text'],env))
  elif enabled[-1] and kind=='is.workflow.actions.number':outputs[q['UUID']]=q['WFNumberActionNumber']
  elif enabled[-1] and kind=='is.workflow.actions.setvariable':env[q['WFVariableName']]=read_token(q['WFInput'],env,outputs)
 raise AssertionError('Missing eligibility gate')
for row,expected in receiver_fixtures:
 check((native_receiver_type(row) and row['id']!='ios-shortcut-sender')==expected,'Actual plist receiver predicate matches protocol fixture')
cap_pattern=next(a['WFWorkflowActionParameters']['WFMatchTextPattern'] for a in acts if a['WFWorkflowActionIdentifier']=='is.workflow.actions.text.match' and 'can_receive' in a['WFWorkflowActionParameters']['WFMatchTextPattern'])
for row,expected in [({'can_receive':False},True),({'can_receive':True},False),({},False),({'can_receive':'false'},False),({'name':'"can_receive":false'},False)]:
 check(bool(re.search(cap_pattern,json.dumps(row,ensure_ascii=False)))==expected,'Actual capability regex detects only JSON Boolean false')
print(f'PASS: {checks} structural/privacy/generated-dictionary checks; {len(acts)} main actions. iOS runtime and Apple signing NOT verified by these checks.')
for path in [resource()]:print(hashlib.sha256(path.read_bytes()).hexdigest(),path.name)
