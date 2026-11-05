#!/usr/bin/env python3
"""Attempt to regenerate reviewed client patches from decrypted IPAs (macOS/Xcode)."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
MATCHER = Path('Sources/tgapiC/NativeTLProfile.inc')


def run(command, cwd):
    result = subprocess.run([str(arg) for arg in command], cwd=cwd,
                            capture_output=True, text=True, timeout=300)
    if result.returncode:
        raise ValueError(((result.stderr+'\n'+result.stdout).strip() or
                          f'command exited with {result.returncode}')[-4000:].strip())
    return result.stdout


def generate(work, tool, *arguments):
    return run([sys.executable, work/'Tools'/tool, *arguments], work)


def validate(work, profile, ipas, engine):
    if not engine:
        return
    archive = work/'profile.ipatch'
    run([engine, '-pack', profile/'patch.json', '-output', archive], work)
    value = json.loads((profile/'patch.json').read_text())
    features = [item['id'] for item in value['components'] if item['id'] != 'required']
    selection = work/'selection.json'
    selection.write_text(json.dumps({str(archive): features}))
    for ipa in ipas:
        report = json.loads(run([engine, '-dry-run', '-ipa', ipa, '-package', archive,
                                 '-feature-selection', selection], work))
        if report.get('error') or not (report.get('plan') or {}).get('patches'):
            raise ValueError(f'{ipa.name}: {report.get("error") or "engine produced no binary edits"}')


def native(work, ipas, engine):
    generate(work, 'prepare_native_tl.py', ipas[0])
    # A shared profile must still describe every supplied client exactly.
    for ipa in ipas[1:]:
        generate(work, 'prepare_native_tl.py', ipa, '--check')
    profile = work/'Patches/native-tl-v1'
    validate(work, profile, ipas, engine)
    return [profile.relative_to(work), MATCHER]


def rust(work, ipa, engine):
    archive = work/'rust.ipatch'
    generate(work, 'prepare_rust_patch.py', ipa, archive,
             '--patch-set-dir', work/'Patches', '--allow-no-rust')
    if not archive.exists():
        print('  No Rust runtime; existing MtProtoKit hooks apply.')
        return []
    with zipfile.ZipFile(archive) as package:
        value = json.loads(package.read('manifest.json'))
    identifier = value['components'][0]['variants'][0]['id']
    profile = work/'Patches'/identifier
    validate(work, profile, [ipa], engine)
    return [profile.relative_to(work)]


def secret(work, telegram, swiftgram, engine):
    generate(work, 'prepare_secret_chats.py', '--telegram', telegram, '--swiftgram', swiftgram)
    profile = work/'Patches/secret-chats-v1'
    validate(work, profile, [telegram, swiftgram], engine)
    return [profile.relative_to(work)]


def pro(work, swiftgram, engine):
    # There is no generator for changed Swift metadata or decoder code.
    generate(work, 'build_payloads.py')
    validate(work, work/'Patches/swiftgram-pro-status-v1', [swiftgram], engine)
    return [Path('Patches/swiftgram-pro-status-v1')]


def attempt(root, label, action, check=False):
    print(f'{label}: attempting...', flush=True)
    try:
        with tempfile.TemporaryDirectory(prefix='tgextra-update-patches-') as directory:
            work = Path(directory)
            for name in ('Tools', 'Patches'):
                shutil.copytree(root/name, work/name, ignore=shutil.ignore_patterns('__pycache__', '*.bin'))
            (work/MATCHER).parent.mkdir(parents=True)
            shutil.copy2(root/MATCHER, work/MATCHER)
            outputs = action(work)
            files = []
            for relative in outputs:
                source = work/relative
                files.extend(sorted(source.rglob('*')) if source.is_dir() else [source])
            files = [source for source in files if source.is_file()]
            changed = [str(source.relative_to(work)) for source in files
                       if source.suffix != '.bin' and
                       (not (root/source.relative_to(work)).exists() or
                        source.read_bytes() != (root/source.relative_to(work)).read_bytes())]
            if check and changed:
                raise ValueError('generated files differ:\n  '+'\n  '.join(changed))
            if not check:
                for source in files:
                    destination = root/source.relative_to(work)
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(source, destination)
            print(f'{label}: '+('up to date' if check else f'OK ({len(changed)} changed source files)'))
            return True
    except (ValueError, OSError, subprocess.TimeoutExpired) as error:
        print(f'{label}: FAILED\n{error}', file=sys.stderr, flush=True)
        return False


def find_ipa(packages, client, explicit):
    if explicit:
        path = explicit.resolve()
        if not path.is_file():
            raise ValueError(f'IPA does not exist: {path}')
        return path
    candidates = sorted(path.resolve() for path in packages.glob('*.ipa')
                        if path.name.lower().startswith(client))
    if len(candidates) > 1:
        raise ValueError(f'multiple {client} IPAs in {packages}; select one with --{client}')
    return candidates[0] if candidates else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--telegram', type=Path, help='decrypted Telegram IPA; otherwise discover in packages/')
    parser.add_argument('--swiftgram', type=Path, help='decrypted Swiftgram IPA; otherwise discover in packages/')
    parser.add_argument('--packages', type=Path, default=ROOT/'packages', help='IPA discovery directory')
    parser.add_argument('--engine', type=Path, default=os.environ.get('IPATCH_ENGINE_CLI') or None,
                        help='v4 ipatch CLI for dry-run validation; defaults to IPATCH_ENGINE_CLI')
    parser.add_argument('--check', action='store_true', help='generate and compare without changing the checkout')
    args = parser.parse_args()
    try:
        telegram = find_ipa(args.packages, 'telegram', args.telegram)
        swiftgram = find_ipa(args.packages, 'swiftgram', args.swiftgram)
        if not telegram and not swiftgram:
            raise ValueError('no reference IPAs; provide --telegram/--swiftgram or put IPAs in packages/')
        engine = args.engine.resolve() if args.engine else None
        if engine and (not engine.is_file() or not os.access(engine, os.X_OK)):
            raise ValueError(f'engine is not executable: {engine}')
    except ValueError as error:
        parser.error(str(error))
    if not engine:
        print('Engine validation skipped; pass --engine or set IPATCH_ENGINE_CLI.')
    ipas = [ipa for ipa in (telegram, swiftgram) if ipa]
    results = [attempt(ROOT, 'Native TL', lambda work: native(work, ipas, engine), args.check)]
    for ipa in ipas:
        results.append(attempt(ROOT, f'Rust Bridge ({ipa.name})',
                               lambda work: rust(work, ipa, engine), args.check))
    if telegram and swiftgram:
        results.append(attempt(ROOT, 'Secret Chats',
                               lambda work: secret(work, telegram, swiftgram, engine), args.check))
    else:
        print('Secret Chats: skipped; both --telegram and --swiftgram are required.')
    if swiftgram and engine:
        results.append(attempt(ROOT, 'Swiftgram Pro (validation)',
                               lambda work: pro(work, swiftgram, engine), args.check))
    else:
        print('Swiftgram Pro: skipped; requires a Swiftgram IPA and --engine (no generator).')
    print(f'{sum(results)}/{len(results)} attempts succeeded. Changed code/ABI requires manual review.')
    return 0 if all(results) else 1


if __name__ == '__main__':
    sys.exit(main())
