import importlib.util
import pathlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('tested_paddle_runner', ROOT / 'paddle_ocr_runner.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class InputCleanupTests(unittest.TestCase):
    def setUp(self):
        artifacts = ROOT / '.test-output' / 'paddle'
        artifacts.mkdir(parents=True, exist_ok=True)
        self.sandbox = tempfile.TemporaryDirectory(dir=artifacts)
        self.root = pathlib.Path(self.sandbox.name)
        self.source = self.root / 'source.png'
        self.source.write_bytes(b'synthetic source: no personal screenshot')
        runner.CACHE_DIR = str(self.root / 'cache')
        runner.configure_environment = lambda: None

    def tearDown(self):
        self.sandbox.cleanup()

    def test_success_removes_working_copy_but_preserves_source(self):
        class FakeOcr:
            def ocr(self, image, **kwargs):
                self.image = image
                return [{'rec_texts': ['Synthetic text']}]
        engine = FakeOcr()
        self.assertEqual(runner.recognize(engine, str(self.source)), 'Synthetic text')
        self.assertFalse(pathlib.Path(engine.image).exists(), 'OCR left a screenshot copy in its model cache')
        self.assertEqual(self.source.read_bytes(), b'synthetic source: no personal screenshot')

    def test_failure_also_removes_working_copy(self):
        class FakeOcr:
            def ocr(self, image, **kwargs):
                self.image = image
                raise RuntimeError('synthetic recognition failure')
        engine = FakeOcr()
        with self.assertRaises(RuntimeError):
            runner.recognize(engine, str(self.source))
        self.assertFalse(pathlib.Path(engine.image).exists(), 'failed OCR left a screenshot copy in its model cache')
        self.assertTrue(self.source.exists())


if __name__ == '__main__':
    unittest.main()
