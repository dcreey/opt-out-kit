import io, os, sys, unittest, urllib.error, urllib.request
from unittest import mock
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import profile_brokers as pb


class Resp:
    status = 200
    def __init__(self, body=b"ok"): self.body = body
    def __enter__(self): return self
    def __exit__(self, *a): return False
    def geturl(self): return "https://x.example/"
    def read(self, n): return self.body


def http_error(code, headers=None):
    return urllib.error.HTTPError("https://x.example/", code, "err", headers or {}, io.BytesIO(b"body"))


class FetcherRetries(unittest.TestCase):
    def run_get(self, outcomes):
        sleeps = []
        with mock.patch("urllib.request.urlopen", side_effect=outcomes):
            result = pb.Fetcher().get("https://x.example/", sleep=sleeps.append)
        return result, sleeps

    def test_a_flaky_first_try_is_retried_and_succeeds(self):
        (st, _, body), sleeps = self.run_get([TimeoutError(), http_error(503), Resp()])
        self.assertEqual((st, body), (200, "ok"))
        self.assertEqual(len(sleeps), 2)
        self.assertLess(sleeps[0], sleeps[1] + 1)          # backs off, never speeds up

    def test_a_real_404_is_final_and_not_retried(self):
        (st, _, _), sleeps = self.run_get([http_error(404)])
        self.assertEqual(st, 404); self.assertEqual(sleeps, [])

    def test_it_gives_up_after_the_limit_and_never_raises(self):
        (st, _, body), sleeps = self.run_get([ConnectionResetError()] * 10)
        self.assertEqual((st, body), (None, ""))
        self.assertEqual(len(sleeps), pb.Fetcher.MAX_TRIES - 1)

    def test_retry_after_is_honored_and_capped(self):
        self.assertEqual(pb.Fetcher.backoff(1, retry_after=7), 7)
        self.assertEqual(pb.Fetcher.backoff(1, retry_after=9999), 60)
        (st, _, _), sleeps = self.run_get([http_error(429, {"Retry-After": "5"}), Resp()])
        self.assertEqual((st, sleeps), (200, [5.0]))

    def test_backoff_grows_and_is_capped(self):
        waits = [pb.Fetcher.backoff(a) for a in (1, 2, 3)]
        self.assertTrue(2 <= waits[0] < 3 and 4 <= waits[1] < 5 and 8 <= waits[2] < 9)
        self.assertLessEqual(pb.Fetcher.backoff(20), 60)


if __name__ == "__main__":
    unittest.main()
