import copy
import unittest

from verify_pr import REPOSITORY, verify


class ApprovalGuardTests(unittest.TestCase):
    def setUp(self):
        self.pr = {'number': 6, 'state': 'open', 'draft': False,
                   'head': {'sha': 'a' * 40, 'repo': {'id': 123}},
                   'base': {'sha': 'b' * 40, 'ref': 'main',
                            'repo': {'id': 456, 'full_name': REPOSITORY}}}
        self.event = {'repository': {'full_name': REPOSITORY}, 'pull_request': copy.deepcopy(self.pr)}

    def test_same_head_and_base_may_run(self):
        verify('pull_request', self.event, self.pr)

    def test_new_commits_require_new_approval(self):
        for side in ('head', 'base'):
            with self.subTest(side=side):
                current = copy.deepcopy(self.pr)
                current[side]['sha'] = 'c' * 40
                with self.assertRaises(ValueError):
                    verify('pull_request', self.event, current)

    def test_closed_draft_and_different_pr_are_rejected(self):
        for key, value in (('state', 'closed'), ('draft', True), ('number', 7)):
            with self.subTest(key=key), self.assertRaises(ValueError):
                verify('pull_request', self.event, {**self.pr, key: value})

    def test_non_pr_events_are_rejected(self):
        for name in ('push', 'workflow_dispatch', 'pull_request_target', 'schedule'):
            with self.subTest(name=name), self.assertRaises(ValueError):
                verify(name, self.event, self.pr)

    def test_retarget_and_repository_substitution_are_rejected(self):
        for side, key, value in (('base', 'ref', 'release'),
                                 ('base', 'repo', {'id': 789, 'full_name': 'someone/else'}),
                                 ('head', 'repo', {'id': 789})):
            with self.subTest(side=side, key=key):
                current = copy.deepcopy(self.pr)
                current[side][key] = value
                with self.assertRaises(ValueError):
                    verify('pull_request', self.event, current)

    def test_missing_identity_is_rejected(self):
        for side in ('head', 'base'):
            with self.subTest(side=side):
                event = copy.deepcopy(self.event)
                del event['pull_request'][side]['sha']
                with self.assertRaises(ValueError):
                    verify('pull_request', event, self.pr)


if __name__ == '__main__':
    unittest.main()
