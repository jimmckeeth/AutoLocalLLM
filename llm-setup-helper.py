#!/usr/bin/env python3
"""AutoLocalLLM helper — LlmFit filtering, table display, config writer."""
import json, sys, os, glob

PREF_PROVIDERS = ['bartowski', 'unsloth', 'mradermacher']

def is_cached(repo, filename):
    hf_cache = os.path.expanduser('~/.cache/huggingface/hub')
    repo_dir  = 'models--' + repo.replace('/', '--')
    pattern   = os.path.join(hf_cache, repo_dir, 'snapshots', '*', filename)
    return bool(glob.glob(pattern))

def build_candidates(models):
    candidates = []
    for m in models:
        hf_id   = m.get('name', '')
        sources = m.get('gguf_sources') or []
        if not sources:
            print(f'  Skip (no GGUF source): {hf_id}', file=sys.stderr)
            continue
        source = None
        for prov in PREF_PROVIDERS:
            source = next((s for s in sources if s.get('provider') == prov), None)
            if source:
                break
        if not source:
            source = sources[0]
        repo     = source['repo']
        basename = repo.split('/')[-1].removesuffix('-GGUF')
        quant    = m.get('best_quant') or 'Q4_K_M'
        filename = f'{basename}-{quant}.gguf'
        candidates.append({
            'index':         len(candidates) + 1,
            'hf_id':         hf_id,
            'runner':        'llamacpp',
            'gguf_repo':     repo,
            'gguf_basename': basename,
            'template':      '',
            'ollama_tag':    '',
            'quantization':  quant,
            'score':         round(float(m.get('score') or 0), 1),
            'params':        m.get('params_b'),
            'mem_pct':       m.get('utilization_pct', '?'),
            'disk_gb':       m.get('disk_size_gb'),
            'cached':        is_cached(repo, filename),
        })
    return candidates

def cmd_filter():
    raw = sys.stdin.read()
    try:
        data = json.loads(raw)
        models = data['models'] if isinstance(data, dict) and 'models' in data else data
    except json.JSONDecodeError:
        print('[]'); return
    print(json.dumps(build_candidates(models), indent=2))

def cmd_table():
    candidates = json.load(sys.stdin)
    W = 36
    div = '─' * 84
    print(f'\n  {div}')
    print(f"  {'#':<3} | {'Model':<{W}} | {'Params':<7} | {'Score':<5} | {'VRAM%':<5} | {'Size':<6} | {'Cached'}")
    print(f'  {div}')
    for c in candidates:
        if c['runner'] == 'llamacpp':
            label  = f"{c['gguf_basename']} ({c['quantization']})"
            runner = 'llama.cpp'
        else:
            label  = c['ollama_tag']
            runner = 'Ollama'
        if len(label) > W:
            label = label[:W - 1] + '…'
        color = '\033[33m' if c['index'] == 1 else '\033[90m'
        reset = '\033[0m'
        try:
            params = f"{round(float(str(c['params']).rstrip('B').strip()), 1)}B" if c['params'] is not None else '?'
        except (ValueError, TypeError):
            params = str(c['params'])
        mem    = f"{c['mem_pct']}%" if c['mem_pct'] is not None else '?'
        disk   = f"{c['disk_gb']:.1f}G"  if c.get('disk_gb') is not None else '?'
        cached = '\033[32m yes\033[0m' if c.get('cached') else '\033[90m no\033[0m'
        print(f'  {color}{c["index"]:<3} | {label:<{W}} | {params:<7} | {c["score"]:<5} | {mem:<5} | {disk:<6}{reset} | {cached}')
    print(f'  {div}\n')

def cmd_get():
    idx        = int(sys.argv[2]) - 1
    candidates = json.load(sys.stdin)
    if idx < 0 or idx >= len(candidates):
        sys.exit(f'Index {idx+1} out of range (1-{len(candidates)})')
    print(json.dumps(candidates[idx]))

def cmd_len():
    candidates = json.load(sys.stdin)
    print(len(candidates))

def cmd_field():
    field      = sys.argv[2]
    candidates = json.load(sys.stdin)
    idx        = int(sys.argv[3]) - 1 if len(sys.argv) > 3 else 0
    print(candidates[idx].get(field, ''))

def cmd_sel():
    field = sys.argv[2]
    obj   = json.load(sys.stdin)
    print(obj.get(field, ''))

def cmd_cached():
    repo, filename = sys.argv[2], sys.argv[3]
    print('yes' if is_cached(repo, filename) else 'no')

def cmd_config():
    config_path  = sys.argv[2]
    model_id     = sys.argv[3]
    display_name = sys.argv[4]
    api_base     = sys.argv[5]
    runner       = sys.argv[6]

    os.makedirs(os.path.dirname(config_path), exist_ok=True)
    try:
        with open(config_path) as f:
            cfg = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        cfg = {}

    cfg.setdefault('$schema', 'https://opencode.ai/config.json')
    cfg.setdefault('provider', {})

    provider_key  = 'llama-cpp' if runner == 'llamacpp' else 'ollama'
    provider_name = 'llama.cpp Local' if runner == 'llamacpp' else 'Ollama Local'

    cfg['provider'].setdefault(provider_key, {
        'npm':     '@ai-sdk/openai-compatible',
        'name':    provider_name,
        'options': {'baseURL': f'{api_base}/v1'},
        'models':  {},
    })

    provider = cfg['provider'][provider_key]
    provider.setdefault('models', {})
    provider['models'][model_id] = {'name': display_name, 'tools': True}

    with open(config_path, 'w') as f:
        json.dump(cfg, f, indent=2)
    print(config_path)

dispatch = {
    'filter': cmd_filter, 'table': cmd_table, 'get': cmd_get,
    'len': cmd_len, 'field': cmd_field, 'sel': cmd_sel,
    'cached': cmd_cached, 'config': cmd_config,
}
cmd = sys.argv[1] if len(sys.argv) > 1 else ''
fn  = dispatch.get(cmd)
if fn:
    fn()
else:
    sys.exit(f'Unknown subcommand: {cmd}  (available: {", ".join(dispatch)})')
