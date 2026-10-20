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
            response = io.BytesIO(b'{"success": true}')
            response.headers = {}
            return response
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


class GraphQLRateLimitTests(unittest.TestCase):
    def request(self, responses):
        calls = []
        def open_request(request, **kwargs):
            calls.append(request)
            status, body, headers = responses[min(len(calls) - 1, len(responses) - 1)]
            if status != 200:
                error = HTTPError(request.full_url, status, '', headers, io.BytesIO(json.dumps(body).encode()))
                self.addCleanup(error.close)
                raise error
            response = io.BytesIO(json.dumps(body).encode())
            response.headers = headers
            return response
        with patch.dict(deploy.os.environ, {'GH_TOKEN': 'test-token'}), \
                patch.object(deploy, 'build_opener') as opener, \
                patch.object(deploy.time, 'time', return_value=1000), \
                patch.object(deploy.time, 'sleep') as sleep, contextlib.redirect_stdout(io.StringIO()):
            self.calls = calls
            self.sleep = sleep
            opener.return_value.open.side_effect = open_request
            return deploy.github_graphql('query { repository { name } }', {})

    def test_http_200_rate_limited_type_honors_reset_headers(self):
        result = self.request([
            (200, {'errors': [{'type': 'RATE_LIMITED', 'message': 'API rate limit exceeded'}]},
             {'X-RateLimit-Remaining': '0', 'X-RateLimit-Reset': '1010'}),
            (200, {'data': {'repository': {'name': 'spriglet'}}}, {}),
        ])
        self.assertEqual(result, {'name': 'spriglet'})
        self.assertEqual(len(self.calls), 2)
        self.sleep.assert_called_once_with(11)

    def test_secondary_throttle_honors_retry_after(self):
        self.request([
            (200, {'errors': [{'message': 'You have exceeded a secondary rate limit'}]}, {'Retry-After': '12'}),
            (200, {'data': {'repository': {}}}, {}),
        ])
        self.sleep.assert_called_once_with(12)

    def test_extension_code_without_headers_uses_bounded_backoff(self):
        throttle = (200, {'errors': [{'extensions': {'code': 'RATE_LIMITED'}}]}, {})
        self.request([throttle, throttle, (200, {'data': {'repository': {}}}, {})])
        self.assertEqual([call.args[0] for call in self.sleep.call_args_list], [60, 120])

    def test_mixed_http_and_graphql_throttles_share_one_retry_budget(self):
        with self.assertRaisesRegex(ValueError, 'rate limit'):
            self.request([
                (200, {'errors': [{'type': 'RATE_LIMITED'}]}, {'Retry-After': '1'}),
                (429, {'message': 'secondary rate limit'}, {'Retry-After': '1'}),
                (200, {'errors': [{'type': 'RATE_LIMITED'}]}, {'Retry-After': '1'}),
            ])
        self.assertEqual(len(self.calls), 3)
        self.assertEqual(self.sleep.call_count, 2)

    def test_long_graphql_reset_fails_without_retrying_early(self):
        with self.assertRaisesRegex(ValueError, 'rate limit'):
            self.request([(200, {'errors': [{'type': 'RATE_LIMITED'}]},
                           {'X-RateLimit-Remaining': '0', 'X-RateLimit-Reset': '4600'})])
        self.sleep.assert_not_called()
        self.assertEqual(len(self.calls), 1)

    def test_non_throttle_and_mixed_errors_fail_without_waiting(self):
        for errors in ([{'type': 'FORBIDDEN', 'message': 'Permission denied'}],
                       [{'message': 'Could not resolve to a Repository'}],
                       [{'type': 'RATE_LIMITED'}, {'type': 'FORBIDDEN'}],
                       [{'type': 'GRAPHQL_VALIDATION_FAILED', 'message': 'Unknown field: rate limit'}]):
            with self.subTest(errors=errors), self.assertRaisesRegex(ValueError, 'query failed'):
                self.request([(200, {'errors': errors}, {'Retry-After': '1'})])
            self.sleep.assert_not_called()
            self.assertEqual(len(self.calls), 1)
