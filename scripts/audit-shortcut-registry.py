#!/usr/bin/env python3
"""Read-only comparison with Apple-shipped action registries. Never scans user data."""
import hashlib
import json
import pathlib
import plistlib
import sys

ROOTS = [
    pathlib.Path('/System/Library/PrivateFrameworks/WorkflowKit.framework'),
    pathlib.Path('/System/Library/PrivateFrameworks/ActionKit.framework'),
    pathlib.Path('/System/Library/PrivateFrameworks/WorkflowUI.framework'),
    pathlib.Path('/System/Applications/Shortcuts.app'),
    pathlib.Path('/System/Library/PrivateFrameworks/WorkflowActions.framework'),
    pathlib.Path('/System/Library/Frameworks/Shortcuts.framework'),
]
MAX_BYTES = 16 * 1024 * 1024
META = {'UUID', 'CustomOutputName', 'GroupingIdentifier', 'WFControlFlowMode'}
used = {}
for filename in sys.argv[1:] or ['Resources/SSClip-Send.unsigned.shortcut', 'Resources/SSClip-Settings.unsigned.shortcut']:
    value = plistlib.loads(pathlib.Path(filename).read_bytes())
    for action in value['WFWorkflowActions']:
        identifier = action['WFWorkflowActionIdentifier']
        used.setdefault(identifier, set()).update(action.get('WFWorkflowActionParameters', {}))

registries, definitions, errors = [], {}, []
inventory, candidate_summaries = [], []
seen_paths = set()

def collect(value, found):
    if isinstance(value, dict):
        # Workflow examples are not schema definitions.
        if 'WFWorkflowActions' in value:
            return
        for key, child in value.items():
            if key.startswith('is.workflow.actions.') and isinstance(child, dict):
                found[key] = child
            elif isinstance(child, (dict, list)):
                collect(child, found)
        identifier = value.get('Identifier') or value.get('ActionIdentifier') or value.get('WFActionIdentifier')
        if isinstance(identifier, str) and identifier.startswith('is.workflow.actions.') and 'Parameters' in value:
            found[identifier] = value
    elif isinstance(value, list):
        for child in value:
            collect(child, found)

def parameter_summary(value):
    result = {}
    def walk(item):
        if isinstance(item, dict):
            key = item.get('Key') or item.get('WFParameterKey')
            if isinstance(key, str):
                result[key] = {field: item[field] for field in ('Class', 'WFParameterClass', 'Type', 'Required') if field in item}
            for child in item.values():
                if isinstance(child, (dict, list)):
                    walk(child)
        elif isinstance(item, list):
            for child in item:
                walk(child)
    walk(value.get('Parameters', []))
    return result

for root in ROOTS:
    record = {'path': str(root), 'exists': root.exists()}
    inventory.append(record)
    if not root.exists():
        continue
    resolved_root = root.resolve()
    candidates = list(root.rglob('*.plist')) + list(root.rglob('*.json'))
    record['candidate_count'] = len(candidates)
    record['action_related_filenames'] = sorted(str(p) for p in root.rglob('*') if p.is_file() and ('action' in p.name.lower() or 'tool' in p.name.lower()))[:60]
    for path in sorted(candidates)[:2000]:
        try:
            real = path.resolve()
            if not real.is_relative_to(resolved_root) or real in seen_paths:
                continue
            seen_paths.add(real)
            if real.stat().st_size > MAX_BYTES:
                continue
            data = real.read_bytes()
            value = json.loads(data) if path.suffix == '.json' else plistlib.loads(data)
            if len(candidate_summaries) < 80:
                candidate_summaries.append({'path': str(real), 'size': len(data), 'root_type': type(value).__name__, 'top_keys': list(value)[:30] if isinstance(value, dict) else []})
            found = {}
            collect(value, found)
            if not found:
                continue
            source = {'path': str(real), 'sha256': hashlib.sha256(data).hexdigest(), 'definition_count': len(found)}
            registries.append(source)
            for identifier, definition in found.items():
                # Prefer the registry with explicit parameter definitions over fallback metadata.
                if identifier not in definitions or len(parameter_summary(definition)) > len(parameter_summary(definitions[identifier][0])):
                    definitions[identifier] = (definition, source)
        except (OSError, ValueError, plistlib.InvalidFileException) as error:
            errors.append({'path': str(path), 'error_type': type(error).__name__})

matches, unknown = {}, []
for identifier in sorted(used):
    if identifier not in definitions:
        unknown.append(identifier)
        continue
    definition, source = definitions[identifier]
    parameters = parameter_summary(definition)
    used_keys = sorted(used[identifier])
    matches[identifier] = {
        'registry_path': source['path'], 'registry_sha256': source['sha256'],
        'used_keys': used_keys,
        'declared_parameters': parameters,
        'generic_metadata_keys': sorted(used[identifier] & META),
        'keys_not_in_parameter_schema': sorted(used[identifier] - set(parameters) - META),
        'input_schema': definition.get('Input'),
        'output_schema': definition.get('Output'),
        'action_class': definition.get('Class'),
    }
report = {
    'scope': 'Only Apple system WorkflowKit, ActionKit, WorkflowUI and Shortcuts.app plist/json resources; no home or user data.',
    'status': 'unverified_no_registry' if not registries else ('unknown_action_ids' if unknown else 'action_ids_verified_parameter_comparison_reported'),
    'limitations': 'macOS registry evidence is not iOS import/execution, variable-token evaluation, official signing or runtime permissions validation. Unknown parameter keys require review, not assumed valid.',
    'registry_files': registries,
    'root_inventory': inventory,
    'candidate_summaries': candidate_summaries,
    'matched_actions': matches,
    'unknown_action_ids': unknown,
    'read_error_count': len(errors),
    'read_error_examples': errors[:10],
}
pathlib.Path('shortcut-registry-audit.json').write_text(json.dumps(report, ensure_ascii=False, indent=2, default=str) + '\n')
print('REGISTRY_AUDIT_STATUS', report['status'])
print('REGISTRY_FILES', len(registries), 'MATCHED_ACTIONS', len(matches), 'UNKNOWN_ACTIONS', len(unknown))
for source in registries:
    print('REGISTRY', source['path'], source['sha256'])
for identifier in unknown:
    print('UNVERIFIED_ACTION', identifier)
for identifier, item in matches.items():
    if item['keys_not_in_parameter_schema']:
        print('PARAMETER_REVIEW', identifier, ','.join(item['keys_not_in_parameter_schema']))
raise SystemExit(0 if registries and not unknown else 2)
