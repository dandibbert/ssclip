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

def resource(chinese, ascii_name):
 for path in [ROOT/chinese, ROOT/ascii_name, ROOT.parent/'Resources'/ascii_name]:
  if path.exists(): return path
 raise FileNotFoundError(ascii_name)
main=plistlib.loads(resource('SSClip发送_unsigned.shortcut','SSClip-Send.unsigned.shortcut').read_bytes())
helper=plistlib.loads(resource('SSClip设置_unsigned.shortcut','SSClip-Settings.unsigned.shortcut').read_bytes())
for name,p in [('main',main),('helper',helper)]:
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
check(len(reads)==2,'State and identity only')
for q in reads:
 check(q['WFFileStorageService']=='iCloud Drive' and q['WFShowFilePicker'] is False and q['WFFileErrorIfNotFound'] is False,'Private persistent file lookup is noninteractive and missing-safe')
writes=[a['WFWorkflowActionParameters'] for a in acts if a['WFWorkflowActionIdentifier']=='is.workflow.actions.documentpicker.save']
check({q['WFFileDestinationPath'] for q in writes}=={'SSClip/phone-id.txt','SSClip/connection-state.json'},'No clipboard body persistence')
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
check(source.index('if @needsTarget == 1')<source.index('@clipboard = getClipboard()'),'Setup completes before clipboard access')
check('if @targetFound != 1' in source,'Missing target fails closed, no fallback')
check('if @returnedID.text == @messageID' in source and 'if @sendState.text == "pending"' in source,'Success requires matching message ID and state')
check(r'\Aios-[0-9]{9}-[0-9]{9}-[0-9]{9}-[0-9]{9}\z' in source,'Persistent high-entropy device identity validated')
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
h=[a for a in helper['WFWorkflowActions'] if a['WFWorkflowActionIdentifier']=='is.workflow.actions.runworkflow']
check(len(h)==1 and h[0]['WFWorkflowActionParameters']['WFWorkflowName']=='SSClip发送','Helper invokes exact main name')
check(not any(a['WFWorkflowActionIdentifier']=='is.workflow.actions.getclipboard' for a in helper['WFWorkflowActions']),'Helper does not read clipboard')
# Regression for the first real-iPhone failure: dictionary brackets compiled as
# object-property aggrandizements; derived UUIDs also aliased independent If groups.
for name,p in [('main',main),('helper',helper)]:
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
print(f'PASS: {checks} structural/privacy/generated-dictionary checks; {len(acts)} main actions, {len(helper["WFWorkflowActions"])} helper actions. iOS runtime and Apple signing NOT verified by these checks.')
for path in ROOT.glob('*_unsigned.shortcut'):print(hashlib.sha256(path.read_bytes()).hexdigest(),path.name)
