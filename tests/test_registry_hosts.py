"""Unit tests of the containerd registry host template (run by `make lint`).

Renders ansible/roles/containerd/templates/hosts.toml.j2 the way the role
does (Jinja2, which comes with ansible-core) and parses the result as TOML.
"""

import tomllib
import unittest
from pathlib import Path

import jinja2

TEMPLATE = Path(__file__).resolve().parents[1] / "ansible/roles/containerd/templates/hosts.toml.j2"


def render(registry: str, server: str, mirrors: list[str]) -> str:
    # TOML, not HTML: no autoescaping, the same as Ansible's templating.
    env = jinja2.Environment(
        autoescape=False,  # noqa: S701
        undefined=jinja2.StrictUndefined,
        keep_trailing_newline=True,
    )
    template = env.from_string(TEMPLATE.read_text())
    return template.render(
        ansible_managed="Ansible managed",
        item={"registry": registry, "server": server, "mirrors": mirrors},
    )


class HostsTomlTest(unittest.TestCase):
    def test_mirrors_in_order_then_server(self) -> None:
        mirrors = ["https://a.example", "https://b.example:5000"]
        text = render("docker.io", "https://registry-1.docker.io", mirrors)
        config = tomllib.loads(text)
        self.assertEqual(config["server"], "https://registry-1.docker.io")
        # TOML tables keep their order: containerd tries the hosts in it.
        self.assertEqual(list(config["host"]), mirrors)
        for host in config["host"].values():
            self.assertEqual(host["capabilities"], ["pull", "resolve"])
            self.assertIn("dial_timeout", host)

    def test_marker_comment(self) -> None:
        # The role finds the files it wrote by this marker: a line that
        # starts with it (ansible.builtin.find matches from a line's start).
        text = render("quay.io", "https://quay.io", ["https://m.example"])
        marker = "# kubeadm-gateway-observability registry mirrors"
        self.assertTrue(any(line.startswith(marker) for line in text.splitlines()))

    def test_special_characters_are_quoted(self) -> None:
        text = render("docker.io", "https://registry-1.docker.io", ['https://x.example/"q'])
        config = tomllib.loads(text)
        self.assertEqual(list(config["host"]), ['https://x.example/"q'])


if __name__ == "__main__":
    unittest.main()
