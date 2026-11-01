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

def resource(chinese, ascii):
 for path in [ROOT/chinese, ROOT/ascii, ROOT.parent/'Resources'/ascii]:
  if path.exists(): return path
 raise FileNotFoundError(ascii)
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
check('@configLength = @config64Length / 4' in source and '@configLength -= @configPadding' in source,'Config limit uses UTF-8 byte calculation too')
# Verify the exact native base64-length arithmetic for ASCII/Chinese/emoji/multiline/quotes/backslash.
for sample in ['','a','ab','abc','中文😀\n"quote"\\tab\t','a'*32768,'a'*32769,'😀'*8192,'😀'*8193]:
 encoded=base64.encodebytes(sample.encode()).decode()
 compact=re.sub(r'\s','',encoded)
 padding=2 if compact.endswith('==') else 1 if compact.endswith('=') else 0
 measured=len(compact)/4*3-padding
 check(measured==len(sample.encode('utf-8')),'UTF-8 length math mismatch')
 obj={'text':sample};check(json.loads(json.dumps(obj))['text']==sample,'JSON semantic roundtrip')
h=[a for a in helper['WFWorkflowActions'] if a['WFWorkflowActionIdentifier']=='is.workflow.actions.runworkflow']
check(len(h)==1 and h[0]['WFWorkflowActionParameters']['WFWorkflowName']=='SSClip发送','Helper invokes exact main name')
check(not any(a['WFWorkflowActionIdentifier']=='is.workflow.actions.getclipboard' for a in helper['WFWorkflowActions']),'Helper does not read clipboard')
print(f'PASS: {checks} structural/privacy/math checks; {len(acts)} main actions, {len(helper["WFWorkflowActions"])} helper actions. iOS runtime and Apple signing NOT verified by these checks.')
for path in ROOT.glob('*_unsigned.shortcut'):print(hashlib.sha256(path.read_bytes()).hexdigest(),path.name)
