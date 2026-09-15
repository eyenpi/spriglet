import copy
import io
import json
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import deploy


def site_archive(replacements=None, extra=None, attributes=None):
    data = io.BytesIO()
    public = deploy.ROOT / 'tools/AppStore/website/public'
    with zipfile.ZipFile(data, 'w', zipfile.ZIP_DEFLATED) as archive:
        for name in sorted(deploy.FILES):
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
        self.assertEqual(files['_redirects'], b'/ /support 302\n')

    def test_production_does_not_get_preview_noindex(self):
        self.assertNotIn(b'X-Robots-Tag', self.unpack(site_archive(), preview=False)['_headers'])

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
        for replacements in ({'spriglet.png': b'<script>oops</script>'}, {'support.html': b'\xff'}):
            with self.subTest(replacements=replacements), self.assertRaises(ValueError):
                self.unpack(site_archive(replacements))


class ProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.run = {'id': 20, 'workflow_id': 10, 'path': deploy.WORKFLOW,
                    'repository': {'full_name': deploy.REPOSITORY},
                    'head_repository': {'id': 100, 'full_name': 'contributor/spriglet'},
                    'status': 'completed', 'conclusion': 'success', 'event': 'pull_request',
                    'head_sha': 'a' * 40, 'head_branch': 'feature'}
        self.pr = {'number': 7, 'state': 'open', 'head': {'sha': 'a' * 40, 'repo': {'id': 100}},
                   'base': {'ref': 'main', 'repo': {'full_name': deploy.REPOSITORY}}}
        self.artifact = {'id': 30, 'name': deploy.ARTIFACT, 'expired': False,
                         'size_in_bytes': 1000, 'digest': 'sha256:' + 'b' * 64}

    def fake_github(self, path, **kwargs):
        return {'actions/runs/20': self.run,
                'actions/workflows/validate.yml': {'id': 10},
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
        self.run['event'] = 'push'
        with patch.object(deploy, 'github', side_effect=self.fake_github):
            self.assertFalse(deploy.resolve_run(20)['deploy'])

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
