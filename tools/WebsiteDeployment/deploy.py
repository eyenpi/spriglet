#!/usr/bin/env python3
"""Trusted static-site deployment. Never run source or configuration from a PR artifact."""

import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import tempfile
import time
from urllib.error import HTTPError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener, urlopen
import zipfile

ROOT = Path(__file__).resolve().parents[2]
REPOSITORY = 'eyenpi/spriglet'
WORKFLOW = '.github/workflows/pr-ci.yml'
LEGACY_WORKFLOW = '.github/workflows/validate.yml'
ARTIFACT = 'website-static'
FILES = frozenset(('index.html', 'support.html', 'privacy.html', '404.html', 'style.css', 'spriglet.png', '_headers', '_redirects'))
MAX_ARCHIVE = 8 * 1024 * 1024
MAX_CONTENT = 4 * 1024 * 1024
REQUIRED_CHECKS = frozenset(('macos', 'security-checks', 'codeql-actions', 'codeql-python', 'codeql-swift'))


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def api(path, method='GET', data=None, cloudflare=False):
    base = 'https://api.cloudflare.com/client/v4/' if cloudflare else 'https://api.github.com/'
    key = 'CLOUDFLARE_API_TOKEN' if cloudflare else 'GH_TOKEN'
    request = Request(base + path, method=method, headers={
        'Authorization': 'Bearer ' + os.environ[key],
        'Accept': 'application/json', 'Content-Type': 'application/json',
        'User-Agent': 'SprigletWebsiteDeployment/1.0',
    }, data=None if data is None else json.dumps(data).encode())
    # Never forward a credential to a redirect destination.
    with build_opener(NoRedirect()).open(request, timeout=30) as response:
        body = response.read()
    result = json.loads(body) if body else {}
    if cloudflare and result.get('success') is not True:
        raise ValueError('Cloudflare API did not confirm success')
    return result


def github(path, **kwargs):
    return api('repos/' + REPOSITORY + '/' + path, **kwargs)


def positive_number(value):
    if not re.fullmatch(r'[1-9][0-9]{0,11}', str(value)):
        raise ValueError('Expected a positive numeric GitHub identifier')
    return int(value)


def output(values):
    path = os.environ.get('GITHUB_OUTPUT')
    if path:
        with open(path, 'a') as stream:
            for key, value in values.items():
                text = str(value).lower() if isinstance(value, bool) else str(value)
                if '\n' in text or '\r' in text:
                    raise ValueError('Invalid workflow output')
                stream.write(key + '=' + text + '\n')
    print(json.dumps(values, sort_keys=True))


def validate_run(run, workflow_id):
    if (run.get('repository', {}).get('full_name') != REPOSITORY
            or run.get('workflow_id') != workflow_id
            or run.get('path') != (LEGACY_WORKFLOW if run.get('event') == 'push' else WORKFLOW)
            or run.get('status') != 'completed'
            or run.get('conclusion') != 'success'
            or run.get('event') not in ('pull_request', 'push')
            or not re.fullmatch('[0-9a-f]{40}', run.get('head_sha', ''))):
        raise ValueError('Run does not belong to the successful approved build workflow')


def check_pr(pr, run):
    return (pr.get('state') == 'open'
            and pr.get('draft') is False
            and pr.get('base', {}).get('repo', {}).get('full_name') == REPOSITORY
            and pr.get('base', {}).get('ref') == 'main'
            and pr.get('head', {}).get('sha') == run['head_sha']
            and pr.get('head', {}).get('repo', {}).get('id') == run.get('head_repository', {}).get('id'))


def select_artifact(run_id):
    artifacts = github(f'actions/runs/{run_id}/artifacts?per_page=100')['artifacts']
    candidates = [a for a in artifacts if a['name'] == ARTIFACT and not a['expired']]
    if len(candidates) != 1:
        raise ValueError('Expected exactly one unexpired website artifact from this run')
    artifact = candidates[0]
    if artifact['size_in_bytes'] > MAX_ARCHIVE:
        raise ValueError('Website archive exceeds the size limit')
    if not re.fullmatch(r'sha256:[0-9a-f]{64}', artifact.get('digest', '')):
        raise ValueError('GitHub did not provide an artifact SHA-256 digest')
    return artifact


def resolve_run(run_id, rollback=False):
    run_id = positive_number(run_id)
    run = github(f'actions/runs/{run_id}')
    workflow = LEGACY_WORKFLOW if run.get('event') == 'push' else WORKFLOW
    workflow_id = github('actions/workflows/' + Path(workflow).name)['id']
    validate_run(run, workflow_id)
    if run['event'] == 'push':
        if run['head_branch'] != 'main' or run['head_repository']['full_name'] != REPOSITORY:
            if rollback:
                raise ValueError('Production requires a build pushed to this repository main branch')
            return {'deploy': False, 'reason': 'Only main pushes publish production'}
        if not rollback and github('branches/main')['commit']['sha'] != run['head_sha']:
            return {'deploy': False, 'reason': 'A newer main commit superseded this run'}
        target = 'production'
        environment = 'website-production'
        pr_number = 0
    else:
        if rollback:
            raise ValueError('A PR build cannot be used for production rollback')
        prs = github('commits/' + run['head_sha'] + '/pulls?per_page=100')
        matches = [pr for pr in prs if check_pr(pr, run)]
        if len(matches) != 1:
            return {'deploy': False, 'reason': 'PR closed, changed, or not uniquely associated with this run'}
        pr_number = positive_number(matches[0]['number'])
        target = 'pr-' + str(pr_number)
        environment = 'website-preview'
    artifact = select_artifact(run_id)
    return {'deploy': True, 'action': 'deploy', 'target': target, 'environment': environment,
            'pr': pr_number, 'sha': run['head_sha'], 'run': run_id, 'artifact': artifact['id'],
            'digest': artifact['digest'], 'rollback': rollback}


def resolve():
    event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
    name = os.environ['GITHUB_EVENT_NAME']
    if event.get('repository', {}).get('full_name') != REPOSITORY:
        raise ValueError('Unexpected repository')
    if name != 'workflow_run':
        raise ValueError('Automatic deployment only follows approved PR validation')
    run = event.get('workflow_run', {})
    if run.get('conclusion') != 'success' or run.get('event') != 'pull_request':
        return output({'deploy': False, 'reason': 'Only successful approved PR runs deploy automatically'})
    output(resolve_run(run['id']))


def download_artifact(artifact_id, digest):
    path = f'repos/{REPOSITORY}/actions/artifacts/{positive_number(artifact_id)}/zip'
    request = Request('https://api.github.com/' + path, headers={
        'Authorization': 'Bearer ' + os.environ['GH_TOKEN'], 'User-Agent': 'SprigletWebsiteDeployment/1.0'})
    try:
        response = build_opener(NoRedirect()).open(request, timeout=30)
    except HTTPError as error:
        if error.code != 302:
            raise
        location = error.headers['Location']
        parsed = urlsplit(location)
        if parsed.scheme != 'https' or parsed.username or parsed.password:
            raise ValueError('Unsafe artifact download redirect')
        # Signed GitHub artifact URL; no GitHub or Cloudflare authorization header is forwarded.
        response = urlopen(Request(location, headers={'User-Agent': 'SprigletWebsiteDeployment/1.0'}), timeout=60)
    with response:
        data = response.read(MAX_ARCHIVE + 1)
    if len(data) > MAX_ARCHIVE or 'sha256:' + hashlib.sha256(data).hexdigest() != digest:
        raise ValueError('Artifact size or SHA-256 digest mismatch')
    return data


def unpack_static(data, destination, preview):
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        entries = archive.infolist()
        names = [entry.filename for entry in entries]
        if len(names) != len(FILES) or set(names) != FILES:
            raise ValueError('Artifact must contain exactly the expected flat static website files')
        if sum(entry.file_size for entry in entries) > MAX_CONTENT:
            raise ValueError('Expanded website exceeds the size limit')
        for entry in entries:
            mode = entry.external_attr >> 16
            if entry.is_dir() or (stat.S_IFMT(mode) not in (0, stat.S_IFREG)) or entry.flag_bits & 1:
                raise ValueError('Artifact contains a link, special file, or encrypted content')
            content = archive.read(entry)
            if entry.filename == 'spriglet.png':
                if not content.startswith(b'\x89PNG\r\n\x1a\n'):
                    raise ValueError('Website logo must be a PNG')
            else:
                content.decode('utf-8')
            if entry.filename not in ('_headers', '_redirects'):
                (destination / entry.filename).write_bytes(content)
    # Server policy comes only from protected main, never from a PR-controlled artifact.
    public = ROOT / 'tools/AppStore/website/public'
    headers = (public / '_headers').read_text()
    if preview:
        headers += '  X-Robots-Tag: noindex, nofollow, noarchive\n'
    (destination / '_headers').write_text(headers)
    (destination / '_redirects').write_bytes((public / '_redirects').read_bytes())


def wait_production_checks(sha):
    # Swift extraction can outlast the app validation that triggers this workflow.
    for _ in range(100):
        checks = github(f'commits/{sha}/check-runs?per_page=100')['check_runs']
        latest = {}
        for check in sorted(checks, key=lambda c: c['id']):
            if check.get('app', {}).get('id') == 15368:
                latest[check['name']] = check
        relevant = [latest.get(name) for name in REQUIRED_CHECKS]
        if all(check and check['conclusion'] == 'success' for check in relevant):
            return
        if any(check and check['status'] == 'completed' and check['conclusion'] != 'success' for check in relevant):
            raise ValueError('A required production check failed')
        time.sleep(15)
    raise ValueError('Required production checks did not finish successfully within twenty-five minutes')


def worker_name(target):
    if target == 'production':
        return 'meetspriglet-support'
    if not re.fullmatch(r'pr-[1-9][0-9]{0,11}', target):
        raise ValueError('Invalid preview target')
    return 'meetspriglet-' + target


def account_id():
    value = os.environ['CLOUDFLARE_ACCOUNT_ID']
    if not re.fullmatch('[0-9a-f]{32}', value):
        raise ValueError('Invalid Cloudflare account ID')
    return value


def clean_preview(pr_number):
    pr_number = positive_number(pr_number)
    # A reopened PR must not be deleted by a delayed close event.
    if github(f'pulls/{pr_number}')['state'] != 'closed':
        return output({'cleaned': False, 'reason': 'PR is open again'})
    name = worker_name('pr-' + str(pr_number))
    try:
        api(f'accounts/{account_id()}/workers/scripts/{name}', method='DELETE', cloudflare=True)
    except HTTPError as error:
        details = json.loads(error.read())
        if error.code != 404 or not any(item.get('code') == 10007 for item in details.get('errors', [])):
            raise ValueError('Cloudflare preview deletion failed') from None
    deployments = github(f'deployments?environment=preview%2Fpr-{pr_number}&per_page=100')
    for deployment in deployments:
        github(f"deployments/{deployment['id']}/statuses", method='POST', data={'state': 'inactive', 'auto_inactive': False})
    output({'cleaned': True, 'target': name})


def deploy(run_id, expected_target, rollback):
    resolved = resolve_run(run_id, rollback)
    if not resolved['deploy']:
        return output(resolved)
    if resolved['target'] != expected_target:
        raise ValueError('Deployment target changed after resolving the run')
    preview = resolved['pr'] != 0
    if not preview:
        wait_production_checks(resolved['sha'])
    name = worker_name(expected_target)
    account = account_id()
    if preview:
        workers = api(f'accounts/{account}/workers/scripts', cloudflare=True)['result']
        previews = [worker for worker in workers if re.fullmatch(r'meetspriglet-pr-[0-9]+', worker['id'])]
        if len(previews) >= 20 and not any(worker['id'] == name for worker in previews):
            raise ValueError('Preview limit reached (20). Run the documented cleanup command for closed PRs before deploying another preview')
    with tempfile.TemporaryDirectory(prefix='spriglet-website-') as directory:
        work = Path(directory)
        public = work / 'public'; public.mkdir()
        unpack_static(download_artifact(resolved['artifact'], resolved['digest']), public, preview)
        config = {'name': name, 'account_id': account, 'compatibility_date': '2026-09-15',
                  'send_metrics': False, 'workers_dev': preview, 'preview_urls': False,
                  'assets': {'directory': str(public), 'html_handling': 'auto-trailing-slash', 'not_found_handling': '404-page'},
                  'observability': {'enabled': False}}
        if preview:
            subdomain = api(f'accounts/{account}/workers/subdomain', cloudflare=True)['result']['subdomain']
            if not re.fullmatch('[a-z0-9-]+', subdomain):
                raise ValueError('Invalid workers.dev subdomain')
            origin = f'https://{name}.{subdomain}.workers.dev'
        else:
            brand = json.loads((ROOT / 'Configuration/Shared/brand.json').read_text())
            origin = brand['websiteURL'].rstrip('/')
            parsed = urlsplit(origin)
            if parsed.scheme != 'https' or not parsed.hostname or parsed.path or parsed.username or parsed.port:
                raise ValueError('Production origin must be a plain HTTPS origin')
            config['routes'] = [{'pattern': parsed.hostname, 'custom_domain': True}]
        configuration = work / 'wrangler.json'
        configuration.write_text(json.dumps(config))
        # Recheck after downloading and validation, just before touching Cloudflare.
        current = resolve_run(run_id, rollback)
        if not current['deploy'] or current['sha'] != resolved['sha']:
            return output({'deploy': False, 'reason': 'Build was superseded before upload'})
        record = github('deployments', method='POST', data={
            'ref': resolved['sha'], 'auto_merge': False, 'required_contexts': [],
            'environment': 'preview/' + expected_target if preview else 'production',
            'transient_environment': preview, 'production_environment': not preview,
            'description': 'Generated Spriglet website'})
        status_path = f"deployments/{record['id']}/statuses"
        github(status_path, method='POST', data={'state': 'in_progress', 'auto_inactive': False})
        try:
            wrangler = ROOT / 'tools/WebsiteDeployment/node_modules/.bin/wrangler'
            subprocess.run([str(wrangler), 'deploy', '--config', str(configuration), '--no-bundle'], cwd=work, check=True)
            for attempt in range(8):
                checked = subprocess.run(['python3', str(ROOT / 'tools/AppStore/website/check_http.py'), origin, '--public', str(public)], cwd=work)
                if checked.returncode == 0:
                    break
                if attempt == 7:
                    raise ValueError('Deployed website did not pass public HTTP checks')
                time.sleep(15)
            current = resolve_run(run_id, rollback)
            if not current['deploy']:
                if preview and github(f"pulls/{resolved['pr']}")['state'] == 'closed':
                    clean_preview(resolved['pr'])
                github(status_path, method='POST', data={'state': 'inactive', 'auto_inactive': False})
                return output({'deploy': False, 'reason': 'A newer change superseded this deployment'})
            github(status_path, method='POST', data={'state': 'success', 'environment_url': origin, 'auto_inactive': True})
        except Exception:
            github(status_path, method='POST', data={'state': 'failure', 'auto_inactive': False})
            raise
        output({'url': origin, 'sha': resolved['sha'], 'target': expected_target})
        if os.environ.get('GITHUB_STEP_SUMMARY'):
            with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as stream:
                stream.write(f'Website: [{origin}]({origin})\n\nCommit: `{resolved["sha"]}`\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('resolve', 'deploy', 'cleanup'))
    parser.add_argument('--run', type=positive_number)
    parser.add_argument('--target')
    parser.add_argument('--pr', type=positive_number)
    parser.add_argument('--rollback', action='store_true')
    args = parser.parse_args()
    if args.action == 'resolve':
        resolve()
    elif args.action == 'cleanup':
        clean_preview(args.pr)
    else:
        deploy(args.run, args.target, args.rollback)


if __name__ == '__main__':
    main()
