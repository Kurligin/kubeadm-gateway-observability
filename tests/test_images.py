"""Unit tests of scripts/images.py (run by `make lint`)."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

import images  # noqa: E402

D = "@sha256:" + "a" * 64


class NormalizeTest(unittest.TestCase):
    def test_docker_hub_shorthand(self) -> None:
        self.assertEqual(images.normalize("busybox:1.37.0"), "docker.io/library/busybox:1.37.0")
        self.assertEqual(images.normalize("fluent/fluentd:v1"), "docker.io/fluent/fluentd:v1")

    def test_explicit_registry_kept(self) -> None:
        for ref in ("quay.io/a/b:1", "registry.k8s.io/pause:3.10", "localhost:5000/x:1"):
            self.assertEqual(images.normalize(ref), ref)

    def test_repository(self) -> None:
        self.assertEqual(images.repository("quay.io/a/b:v1" + D), "quay.io/a/b")
        self.assertEqual(images.repository("localhost:5000/x"), "localhost:5000/x")


class FindImagesTest(unittest.TestCase):
    def test_image_keys_and_embedded_references(self) -> None:
        docs = [
            {"kind": "Deployment", "spec": {"containers": [{"image": "busybox:1" + D}]}},
            {"kind": "Prometheus", "spec": {"image": "quay.io/prometheus/prometheus:v3" + D}},
            {"args": ["--reloader=quay.io/po/reloader:v0.94.1" + D, "--url=https://quay.io/x/y"]},
            {
                "data": {
                    "eg.yaml": "shutdownManager:\n  image: docker.io/envoyproxy/gateway:v1.9.2\n"
                }
            },
        ]
        self.assertEqual(
            images.find_images(docs),
            {
                "docker.io/library/busybox:1" + D,
                "quay.io/prometheus/prometheus:v3" + D,
                "quay.io/po/reloader:v0.94.1" + D,
                "docker.io/envoyproxy/gateway:v1.9.2",
            },
        )

    def test_pull_list_uses_digest_and_skips_not_run(self) -> None:
        found = {"quay.io/a/b:v1" + D, "quay.io/thanos/thanos:v0.42.4" + D, "quay.io/c/d:v2"}
        self.assertEqual(images.to_pull(found), ["quay.io/a/b" + D, "quay.io/c/d:v2"])


if __name__ == "__main__":
    unittest.main()
