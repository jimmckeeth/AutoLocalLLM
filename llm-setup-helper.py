#!/usr/bin/env python3
"""AutoLocalLLM helper — cross-platform orchestrator + LlmFit utilities."""
import glob, json, os, re, stat, subprocess, sys, time

PREF_PROVIDERS = ['bartowski', 'unsloth', 'mradermacher']
LLMFIT_CACHE   = os.path.expanduser('~/.cache/llmfit/models')
WINDOWS        = sys.platform == 'win32'

# ─── ANSI color output ────────────────────────────────────────────────────────
_color = sys.stdout.isatty() if hasattr(sys.stdout, 'isatty') else False
if WINDOWS and _color:
    try:
        import ctypes
        ctypes.windll.kernel32.SetConsoleMode(
            ctypes.windll.kernel32.GetStdHandle(-11), 7)
    except Exception:
        _color = False

def _c(code, msg):  return f'\033[{code}m{msg}\033[0m' if _color else msg
def step(msg): print(f'\n  {_c(36, ">> " + msg)}')
def ok(msg):   print(f'     {_c(32, "OK  " + msg)}')
def warn(msg): print(f'     {_c(33, "**  " + msg)}')
def info(msg): print(f'     {_c(90, "..  " + msg)}')
def die(msg):  print(f'\n     {_c(31, "!!  Fatal: " + msg)}\n', file=sys.stderr); sys.exit(1)

# ─── HuggingFace cache check ──────────────────────────────────────────────────
def is_cached(repo, filename):
    hf_cache = os.path.expanduser('~/.cache/huggingface/hub')
    repo_dir  = 'models--' + repo.replace('/', '--')
    pattern   = os.path.join(hf_cache, repo_dir, 'snapshots', '*', filename)
    return bool(glob.glob(pattern))

# ─── LlmFit output → candidate list ──────────────────────────────────────────
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
            if source: break
        if not source: source = sources[0]
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

# ─── Table display ────────────────────────────────────────────────────────────
def print_table(candidates):
    W = 36; div = '─' * 84
    print(f'\n  {div}')
    print(f"  {'#':<3} | {'Model':<{W}} | {'Params':<7} | {'Score':<5} | {'VRAM%':<5} | {'Size':<6} | {'Cached'}")
    print(f'  {div}')
    for c in candidates:
        label = f"{c['gguf_basename']} ({c['quantization']})" if c['runner'] == 'llamacpp' else c['ollama_tag']
        if len(label) > W: label = label[:W - 1] + '…'
        color = '\033[33m' if c['index'] == 1 else '\033[90m'
        reset = '\033[0m'
        try:
            params = f"{round(float(str(c['params']).rstrip('B').strip()), 1)}B" if c['params'] is not None else '?'
        except (ValueError, TypeError):
            params = str(c['params'])
        mem    = f"{c['mem_pct']}%" if c['mem_pct'] is not None else '?'
        disk   = f"{c['disk_gb']:.1f}G" if c.get('disk_gb') is not None else '?'
        cached = '\033[32m yes\033[0m' if c.get('cached') else '\033[90m no\033[0m'
        print(f'  {color}{c["index"]:<3} | {label:<{W}} | {params:<7} | {c["score"]:<5} | {mem:<5} | {disk:<6}{reset} | {cached}')
    print(f'  {div}\n')

# ─── OpenCode config writer ───────────────────────────────────────────────────
def write_opencode_config(config_path, model_id, display_name, api_base, runner):
    os.makedirs(os.path.dirname(config_path), exist_ok=True)
    try:
        with open(config_path) as f: cfg = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError): cfg = {}
    cfg.setdefault('$schema', 'https://opencode.ai/config.json')
    cfg.setdefault('provider', {})
    provider_key  = 'llama-cpp' if runner == 'llamacpp' else 'ollama'
    provider_name = 'llama.cpp Local' if runner == 'llamacpp' else 'Ollama Local'
    cfg['provider'].setdefault(provider_key, {
        'npm': '@ai-sdk/openai-compatible', 'name': provider_name,
        'options': {'baseURL': f'{api_base}/v1'}, 'models': {},
    })
    provider = cfg['provider'][provider_key]
    provider.setdefault('models', {})
    provider['models'][model_id] = {'name': display_name, 'tools': True}
    with open(config_path, 'w') as f: json.dump(cfg, f, indent=2)
    return config_path

# ─── Model cache lookup ───────────────────────────────────────────────────────
def find_cached_model(repo, quant):
    """Return local path to a cached .gguf file, or None."""
    basename = repo.split('/')[-1].removesuffix('-GGUF')
    # llmfit cache: try both separators (bartowski uses '-', mradermacher uses '.')
    for sep in ('-', '.'):
        path = os.path.join(LLMFIT_CACHE, f'{basename}{sep}{quant}.gguf')
        if os.path.isfile(path): return path
    # Fuzzy llmfit cache: normalise punctuation for comparison
    if os.path.isdir(LLMFIT_CACHE):
        norm = lambda s: s.lower().translate(str.maketrans('-_.', '   '))
        b_norm = norm(basename); q_norm = norm(quant)
        for f in glob.glob(os.path.join(LLMFIT_CACHE, '*.gguf')):
            n = norm(os.path.basename(f))
            if b_norm in n and q_norm in n: return f
    # HuggingFace cache: both separators
    hf_cache = os.path.expanduser('~/.cache/huggingface/hub')
    repo_dir = 'models--' + repo.replace('/', '--')
    for sep in ('-', '.'):
        for m in glob.glob(os.path.join(hf_cache, repo_dir, 'snapshots', '*',
                                        f'{basename}{sep}{quant}.gguf')):
            return m
    return None

# ─── Model download ───────────────────────────────────────────────────────────
def download_model(repo, quant, hf_token=''):
    """Download via `llmfit download`. Returns local .gguf path."""
    os.makedirs(LLMFIT_CACHE, exist_ok=True)
    env = {**os.environ, **(({'HF_TOKEN': hf_token}) if hf_token else {})}

    # Try with --quant; if llmfit doesn't support the flag, retry without
    cmds = [
        ['llmfit', 'download', repo, '--quant', quant],
        ['llmfit', 'download', repo],
    ]
    lines = []
    for cmd in cmds:
        info(f'Running: {" ".join(cmd)}')
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, env=env, bufsize=1)
        lines = []
        for line in proc.stdout:
            s = line.rstrip(); lines.append(s)
            print(f'     {_c(90, s[:78])}')
        proc.wait()
        if proc.returncode == 0: break
        if '--quant' in cmd:
            warn('llmfit download --quant not accepted; retrying without --quant')
            continue
        die(f'llmfit download failed (exit {proc.returncode})')

    # Parse output for .gguf path
    for line in reversed(lines):
        if '.gguf' in line:
            m = re.search(r'((?:/|~)[^\s:]+\.gguf|[A-Za-z]:\\[^\s:]+\.gguf)', line)
            if m:
                path = os.path.expanduser(m.group(1))
                if os.path.isfile(path): return path

    path = find_cached_model(repo, quant)
    if path: return path
    die(f'Could not locate downloaded model in {LLMFIT_CACHE}')

# ─── llama-server launcher ────────────────────────────────────────────────────
def start_server(model_path, port, context, bin_dir, lib_dir, share_dir, hf_token=''):
    """Launch llama-server --model <path>; poll /health. Returns api_root URL."""
    import urllib.request
    api_root   = f'http://127.0.0.1:{port}'
    health_url = f'{api_root}/health'

    try:
        with urllib.request.urlopen(health_url, timeout=2) as r:
            if json.loads(r.read()).get('status') == 'ok':
                ok(f'llama-server already running on {api_root}'); return api_root
    except Exception: pass

    step(f'Starting llama-server  ({os.path.basename(model_path)})')
    os.makedirs(share_dir, exist_ok=True)
    log_path = os.path.join(share_dir, 'llama-server.log')

    cmd = ['llama-server', '--model', model_path, '-c', str(context),
           '--host', '127.0.0.1', '--port', str(port), '--jinja']
    info(f'  {" ".join(cmd)}')

    env = dict(os.environ)
    if not WINDOWS:
        ld = env.get('LD_LIBRARY_PATH', '')
        env['LD_LIBRARY_PATH'] = f'{lib_dir}:{bin_dir}' + (f':{ld}' if ld else '')
    if hf_token: env['HF_TOKEN'] = hf_token

    with open(log_path, 'w') as logf:
        proc = subprocess.Popen(cmd, stdout=logf, stderr=subprocess.STDOUT, env=env)
    info(f'PID {proc.pid}  log: {log_path}')

    timeout = 600; interval = 3; elapsed = 0
    print()
    while elapsed < timeout:
        time.sleep(interval); elapsed += interval
        try:
            lines = [l.rstrip() for l in open(log_path) if l.strip()]
            last = lines[-1][:75] if lines else 'starting…'
        except Exception: last = 'starting…'
        print(f'\r     {_c(90, f"{last:<75}")}', end='', flush=True)
        try:
            with urllib.request.urlopen(health_url, timeout=2) as r:
                if json.loads(r.read()).get('status') == 'ok':
                    print(); ok(f'llama-server ready  ({api_root})'); return api_root
        except Exception: pass
        if proc.poll() is not None:
            print(); die(f'llama-server exited unexpectedly. Check log: {log_path}')
    print(); die(f'llama-server did not become ready within {timeout}s. Check log: {log_path}')

# ─── Startup script writer ────────────────────────────────────────────────────
def write_startup_script(model_path, port, context, lib_dir, bin_dir, share_dir, hf_token=''):
    os.makedirs(share_dir, exist_ok=True)
    if WINDOWS:
        script_path = os.path.join(share_dir, 'Start-LlamaServer.ps1')
        tok = f"$env:HF_TOKEN = '{hf_token}'" if hf_token else '# $env:HF_TOKEN = "hf_xxx"'
        content = (
            '# Auto-generated by llm-setup-helper.py\n'
            'Set-StrictMode -Version Latest; $ErrorActionPreference = \'Stop\'\n'
            f'{tok}\n'
            f'$h = "http://127.0.0.1:{port}/health"\n'
            f'try {{ if ((Invoke-RestMethod -Uri $h -TimeoutSec 2).status -eq \'ok\')'
            f' {{ Write-Host "llama-server already running."; exit 0 }} }} catch {{}}\n'
            f'Write-Host "Starting llama-server on http://127.0.0.1:{port} ..."\n'
            f'llama-server --model "{model_path}" -c {context} --host 127.0.0.1 --port {port} --jinja\n'
        )
    else:
        script_path = os.path.join(share_dir, 'start-llama-server.sh')
        tok = f"export HF_TOKEN='{hf_token}'" if hf_token else ''
        content = (
            '#!/usr/bin/env bash\n# Auto-generated by llm-setup-helper.py\n'
            'set -euo pipefail\n'
            f'export LD_LIBRARY_PATH="{lib_dir}:{bin_dir}${{LD_LIBRARY_PATH:+:${{LD_LIBRARY_PATH}}}}"\n'
            f'{tok}\n'
            f'API_ROOT="http://127.0.0.1:{port}"\n'
            'if curl -fsS "${API_ROOT}/health" 2>/dev/null | grep -q \'"ok"\'; then\n'
            '    echo "llama-server already running on ${API_ROOT}"; exit 0\nfi\n'
            'echo "Starting llama-server on ${API_ROOT} ..."\n'
            f'exec llama-server --model "{model_path}" -c {context} --host 127.0.0.1 --port {port} --jinja\n'
        )
    with open(script_path, 'w') as f: f.write(content)
    if not WINDOWS: os.chmod(script_path, 0o755)
    ok(f'Startup script: {script_path}')
    return script_path

# ─── Setup orchestration ──────────────────────────────────────────────────────
def cmd_setup():
    import argparse
    p = argparse.ArgumentParser(prog='llm-setup-helper.py setup')
    p.add_argument('--port',      type=int, default=8080)
    p.add_argument('--context',   type=int, default=16384)
    p.add_argument('--manual',    action='store_true')
    p.add_argument('--hf-token',  default='', dest='hf_token')
    p.add_argument('--force',     action='store_true')
    p.add_argument('--update',    action='store_true')
    p.add_argument('--top-n',     type=int, default=None, dest='top_n')
    p.add_argument('--bin-dir',   default=os.path.expanduser('~/.local/bin'), dest='bin_dir')
    p.add_argument('--lib-dir',   default=os.path.expanduser('~/.local/lib'), dest='lib_dir')
    p.add_argument('--share-dir', default=os.path.expanduser('~/.local/share/autolocalllm'), dest='share_dir')
    args = p.parse_args(sys.argv[2:])

    mg = '\033[35m' if _color else ''; cy = '\033[36m' if _color else ''
    gy = '\033[90m' if _color else ''; rs = '\033[0m' if _color else ''
    print()
    print(f'  {mg}+------------------------------------------------------------+{rs}')
    print(f'  {mg}|   AutoLocalLLM  --  LlmFit -> llama.cpp -> OpenCode       |{rs}')
    print(f'  {mg}+------------------------------------------------------------+{rs}')
    if args.manual:
        print(f'  {cy}Mode: manual selection{rs}')
    else:
        print(f'  {gy}Mode: auto  (use --manual to pick){rs}')
    print()

    # 1. Optionally refresh llmfit database (opt-in to avoid regression)
    if args.update:
        step('Updating LlmFit model cache')
        res = subprocess.run(['llmfit', 'update'], capture_output=True, text=True)
        if res.returncode != 0:
            warn('llmfit update failed — using cached data (may be stale)')
        else:
            ok('LlmFit cache updated')

    # 2. Query llmfit
    step('Querying LlmFit: coding models for this hardware')
    llmfit_cmd = ['llmfit', 'recommend', '--json', '--use-case', 'coding',
                  '--capability', 'tool_use', '--min-fit', 'good']
    if args.top_n:
        llmfit_cmd += ['--limit', str(args.top_n)]
    res = subprocess.run(llmfit_cmd, capture_output=True, text=True)
    if res.returncode != 0:
        die(f'LlmFit failed:\n{res.stderr}')
    try:
        raw = json.loads(res.stdout)
        models = raw['models'] if isinstance(raw, dict) and 'models' in raw else raw
    except json.JSONDecodeError:
        die('Could not parse LlmFit JSON output.')

    # 3. Build and display candidates
    candidates = build_candidates(models)
    if not candidates:
        die('No candidates found. Try --update or check llmfit supports your hardware.')
    info(f'Found {len(candidates)} candidate(s)')

    step('Candidate models')
    print_table(candidates)

    # 4. Select model
    if not args.manual:
        info('Auto-selecting #1  (use --manual to pick)')
        selected = candidates[0]
    else:
        count = len(candidates)
        selected = candidates[0]
        while True:
            try:
                choice = input(f'  Enter number [1-{count}] or press Enter for #1: ').strip()
            except (EOFError, KeyboardInterrupt):
                break
            if not choice: break
            try:
                n = int(choice)
                if 1 <= n <= count:
                    selected = candidates[n - 1]; break
            except ValueError: pass
            warn(f'Please enter a number between 1 and {count}.')

    print()
    print('  Chosen model')
    info(f"HuggingFace : {selected['hf_id']}")
    info(f"GGUF repo   : {selected['gguf_repo']}")
    info(f"Quantization: {selected['quantization']}")
    info(f"Score       : {selected['score']}   Params: {selected['params']}B   VRAM: {selected['mem_pct']}%")

    # 5. Locate or download model
    repo  = selected['gguf_repo']
    quant = selected['quantization']
    model_path = None if args.force else find_cached_model(repo, quant)
    if model_path:
        ok(f'Using cached model: {model_path}')
    else:
        step('Downloading model via llmfit')
        model_path = download_model(repo, quant, args.hf_token)
        ok(f'Downloaded: {model_path}')

    # 6. Start llama-server
    api_root = start_server(model_path, args.port, args.context,
                            args.bin_dir, args.lib_dir, args.share_dir, args.hf_token)

    # 7. Write OpenCode config
    basename     = selected['gguf_basename']
    model_id     = f'{basename}-{quant}'.lower()
    display_name = f'{basename} ({quant}, ctx={args.context})'
    config_path  = os.path.expanduser('~/.config/opencode/config.json')
    write_opencode_config(config_path, model_id, display_name, api_root, 'llamacpp')
    ok(f'OpenCode config: {config_path}')

    # 8. Write startup script
    startup = write_startup_script(model_path, args.port, args.context,
                                   args.lib_dir, args.bin_dir, args.share_dir, args.hf_token)

    # 9. Done
    gn = '\033[32m' if _color else ''; yw = '\033[33m' if _color else ''
    print()
    print(f'  {gn}+------------------------------------------------------------+{rs}')
    print(f'  {gn}|                   Setup Complete!                          |{rs}')
    print(f'  {gn}+------------------------------------------------------------+{rs}')
    print()
    print(f'  {yw}Model    :{rs} {model_id}')
    print(f'  {yw}Server   :{rs} {api_root}')
    print(f'  {yw}Config   :{rs} {config_path}')
    print(f'  {yw}Relaunch :{rs} {startup}')
    print()
    print('  Start coding now:')
    print(f'    {cy}opencode{rs}')
    print()
    print('  Press Ctrl+K inside OpenCode to open the model picker, then select:')
    print(f'    {cy}llama-cpp > {model_id}{rs}')
    print()
    print(f'  {gy}After a reboot, restart the model server:{rs}')
    launch = f'bash {startup}' if not WINDOWS else startup
    print(f'  {gy}  {launch}{rs}')
    print()

# ─── Legacy subcommand shims (used by bash script during transitions) ─────────
def cmd_filter():
    raw = sys.stdin.read()
    try:
        data = json.loads(raw)
        models = data['models'] if isinstance(data, dict) and 'models' in data else data
    except json.JSONDecodeError:
        print('[]'); return
    print(json.dumps(build_candidates(models), indent=2))

def cmd_table():
    print_table(json.load(sys.stdin))

def cmd_get():
    idx = int(sys.argv[2]) - 1
    candidates = json.load(sys.stdin)
    if idx < 0 or idx >= len(candidates):
        sys.exit(f'Index {idx+1} out of range (1-{len(candidates)})')
    print(json.dumps(candidates[idx]))

def cmd_len():
    print(len(json.load(sys.stdin)))

def cmd_field():
    field = sys.argv[2]; candidates = json.load(sys.stdin)
    idx   = int(sys.argv[3]) - 1 if len(sys.argv) > 3 else 0
    print(candidates[idx].get(field, ''))

def cmd_sel():
    field = sys.argv[2]
    print(json.load(sys.stdin).get(field, ''))

def cmd_cached():
    repo, filename = sys.argv[2], sys.argv[3]
    print('yes' if is_cached(repo, filename) else 'no')

def cmd_config():
    config_path, model_id, display_name, api_base, runner = sys.argv[2:7]
    print(write_opencode_config(config_path, model_id, display_name, api_base, runner))

# ─── Dispatch ─────────────────────────────────────────────────────────────────
dispatch = {
    'setup':  cmd_setup,
    'filter': cmd_filter, 'table': cmd_table,  'get':    cmd_get,
    'len':    cmd_len,    'field': cmd_field,   'sel':    cmd_sel,
    'cached': cmd_cached, 'config': cmd_config,
}
cmd = sys.argv[1] if len(sys.argv) > 1 else ''
fn  = dispatch.get(cmd)
if fn:
    fn()
else:
    sys.exit(f'Unknown subcommand: {cmd}  (available: {", ".join(dispatch)})')
