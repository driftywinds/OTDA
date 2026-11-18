import json, pathlib, collections

d = json.loads(pathlib.Path(r'W:\repos\OTDA\_research\OpenTodo\docs\openapi.json').read_text(encoding='utf-8'))
rows = json.loads(pathlib.Path(r'W:\repos\OTDA\spec\routes_full.json').read_text(encoding='utf-8'))['routes']
meta = {}
for p, item in d['paths'].items():
    for m, op in item.items():
        meta[(m.upper(), p)] = op

AI = {'In-app assistant', 'AI assistants (MCP)', 'Routines',
      'Keeping a project away from assistants', 'Agent tokens'}
AREAS = {'Administration (owner and admins)', 'Your account and credentials',
         'Integrations', 'Workspaces'}

stat = collections.defaultdict(lambda: [0, 0])
blocked = []
for r in rows:
    op = meta.get((r['method'], r['path']))
    if not op:
        continue
    tags = op.get('tags') or []
    if not (set(tags) & AREAS):
        continue
    pol = op.get('x-opentodo-policy', '') or ''
    area = next((t for t in tags if t not in AI), tags[0] if tags else '?')
    dead = ('session-only' in pol) or ('credential' in pol)
    stat[area][0] += 1
    if dead:
        stat[area][1] += 1
        blocked.append((r['method'], r['path'], pol))

for a, (n, b) in sorted(stat.items(), key=lambda x: -x[1][0]):
    print(f'{a:42s} {n:3d} ops | {n-b:3d} token-ok | {b:3d} need a session')
print('\nsession/credential-gated:')
for m, p, pol in sorted(blocked, key=lambda x: x[1]):
    print(f'  {m:6s} {p:60s} {pol}')
print(f'\ntotal blocked {len(blocked)} of {sum(v[0] for v in stat.values())}')
