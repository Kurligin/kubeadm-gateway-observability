"""Unit tests of scripts/vendor-charts.sh check (run by `make lint`).

Every test builds a throw-away repository: the real script, a versions.env
with the version and sha256 keys it reads, and fake chart archives (a
Chart.yaml only) in vendor/charts.
"""

import hashlib
import io
import re
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "vendor-charts.sh"
BASH = shutil.which("bash") or "/bin/bash"


def chart_entries() -> list[tuple[str, str, str, str]]:
    """(chart name, version key, version prefix, sha256 key) of the script."""
    text = SCRIPT.read_text()
    block = re.search(r"readonly CHARTS=\((.*?)\n\)", text, re.S)
    if block is None:
        raise AssertionError("no CHARTS array in scripts/vendor-charts.sh")
    entries = []
    for line in re.findall(r'"([^"]+)"', block.group(1)):
        name, _source, version_key, prefix, sha_key = line.split()
        entries.append((name, version_key, "" if prefix == "-" else prefix, sha_key))
    return entries


def chart_archive(name: str, version: str) -> bytes:
    """A gzipped tar with <name>/Chart.yaml, like a packaged chart."""
    chart_yaml = f"apiVersion: v2\nname: {name}\nversion: {version}\n".encode()
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        info = tarfile.TarInfo(f"{name}/Chart.yaml")
        info.size = len(chart_yaml)
        tar.addfile(info, io.BytesIO(chart_yaml))
    return buf.getvalue()


class VendorChartsCheckTest(unittest.TestCase):
    def setUp(self) -> None:
        self.repo = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.repo)
        (self.repo / "scripts").mkdir()
        shutil.copy(SCRIPT, self.repo / "scripts")
        vendor = self.repo / "vendor" / "charts"
        vendor.mkdir(parents=True)
        lines = ["# test versions"]
        self.files: dict[str, Path] = {}
        seen_versions: set[str] = set()
        for index, (name, version_key, prefix, sha_key) in enumerate(chart_entries()):
            version = f"1.{index}.0"
            if version_key not in seen_versions:
                lines.append(f"{version_key}={version}")
                seen_versions.add(version_key)
            else:
                version = next(
                    line.split("=", 1)[1] for line in lines if line.startswith(f"{version_key}=")
                )
            data = chart_archive(name, prefix + version)
            path = vendor / f"{name}-{prefix}{version}.tgz"
            path.write_bytes(data)
            self.files[sha_key] = path
            lines.append(f"{sha_key}={hashlib.sha256(data).hexdigest()}")
        (self.repo / "versions.env").write_text("\n".join(lines) + "\n")

    def check(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(  # noqa: S603 - fixed script path
            [BASH, "scripts/vendor-charts.sh", "check"],
            cwd=self.repo,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_matching_charts_pass(self) -> None:
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"{len(self.files)} vendored charts match", result.stderr)

    def test_checksum_mismatch_fails(self) -> None:
        path = self.files["CILIUM_CHART_SHA256"]
        path.write_bytes(chart_archive("cilium", "9.9.9"))
        result = self.check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CILIUM_CHART_SHA256", result.stderr)

    def test_missing_chart_fails(self) -> None:
        self.files["METRICS_SERVER_CHART_SHA256"].unlink()
        result = self.check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("is missing", result.stderr)

    def test_stale_archive_fails(self) -> None:
        stale = self.repo / "vendor" / "charts" / "cilium-0.0.1.tgz"
        stale.write_bytes(chart_archive("cilium", "0.0.1"))
        result = self.check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cilium-0.0.1.tgz", result.stderr)

    def test_wrong_chart_inside_fails(self) -> None:
        # Pinned checksum of an archive that holds another chart.
        path = self.files["CERT_MANAGER_CHART_SHA256"]
        data = chart_archive("not-cert-manager", "v1.0.0")
        path.write_bytes(data)
        versions = self.repo / "versions.env"
        text = re.sub(
            r"^CERT_MANAGER_CHART_SHA256=.*$",
            f"CERT_MANAGER_CHART_SHA256={hashlib.sha256(data).hexdigest()}",
            versions.read_text(),
            flags=re.M,
        )
        versions.write_text(text)
        result = self.check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not chart cert-manager", result.stderr)

    def test_every_chart_of_the_repository_is_vendored(self) -> None:
        # The real repository: what `make lint` checks offline.
        result = subprocess.run(  # noqa: S603 - fixed script path
            [BASH, str(SCRIPT), "check"],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
