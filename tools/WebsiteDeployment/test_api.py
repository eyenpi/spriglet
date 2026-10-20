import contextlib
import io
import json
import unittest
from unittest.mock import patch
from urllib.error import HTTPError

import deploy


class RateLimitTests(unittest.TestCase):
    def request(self, status, headers=None, message='secondary rate limit', failures=1, cloudflare=False):
        calls = []
        def open_request(request, **kwargs):
            calls.append(request)
            if len(calls) <= failures:
                error = HTTPError(request.full_url, status, '', headers or {},
                                  io.BytesIO(json.dumps({'message': message}).encode()))
                self.addCleanup(error.close)
                raise error
            return io.BytesIO(b'{"success": true}')
        with patch.dict(deploy.os.environ, {'GH_TOKEN': 'test-token', 'CLOUDFLARE_API_TOKEN': 'test-token'}), \
                patch.object(deploy, 'build_opener') as opener, \
                patch.object(deploy.time, 'time', return_value=1000), \
                patch.object(deploy.time, 'sleep') as sleep, contextlib.redirect_stdout(io.StringIO()):
            self.sleep = sleep
            self.calls = calls
            opener.return_value.open.side_effect = open_request
            return deploy.api('example', method='POST', data={'state': 'inactive'}, cloudflare=cloudflare)

    def test_secondary_limit_without_headers_waits_and_retries(self):
        self.assertTrue(self.request(403)['success'])
        self.assertEqual(self.sleep.call_args_list[0].args, (60,))
        self.assertEqual(len(self.calls), 2)
        self.assertEqual(self.calls[0].data, self.calls[1].data)

    def test_429_honors_retry_after(self):
        self.assertTrue(self.request(429, {'Retry-After': '12'})['success'])
        self.sleep.assert_called_once_with(12)

    def test_primary_limit_honors_reset_even_with_shorter_retry_after(self):
        self.assertTrue(self.request(403, {'X-RateLimit-Remaining': '0', 'X-RateLimit-Reset': '1010',
                                         'Retry-After': '2'}, message='API rate limit exceeded')['success'])
        self.sleep.assert_called_once_with(11)

    def test_repeated_secondary_limit_backs_off(self):
        self.assertTrue(self.request(403, failures=2)['success'])
        self.assertEqual([call.args[0] for call in self.sleep.call_args_list], [60, 120])

    def test_permanent_limit_fails_after_bounded_retries(self):
        with self.assertRaisesRegex(ValueError, 'rate limit'):
            self.request(429, failures=10)
        self.assertEqual(len(self.calls), 3)

    def test_long_reset_fails_without_retrying_early(self):
        with self.assertRaisesRegex(ValueError, 'rate limit'):
            self.request(403, {'X-RateLimit-Remaining': '0', 'X-RateLimit-Reset': '4600'})
        self.sleep.assert_not_called()
        self.assertEqual(len(self.calls), 1)

    def test_permission_errors_and_cloudflare_errors_are_not_retried(self):
        for cloudflare, message in ((False, 'Resource not accessible by integration'), (True, 'rate limit')):
            with self.subTest(cloudflare=cloudflare), self.assertRaises(HTTPError):
                self.request(403, message=message, cloudflare=cloudflare)
            self.sleep.assert_not_called()
            self.assertEqual(len(self.calls), 1)
