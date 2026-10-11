import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location('public_files', Path(__file__).resolve().parents[2] / 'scripts/check-public-files.py')
guard = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(guard)


class CredentialGuardTests(unittest.TestCase):
    def test_credential_files_rejected_inside_public_directories(self):
        for name in ('auth.p8', 'server.key', 'signing.p12', 'key.pem', '.env', '.env.production', '.dev.vars', '.dev.vars.preview'):
            with self.subTest(name=name):
                self.assertFalse(guard.public_path('tools/example/' + name))

    def test_private_key_variants_detected_without_real_keys(self):
        for variant in ('', 'RSA ', 'EC ', 'OPENSSH ', 'ENCRYPTED ', 'DSA '):
            synthetic = ('-----BEGIN ' + variant + 'PRIVATE KEY-----').encode()
            self.assertIsNotNone(guard.KEY_HEADER.search(synthetic))

    def test_public_security_docs_and_code_allowed(self):
        for name in ('SECURITY.md', '.github/CODEOWNERS', 'tools/Security/run.py', '.gitleaksignore'):
            self.assertTrue(guard.public_path(name))
        self.assertIsNone(guard.KEY_HEADER.search(b'Ordinary documentation about private keys'))

    def test_screenshot_migration_only_permits_exact_historical_blobs(self):
        for name, object_id in guard.HISTORICAL_UI_EVIDENCE.items():
            self.assertFalse(guard.public_path(name))
            self.assertTrue(guard.historical_public_path(name, object_id))
            self.assertFalse(guard.historical_public_path(name, '0' * 40))
            self.assertTrue(guard.public_path(name.replace('docs/', 'art/', 1)))
        self.assertFalse(guard.historical_public_path('docs/screenshots/drop-to-mallow/new.png', '0' * 40))


if __name__ == '__main__':
    unittest.main()
