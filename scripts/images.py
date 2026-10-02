"""Container images referenced by rendered Kubernetes manifests.

Reads multi-document YAML (`helmfile template`) from stdin and finds every
image reference: values of `image` keys at any depth (Pods, Prometheus and
Alertmanager objects, EnvoyProxy, ...) and references embedded in other
strings (operator arguments, configuration files inside ConfigMaps).

  images.py list               print the images to pre-pull, one per line
  images.py check <list file>  fail if an image has no digest, or if the
                               list file differs from what `list` prints

Images that are only referenced and never run here are pinned all the same,
but left out of the pre-pull list (see NOT_RUN).
"""

import re
import sys
from collections.abc import Iterable, Iterator
from pathlib import Path
from typing import Any

import yaml

# Registries the manifests pull from; a bare "name/repo:tag" means Docker Hub.
REGISTRIES = (
    "docker.io",
    "quay.io",
    "registry.k8s.io",
    "ghcr.io",
    "gcr.io",
    "docker.angie.software",
)

# Reference with an explicit registry inside any string (arguments, embedded
# configuration). Not preceded by "/" or a word character, so URLs such as
# https://quay.io/... or longer host names do not match.
EMBEDDED = re.compile(
    r"(?<![\w./-])(?:"
    + "|".join(re.escape(r) for r in REGISTRIES)
    + r")/[a-z0-9._/-]+(?::[\w.-]+)?(?:@sha256:[a-f0-9]{64})?"
)
DIGEST = re.compile(r"@sha256:[a-f0-9]{64}$")

# Pinned, but only referenced: never started on this cluster.
NOT_RUN = {
    "docker.io/envoyproxy/ratelimit": "Envoy Gateway global rate limit (local limits only)",
    "quay.io/jetstack/cert-manager-acmesolver": "cert-manager ACME HTTP-01 solver (no ACME issuer)",
    "quay.io/thanos/thanos": "Thanos sidecar default of the Prometheus Operator (no Thanos)",
}


class _Loader(yaml.SafeLoader):
    """Safe loader that reads a bare "=" (YAML 1.1 value key) as a string."""


_Loader.add_constructor(
    "tag:yaml.org,2002:value",
    lambda loader, node: loader.construct_scalar(node),  # type: ignore[arg-type]
)


def load_documents(text: str) -> list[Any]:
    """All YAML documents of a multi-document stream."""
    return list(yaml.load_all(text, Loader=_Loader))  # noqa: S506 (safe loader subclass)


def normalize(ref: str) -> str:
    """Fully qualified reference: docker.io/library/busybox:1 for busybox:1."""
    first = ref.split("/", 1)[0]
    if "/" not in ref or ("." not in first and ":" not in first and first != "localhost"):
        ref = "docker.io/" + (ref if "/" in ref else "library/" + ref)
    return ref


def repository(ref: str) -> str:
    """Reference without tag and digest."""
    name = ref.split("@", 1)[0]
    last = name.rsplit("/", 1)[-1]
    if ":" in last:
        name = name[: -(len(last) - last.index(":"))]
    return name


def _strings(node: Any, key: str | None = None) -> Iterator[tuple[str | None, str]]:
    if isinstance(node, dict):
        for k, v in node.items():
            yield from _strings(v, str(k))
    elif isinstance(node, list):
        for item in node:
            yield from _strings(item, key)
    elif isinstance(node, str):
        yield key, node


def find_images(documents: Iterable[Any]) -> set[str]:
    """Every image reference in the given YAML documents, normalized."""
    found: set[str] = set()
    for doc in documents:
        for key, value in _strings(doc):
            if key == "image" and value and " " not in value.strip():
                found.add(normalize(value.strip()))
            else:
                found.update(normalize(m.group(0)) for m in EMBEDDED.finditer(value))
    return found


def to_pull(images: Iterable[str]) -> list[str]:
    """Pre-pull list: images that run, as repository@digest (or as is)."""
    result = set()
    for ref in images:
        if repository(ref) in NOT_RUN:
            continue
        match = DIGEST.search(ref)
        result.add(repository(ref) + match.group(0) if match else ref)
    return sorted(result)


def main(argv: list[str]) -> int:
    if not argv or argv[0] not in ("list", "check") or (argv[0] == "check") != (len(argv) == 2):
        print(__doc__, file=sys.stderr)
        return 2
    images = find_images(load_documents(sys.stdin.read()))
    if not images:
        print("no images found in the input", file=sys.stderr)
        return 1
    if argv[0] == "list":
        print("\n".join(to_pull(images)))
        return 0

    status = 0
    unpinned = sorted(ref for ref in images if not DIGEST.search(ref))
    for ref in unpinned:
        print(f"image without digest: {ref}", file=sys.stderr)
        status = 1
    listed = [
        line.strip()
        for line in Path(argv[1]).read_text().splitlines()
        if line.strip() and not line.startswith("#")
    ]
    if listed != to_pull(images):
        missing = sorted(set(to_pull(images)) - set(listed))
        extra = sorted(set(listed) - set(to_pull(images)))
        print(
            f"{argv[1]} is out of date (run `make images-list`): "
            f"missing {missing or 'nothing'}, not used {extra or 'nothing'}",
            file=sys.stderr,
        )
        status = 1
    if status == 0:
        print(f"{len(images)} images, all pinned by digest; {argv[1]} is up to date")
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
