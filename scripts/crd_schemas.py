"""JSON schemas for kubeconform from CustomResourceDefinitions.

Reads multi-document YAML from stdin and writes, for every version of every
CustomResourceDefinition in it, the version's OpenAPI v3 schema as
<out dir>/<group>/<kind>_<version>.json (kind in lower case), the layout of
the kubeconform option

  -schema-location '<out dir>/{{ .Group }}/{{ .ResourceKind }}_{{ .ResourceAPIVersion }}.json'

Schemas are made strict the way kubectl validates objects: an object rejects
fields its schema does not declare (unless it is marked
x-kubernetes-preserve-unknown-fields or declares additionalProperties, as a
map does), also an object without any properties, whose fields the API
server would prune. Object metadata stays open (the API server validates
it), embedded resources (x-kubernetes-embedded-resource) accept apiVersion,
kind and metadata, and x-kubernetes-int-or-string becomes "string or
integer". Other documents are ignored.

  crd_schemas.py <out dir>
"""

import copy
import json
import sys
from collections.abc import Iterable
from pathlib import Path
from typing import Any

from images import load_documents

# Fields every Kubernetes object may carry; CRD schemas often omit them.
OBJECT_FIELDS = {
    "apiVersion": {"type": "string"},
    "kind": {"type": "string"},
    # Marked so that it is never closed (validated by the API server).
    "metadata": {"type": "object", "x-kubernetes-preserve-unknown-fields": True},
}


def _strict(node: dict[str, Any]) -> None:
    # allOf/anyOf/oneOf/not are left alone: in structural schemas they only
    # add value validations, never fields, so strict branches would reject
    # valid objects.
    if node.get("x-kubernetes-int-or-string"):
        node.setdefault("oneOf", [{"type": "string"}, {"type": "integer"}])
    if node.get("x-kubernetes-embedded-resource"):
        props = node.setdefault("properties", {})
        for name, schema in OBJECT_FIELDS.items():
            props.setdefault(name, copy.deepcopy(schema))
    if (
        ("properties" in node or node.get("type") == "object")
        and "additionalProperties" not in node
        and not node.get("x-kubernetes-preserve-unknown-fields")
    ):
        node["additionalProperties"] = False
    for child in node.get("properties", {}).values():
        if isinstance(child, dict):
            _strict(child)
    for key in ("items", "additionalProperties"):
        if isinstance(node.get(key), dict):
            _strict(node[key])


def strict_schema(schema: dict[str, Any]) -> dict[str, Any]:
    """Strict copy of the openAPIV3Schema of a CRD version."""
    result = copy.deepcopy(schema)
    props = result.setdefault("properties", {})
    for name, field in OBJECT_FIELDS.items():
        props.setdefault(name, copy.deepcopy(field))
    # Standard object metadata is validated by the API server, not here.
    props["metadata"] = copy.deepcopy(OBJECT_FIELDS["metadata"])
    _strict(result)
    return result


def write_schemas(documents: Iterable[Any], out_dir: Path) -> int:
    """Write the schema files; return how many were written."""
    count = 0
    for doc in documents:
        if not isinstance(doc, dict) or doc.get("kind") != "CustomResourceDefinition":
            continue
        spec = doc["spec"]
        kind = spec["names"]["kind"].lower()
        for version in spec["versions"]:
            schema = version.get("schema", {}).get("openAPIV3Schema")
            if not schema:
                continue
            path = out_dir / spec["group"] / f"{kind}_{version['name']}.json"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(strict_schema(schema), indent=1, sort_keys=True))
            count += 1
    return count


def main(argv: list[str], stdin: str | None = None) -> int:
    if len(argv) != 1:
        print(__doc__, file=sys.stderr)
        return 2
    text = sys.stdin.read() if stdin is None else stdin
    count = write_schemas(load_documents(text), Path(argv[0]))
    if count == 0:
        print("no CustomResourceDefinition found in the input", file=sys.stderr)
        return 1
    print(f"{count} CRD schemas written to {argv[0]}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
