"""Reject invalid IPA containers before invoking any signing tools."""
import contextlib, importlib.util, io, pathlib, sys, tempfile, unittest, zipfile
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('verify_ios', ROOT / 'scripts/verify-ios.py')
VERIFIER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFIER)


class ContainerSafety(unittest.TestCase):
    def rejected(self, members, message):
        with tempfile.TemporaryDirectory(prefix='banana-ipa-negative-') as temporary:
            artifact = pathlib.Path(temporary) / 'invalid-fixture.ipa'
            with zipfile.ZipFile(artifact, 'w') as archive:
                for name in members:
                    archive.writestr(name, b'test fixture, not an application')
            with patch.object(sys, 'argv', ['verify-ios.py', str(artifact)]), \
                 patch.object(VERIFIER, 'run') as tool, contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaisesRegex(ValueError, message):
                    VERIFIER.main()
                tool.assert_not_called()

    def test_parent_traversal(self):
        self.rejected(['../escaped.txt'], 'Unsafe IPA')

    def test_absolute_path(self):
        self.rejected(['/tmp/escaped.txt'], 'Unsafe IPA')

    def test_empty_payload(self):
        self.rejected(['readme.txt'], 'exactly one real application')


if __name__ == '__main__':
    unittest.main()
