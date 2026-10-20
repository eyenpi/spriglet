import copy
import io
import json
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import HTTPError
import zipfile

import deploy


def site_archive(replacements=None, extra=None, attributes=None, files=deploy.FILES):
    data = io.BytesIO()
    public = deploy.ROOT / 'tools/AppStore/website/public'
    with zipfile.ZipFile(data, 'w', zipfile.ZIP_DEFLATED) as archive:
        for name in sorted(files):
            value = (replacements or {}).get(name, (public / name).read_bytes())
            info = zipfile.ZipInfo(name)
            if name in (attributes or {}):
                info.external_attr = attributes[name] << 16
            archive.writestr(info, value)
        if extra:
            archive.writestr(*extra)
    return data.getvalue()


class ArtifactTests(unittest.TestCase):
    def unpack(self, data, preview=True):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            deploy.unpack_static(data, folder, preview)
            return {path.name: path.read_bytes() for path in folder.iterdir()}

    def test_shared_icon_and_text_are_preserved(self):
        files = self.unpack(site_archive())
        for name in ('spriglet.png', 'support.html', 'privacy.html'):
            self.assertEqual(files[name], (deploy.ROOT / 'tools/AppStore/website/public' / name).read_bytes())

    def test_pr_headers_and_redirects_cannot_replace_trusted_policy(self):
        files = self.unpack(site_archive({'_headers': b'/*\n Content-Security-Policy: *\n', '_redirects': b'/ https://example.invalid 302\n'}))
        self.assertIn(b"default-src 'none'", files['_headers'])
        self.assertIn(b'X-Robots-Tag: noindex', files['_headers'])
        self.assertEqual(files['_redirects'], (deploy.ROOT / 'tools/AppStore/website/public/_redirects').read_bytes())
        self.assertNotIn(b'https://example.invalid', files['_redirects'])
        self.assertIn(b"/*\n  X-Robots-Tag: noindex", files['_headers'])

    def test_production_does_not_get_preview_noindex(self):
        self.assertNotIn(b'X-Robots-Tag', self.unpack(site_archive(), preview=False)['_headers'])

    def test_legacy_rollback_keeps_known_redirect_and_trusted_headers(self):
        files = self.unpack(site_archive({'_redirects': b'/ https://evil.invalid 302\n'}, files=deploy.LEGACY_FILES), preview=False)
        self.assertEqual(set(files), deploy.LEGACY_FILES)
        self.assertEqual(files['_redirects'], b'/ /support 302\n')
        self.assertIn(b"default-src 'none'", files['_headers'])

    def test_incomplete_homepage_asset_set_is_rejected(self):
        with self.assertRaises(ValueError):
            self.unpack(site_archive(files=deploy.FILES - {'home.js'}))

    def test_traversal_absolute_paths_and_deployment_code_are_rejected(self):
        for name in ('../wrangler.json', '/tmp/site.html', 'wrangler.json', '_worker.js', 'build.sh', 'nested/index.html'):
            with self.subTest(name=name), self.assertRaises(ValueError):
                self.unpack(site_archive(extra=(name, b'untrusted')))

    def test_duplicate_entries_are_rejected(self):
        with self.assertWarns(UserWarning), self.assertRaises(ValueError):
            self.unpack(site_archive(extra=('index.html', b'duplicate')))

    def test_symbolic_links_and_special_files_are_rejected(self):
        for mode in (stat.S_IFLNK | 0o777, stat.S_IFIFO | 0o644):
            with self.subTest(mode=mode), self.assertRaises(ValueError):
                self.unpack(site_archive(attributes={'support.html': mode}))

    def test_expanded_size_limit_is_enforced(self):
        with self.assertRaises(ValueError):
            self.unpack(site_archive({'style.css': b'a' * (deploy.MAX_CONTENT + 1)}))

    def test_invalid_logo_and_text_are_rejected(self):
        for replacements in ({'spriglet.png': b'<script>oops</script>'}, {'support.html': b'\xff'},
                             {'instrument-serif.woff2': b'<script>oops</script>'}):
            with self.subTest(replacements=replacements), self.assertRaises(ValueError):
                self.unpack(site_archive(replacements))


class PreviewCleanupTests(unittest.TestCase):
    def setUp(self):
        self.workers = {f'meetspriglet-pr-{number}' for number in range(1, 21)}
        self.workers.add('meetspriglet-support')
        self.states = {number: 'closed' for number in range(1, 21)}
        self.states[99] = 'open'
        self.deleted = []
        self.statuses = []
        self.histories = {}
        self.github_requests = 0
        self.github_queries = 0
        self.resolve_sequence = None
        self.on_upload = None
        self.artifact_data = site_archive()
        self.resolved = {'deploy': True, 'pr': 99, 'target': 'pr-99', 'sha': 'a' * 40,
                         'artifact': 30, 'digest': 'sha256:' + 'b' * 64}

    def api(self, path, method='GET', data=None, **kwargs):
        if path == 'graphql':
            self.github_queries += 1
            number = int(data['variables']['environment'].split('-')[-1])
            return {'data': {'repository': {'deployments': {'nodes': [
                {'databaseId': entry['id'], 'latestStatus': {'state': entry['state'].upper()}}
                for entry in self.histories.get(number, [])[:100]
            ]}}}}
        if method == 'DELETE':
            name = path.rsplit('/', 1)[1]
            self.deleted.append(name)
            self.workers.remove(name)
            return {'success': True}
        if path.endswith('/workers/scripts'):
            return {'result': [{'id': name} for name in sorted(self.workers)]}
        if path.endswith('/workers/subdomain'):
            return {'result': {'subdomain': 'preview-test'}}
        raise AssertionError(path)

    def github(self, path, method='GET', data=None):
        self.github_requests += 1
        if self.github_requests > 1000:
            raise RuntimeError('Simulated GITHUB_TOKEN hourly quota exhausted')
        if path.startswith('pulls/'):
            return {'state': self.states[int(path.split('/')[1])]}
        if path.startswith('deployments?'):
            number = int(path.split('pr-')[1].split('&')[0])
            return [{'id': entry['id']} for entry in self.histories.get(number, [])[:100]]
        if path == 'deployments':
            return {'id': 900000}
        if path.endswith('/statuses'):
            self.statuses.append((path, data))
            identifier = int(path.split('/')[1])
            for history in self.histories.values():
                for entry in history:
                    if entry['id'] == identifier:
                        entry['state'] = data['state']
            return {}
        raise AssertionError(path)

    def run_deploy(self):
        with patch.object(deploy, 'account_id', return_value='a' * 32), \
                patch.object(deploy, 'api', side_effect=self.api), \
                patch.object(deploy, 'github', side_effect=self.github), \
                patch.object(deploy, 'resolve_run', return_value=self.resolved, side_effect=self.resolve_sequence), \
                patch.object(deploy, 'wait_production_checks'), \
                patch.object(deploy, 'download_artifact', return_value=self.artifact_data), \
                patch.object(deploy.subprocess, 'run') as run, patch.object(deploy, 'output') as output:
            self.upload = run
            run.return_value.returncode = 0
            run.side_effect = self.on_upload
            deploy.deploy(20, self.resolved['target'], False)
        return run, output

    def test_full_stale_inventory_no_longer_blocks_a_new_preview(self):
        run, output = self.run_deploy()
        self.assertEqual(set(self.deleted), {f'meetspriglet-pr-{n}' for n in range(1, 21)})
        self.assertEqual(self.workers, {'meetspriglet-support'})
        self.assertEqual(run.call_count, 2)
        self.assertEqual(self.statuses[-1][1]['state'], 'success')
        self.assertEqual(output.call_args.args[0]['target'], 'pr-99')

    def test_inactive_history_does_not_exhaust_publication_quota(self):
        self.histories = {number: [
            {'id': number * 100 + revision, 'state': 'success' if revision == 0 else 'inactive'}
            for revision in range(50)
        ] for number in range(1, 21)}
        run, output = self.run_deploy()
        self.assertEqual(output.call_args.args[0]['target'], 'pr-99')
        cleanup_writes = [path for path, data in self.statuses if data['state'] == 'inactive']
        self.assertEqual(len(cleanup_writes), 20)
        self.assertLessEqual(self.github_requests, 100)
        self.assertEqual(self.github_queries, 20)
        self.assertEqual(run.call_count, 2)

    def test_global_status_budget_still_frees_a_slot_for_publication(self):
        self.histories = {number: [{'id': number * 100 + revision, 'state': 'success'}
                                  for revision in range(50)] for number in range(1, 21)}
        run, output = self.run_deploy()
        cleanup_writes = [path for path, data in self.statuses if data['state'] == 'inactive']
        self.assertEqual(len(cleanup_writes), 50)
        self.assertEqual(len(self.deleted), 1)
        self.assertLessEqual(self.github_requests, 100)
        self.assertEqual(output.call_args.args[0]['target'], 'pr-99')
        self.assertEqual(run.call_count, 2)

    def test_closure_during_upload_shares_the_remaining_status_budget(self):
        self.histories = {number: [{'id': number * 100 + revision, 'state': 'success'}
                                  for revision in range(50)] for number in range(1, 21)}
        self.histories[99] = [{'id': 900000, 'state': 'in_progress'}]
        self.resolve_sequence = [self.resolved, self.resolved, {'deploy': False}]
        def upload(command, **kwargs):
            if command[0].endswith('wrangler'):
                self.workers.add('meetspriglet-pr-99')
                self.states[99] = 'closed'
            return deploy.subprocess.CompletedProcess(command, 0)
        self.on_upload = upload
        run, output = self.run_deploy()
        self.assertIn('meetspriglet-pr-99', self.workers)
        self.assertEqual(self.histories[99][0]['state'], 'inactive')
        self.assertFalse(output.call_args.args[0]['deploy'])
        self.assertEqual(run.call_count, 2)

    def test_failed_status_update_keeps_cleanup_discoverable(self):
        self.workers = {'meetspriglet-pr-1'}
        self.histories[1] = [{'id': 100, 'state': 'success'}]
        original = self.github
        def fail_status(path, method='GET', data=None):
            if method == 'POST':
                raise RuntimeError('Status service unavailable')
            return original(path, method, data)
        with patch.object(deploy, 'account_id', return_value='a' * 32), \
                patch.object(deploy, 'api', side_effect=self.api), \
                patch.object(deploy, 'github', side_effect=fail_status), self.assertRaises(RuntimeError):
            deploy.prune_previews()
        self.assertEqual(self.workers, {'meetspriglet-pr-1'})
        self.assertEqual(self.histories[1][0]['state'], 'success')
        with patch.object(deploy, 'account_id', return_value='a' * 32), \
                patch.object(deploy, 'api', side_effect=self.api), \
                patch.object(deploy, 'github', side_effect=self.github):
            result = deploy.prune_previews()
        self.assertEqual(result['cleaned'], ['meetspriglet-pr-1'])
        self.assertEqual(self.histories[1][0]['state'], 'inactive')

    def test_status_work_is_bounded_and_resumes_on_retry(self):
        self.workers = {'meetspriglet-pr-1'}
        self.histories[1] = [{'id': 1000 + revision, 'state': 'success'} for revision in range(100)]
        with patch.object(deploy, 'account_id', return_value='a' * 32), \
                patch.object(deploy, 'api', side_effect=self.api), \
                patch.object(deploy, 'github', side_effect=self.github):
            first = deploy.prune_previews()
            self.assertEqual(len(self.statuses), 50)
            self.assertEqual(first['deferred'], ['meetspriglet-pr-1'])
            self.assertEqual(self.workers, {'meetspriglet-pr-1'})
            second = deploy.prune_previews()
        self.assertEqual(second['cleaned'], ['meetspriglet-pr-1'])
        self.assertEqual(len(self.statuses), 100)
        self.assertEqual(self.workers, set())

    def test_worker_delete_failure_does_not_repeat_finished_status_updates(self):
        self.workers = {'meetspriglet-pr-1'}
        self.histories[1] = [{'id': 100, 'state': 'success'}]
        error = HTTPError('https://api.cloudflare.com', 503, '', {}, io.BytesIO(b'{"errors": []}'))
        self.addCleanup(error.close)
        def fail_deletion(path, method='GET', **kwargs):
            if method == 'DELETE':
                raise error
            return self.api(path, method, **kwargs)
        with patch.object(deploy, 'account_id', return_value='a' * 32), \
                patch.object(deploy, 'api', side_effect=fail_deletion), \
                patch.object(deploy, 'github', side_effect=self.github), self.assertRaises(ValueError):
            deploy.prune_previews()
        self.assertEqual(self.histories[1][0]['state'], 'inactive')
        with patch.object(deploy, 'account_id', return_value='a' * 32), \
                patch.object(deploy, 'api', side_effect=self.api), \
                patch.object(deploy, 'github', side_effect=self.github):
            result = deploy.prune_previews()
        self.assertEqual(result['cleaned'], ['meetspriglet-pr-1'])
        self.assertEqual(len(self.statuses), 1)

    def test_graphql_errors_stop_before_deletion(self):
        def query_failure(path, **kwargs):
            if path == 'graphql':
                return {'errors': [{'message': 'Deployment access denied'}], 'data': None}
            return self.api(path, **kwargs)
        with patch.object(deploy, 'account_id', return_value='a' * 32), \
                patch.object(deploy, 'api', side_effect=query_failure), \
                patch.object(deploy, 'github', side_effect=self.github), self.assertRaises(ValueError):
            deploy.prune_previews()
        self.assertEqual(self.deleted, [])

    def test_active_previews_still_enforce_the_limit(self):
        self.states = dict.fromkeys(self.states, 'open')
        with self.assertRaisesRegex(ValueError, 'Preview limit reached'):
            self.run_deploy()
        self.assertEqual(self.deleted, [])

    def test_invalid_artifact_does_not_delete_previews(self):
        self.artifact_data = site_archive(extra=('../untrusted', b'invalid'))
        with self.assertRaises(ValueError):
            self.run_deploy()
        self.assertEqual(self.deleted, [])
        self.upload.assert_not_called()

    def test_existing_preview_can_update_at_the_limit(self):
        self.states = dict.fromkeys(self.states, 'open')
        self.workers.remove('meetspriglet-pr-20')
        self.workers.add('meetspriglet-pr-99')
        run, output = self.run_deploy()
        self.assertEqual(self.deleted, [])
        self.assertEqual(run.call_count, 2)
        self.assertEqual(output.call_args.args[0]['target'], 'pr-99')

    def test_pruning_leaves_open_and_unrelated_workers(self):
        self.workers = {'meetspriglet-pr-1', 'meetspriglet-pr-2', 'meetspriglet-support',
                        'other-pr-3', 'meetspriglet-pr-0', 'meetspriglet-pr-01',
                        'meetspriglet-pr-1234567890123'}
        self.states[2] = 'open'
        with patch.object(deploy, 'account_id', return_value='a' * 32), \
                patch.object(deploy, 'api', side_effect=self.api), \
                patch.object(deploy, 'github', side_effect=self.github):
            result = deploy.prune_previews()
        self.assertEqual(self.deleted, ['meetspriglet-pr-1'])
        self.assertEqual(result['cleaned'], ['meetspriglet-pr-1'])
        self.assertEqual(result['retained'], ['meetspriglet-pr-2'])
        self.assertEqual(len(self.workers), 6)

    def test_dry_run_lists_candidates_without_mutations(self):
        with patch.object(deploy, 'account_id', return_value='a' * 32), \
                patch.object(deploy, 'api', side_effect=self.api), \
                patch.object(deploy, 'github', side_effect=self.github):
            result = deploy.prune_previews(dry_run=True)
        self.assertEqual(len(result['would_clean']), 20)
        self.assertEqual(result['cleaned'], [])
        self.assertEqual(self.deleted, [])
        self.assertEqual(self.statuses, [])

    def test_reopened_pr_is_rechecked_at_deletion(self):
        self.workers = {'meetspriglet-pr-1'}
        with patch.object(deploy, 'account_id', return_value='a' * 32), \
                patch.object(deploy, 'api', side_effect=self.api), \
                patch.object(deploy, 'github', side_effect=[{'state': 'closed'}, {'state': 'open'}]):
            result = deploy.prune_previews()
        self.assertEqual(self.deleted, [])
        self.assertEqual(result['retained'], ['meetspriglet-pr-1'])

    def test_unknown_pr_state_stops_cleanup(self):
        self.workers = {'meetspriglet-pr-1'}
        self.states[1] = 'unknown'
        with patch.object(deploy, 'account_id', return_value='a' * 32), \
                patch.object(deploy, 'api', side_effect=self.api), \
                patch.object(deploy, 'github', side_effect=self.github), self.assertRaises(ValueError):
            deploy.prune_previews()
        self.assertEqual(self.deleted, [])

    def test_lookup_failure_stops_before_deleting(self):
        error = HTTPError('https://api.github.com', 503, '', {}, io.BytesIO())
        self.addCleanup(error.close)
        with patch.object(deploy, 'account_id', return_value='a' * 32), \
                patch.object(deploy, 'api', side_effect=self.api), \
                patch.object(deploy, 'github', side_effect=error), \
                self.assertRaises(HTTPError):
            deploy.prune_previews()
        self.assertEqual(self.deleted, [])

    def test_deletion_failure_stops_deployment_before_upload(self):
        error = HTTPError('https://api.cloudflare.com', 403, '', {}, io.BytesIO(b'{"errors": []}'))
        self.addCleanup(error.close)
        original = self.api
        def fail_deletion(path, method='GET', **kwargs):
            if method == 'DELETE':
                raise error
            return original(path, method, **kwargs)
        with patch.object(self, 'api', side_effect=fail_deletion), \
                self.assertRaisesRegex(ValueError, 'deletion failed'):
            self.run_deploy()
        self.upload.assert_not_called()

    def test_missing_worker_cleanup_can_be_retried(self):
        error = HTTPError('https://api.cloudflare.com', 404, '', {},
                          io.BytesIO(b'{"errors": [{"code": 10007}]}'))
        self.addCleanup(error.close)
        def missing_worker(path, method='GET', **kwargs):
            if method == 'DELETE':
                raise error
            return self.api(path, method, **kwargs)
        with patch.object(deploy, 'account_id', return_value='a' * 32), \
                patch.object(deploy, 'api', side_effect=missing_worker), \
                patch.object(deploy, 'github', side_effect=self.github):
            result = deploy.clean_preview(1)
        self.assertTrue(result['cleaned'])

    def test_production_never_prunes(self):
        self.resolved.update(pr=0, target='production')
        with patch.object(deploy, 'prune_previews') as prune:
            run, output = self.run_deploy()
        prune.assert_not_called()
        self.assertEqual(self.deleted, [])
        self.assertEqual(run.call_count, 2)
        self.assertEqual(output.call_args.args[0]['target'], 'production')


class ProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.run = {'id': 20, 'workflow_id': 10, 'path': deploy.WORKFLOW,
                    'repository': {'full_name': deploy.REPOSITORY},
                    'head_repository': {'id': 100, 'full_name': 'contributor/spriglet'},
                    'status': 'completed', 'conclusion': 'success', 'event': 'pull_request',
                    'head_sha': 'a' * 40, 'head_branch': 'feature'}
        self.pr = {'number': 7, 'state': 'open', 'draft': False, 'head': {'sha': 'a' * 40, 'repo': {'id': 100}},
                   'base': {'ref': 'main', 'repo': {'full_name': deploy.REPOSITORY}}}
        self.artifact = {'id': 30, 'name': deploy.ARTIFACT, 'expired': False,
                         'size_in_bytes': 1000, 'digest': 'sha256:' + 'b' * 64}

    def fake_github(self, path, **kwargs):
        return {'actions/runs/20': self.run,
                'actions/workflows/validate.yml': {'id': 10},
                'actions/workflows/pr-ci.yml': {'id': 10},
                'commits/' + 'a' * 40 + '/pulls?per_page=100': [self.pr],
                'actions/runs/20/artifacts?per_page=100': {'artifacts': [self.artifact]},
                'branches/main': {'commit': {'sha': 'a' * 40}}}[path]

    def test_fork_pr_can_publish_only_to_its_own_preview(self):
        with patch.object(deploy, 'github', side_effect=self.fake_github):
            result = deploy.resolve_run(20)
        self.assertEqual(result['target'], 'pr-7')
        self.assertEqual(result['environment'], 'website-preview')
        self.assertEqual(result['artifact'], 30)

    def test_wrong_workflow_repo_or_failed_run_are_rejected(self):
        for key, value in [('path', '.github/workflows/evil.yml'), ('workflow_id', 99),
                           ('repository', {'full_name': 'attacker/spriglet'}), ('conclusion', 'failure'),
                           ('status', 'in_progress'), ('head_sha', '../invalid')]:
            run = copy.deepcopy(self.run); run[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                deploy.validate_run(run, 10)

    def test_closed_or_updated_pr_skips_without_deploying(self):
        with patch.object(deploy, 'github', side_effect=self.fake_github):
            self.pr['draft'] = True
            self.assertFalse(deploy.resolve_run(20)['deploy'])
            self.pr['draft'] = False
            self.pr['state'] = 'closed'
            self.assertFalse(deploy.resolve_run(20)['deploy'])
            self.pr['state'] = 'open'; self.pr['head']['sha'] = 'c' * 40
            self.assertFalse(deploy.resolve_run(20)['deploy'])

    def test_wrong_fork_and_base_are_not_accepted(self):
        self.pr['head']['repo']['id'] = 999
        self.assertFalse(deploy.check_pr(self.pr, self.run))
        self.pr['head']['repo']['id'] = 100
        self.pr['base']['ref'] = 'other'
        self.assertFalse(deploy.check_pr(self.pr, self.run))

    def test_pr_cannot_be_promoted_via_rollback(self):
        with patch.object(deploy, 'github', side_effect=self.fake_github), self.assertRaises(ValueError):
            deploy.resolve_run(20, rollback=True)

    def test_feature_push_does_not_publish_production(self):
        self.run.update(event='push', path=deploy.LEGACY_WORKFLOW)
        with patch.object(deploy, 'github', side_effect=self.fake_github):
            self.assertFalse(deploy.resolve_run(20)['deploy'])

    def test_main_requires_current_commit_but_rollback_accepts_a_prior_main_run(self):
        self.run.update(event='push', path=deploy.LEGACY_WORKFLOW, head_branch='main', head_repository={'id': 1, 'full_name': deploy.REPOSITORY})
        def newer_main(path, **kwargs):
            if path == 'branches/main':
                return {'commit': {'sha': 'c' * 40}}
            return self.fake_github(path, **kwargs)
        with patch.object(deploy, 'github', side_effect=newer_main):
            self.assertFalse(deploy.resolve_run(20)['deploy'])
            restored = deploy.resolve_run(20, rollback=True)
        self.assertEqual(restored['target'], 'production')
        self.assertEqual(restored['environment'], 'website-production')

    def test_fork_push_named_main_cannot_become_production(self):
        self.run.update(event='push', path=deploy.LEGACY_WORKFLOW, head_branch='main')
        with patch.object(deploy, 'github', side_effect=self.fake_github), self.assertRaises(ValueError):
            deploy.resolve_run(20, rollback=True)

    def test_failed_required_production_check_blocks_upload(self):
        check = {'id': 1, 'app': {'id': 15368}, 'name': 'security-checks', 'status': 'completed', 'conclusion': 'failure'}
        with patch.object(deploy, 'github', return_value={'check_runs': [check]}), patch.object(deploy.time, 'sleep') as sleep, self.assertRaises(ValueError):
            deploy.wait_production_checks('a' * 40)
        sleep.assert_not_called()

    def test_automatic_deploy_rejects_pushes_and_non_ci_events(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'event.json'
            for name, run in (
                    ('pull_request_target', {}), ('workflow_dispatch', {}),
                    ('workflow_run', {'event': 'push', 'conclusion': 'success'}),
                    ('workflow_run', {'event': 'pull_request', 'conclusion': 'cancelled'})):
                path.write_text(json.dumps({'repository': {'full_name': deploy.REPOSITORY}, 'workflow_run': run}))
                with self.subTest(name=name, run=run), patch.dict(deploy.os.environ, {
                        'GITHUB_EVENT_PATH': str(path), 'GITHUB_EVENT_NAME': name}), \
                        patch.object(deploy, 'resolve_run') as resolve, patch.object(deploy, 'output'):
                    if name == 'workflow_run':
                        deploy.resolve()
                    else:
                        with self.assertRaises(ValueError):
                            deploy.resolve()
                    resolve.assert_not_called()

    def test_missing_digest_expired_and_oversize_artifacts_fail_closed(self):
        for changes in ({'digest': ''}, {'expired': True}, {'size_in_bytes': deploy.MAX_ARCHIVE + 1}):
            previous = self.artifact.copy(); self.artifact.update(changes)
            with self.subTest(changes=changes), patch.object(deploy, 'github', side_effect=self.fake_github), self.assertRaises(ValueError):
                deploy.resolve_run(20)
            self.artifact = previous

    def test_reopened_pr_is_not_deleted(self):
        with patch.object(deploy, 'github', return_value={'state': 'open'}), patch.object(deploy, 'api') as cloudflare:
            deploy.clean_preview(7)
        cloudflare.assert_not_called()

    def test_invalid_names_and_identifiers_cannot_target_other_workers(self):
        for value in ('production; echo test', 'pr-0', 'pr-../production', 'other-worker'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                deploy.worker_name(value)
        for value in ('0', '-1', '7\nOTHER=1', '1; pwd', None):
            with self.subTest(value=value), self.assertRaises(ValueError):
                deploy.positive_number(value)


if __name__ == '__main__':
    unittest.main()
