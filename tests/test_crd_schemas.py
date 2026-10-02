"""Unit tests of scripts/crd_schemas.py (run by `make lint`)."""

import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

import crd_schemas  # noqa: E402

CRD = {
    "apiVersion": "apiextensions.k8s.io/v1",
    "kind": "CustomResourceDefinition",
    "metadata": {"name": "widgets.example.com"},
    "spec": {
        "group": "example.com",
        "names": {"kind": "Widget", "plural": "widgets"},
        "versions": [
            {
                "name": "v1",
                "schema": {
                    "openAPIV3Schema": {
                        "type": "object",
                        "properties": {
                            "spec": {
                                "type": "object",
                                "properties": {
                                    "size": {"x-kubernetes-int-or-string": True},
                                    "free": {
                                        "type": "object",
                                        "x-kubernetes-preserve-unknown-fields": True,
                                        "properties": {"known": {"type": "string"}},
                                    },
                                    "labels": {
                                        "type": "object",
                                        "additionalProperties": {"type": "string"},
                                    },
                                    "empty": {"type": "object"},
                                    "template": {
                                        "type": "object",
                                        "x-kubernetes-embedded-resource": True,
                                        "properties": {"spec": {"type": "object"}},
                                    },
                                    "raw": {
                                        "type": "object",
                                        "x-kubernetes-embedded-resource": True,
                                        "x-kubernetes-preserve-unknown-fields": True,
                                    },
                                    "items": {
                                        "type": "array",
                                        "items": {
                                            "type": "object",
                                            "properties": {"name": {"type": "string"}},
                                        },
                                    },
                                },
                            }
                        },
                    }
                },
            },
            {"name": "v1beta1", "served": False, "schema": {"openAPIV3Schema": {"type": "object"}}},
        ],
    },
}


class StrictSchemaTest(unittest.TestCase):
    def setUp(self) -> None:
        source = CRD["spec"]["versions"][0]["schema"]["openAPIV3Schema"]
        self.schema = crd_schemas.strict_schema(source)

    def test_objects_with_properties_reject_unknown_fields(self) -> None:
        self.assertIs(self.schema["additionalProperties"], False)
        spec = self.schema["properties"]["spec"]
        self.assertIs(spec["additionalProperties"], False)
        self.assertIs(spec["properties"]["items"]["items"]["additionalProperties"], False)

    def test_root_accepts_standard_object_fields(self) -> None:
        for field in ("apiVersion", "kind", "metadata"):
            self.assertIn(field, self.schema["properties"])

    def test_preserve_unknown_fields_and_maps_untouched(self) -> None:
        spec = self.schema["properties"]["spec"]["properties"]
        self.assertNotIn("additionalProperties", spec["free"])
        self.assertEqual(spec["labels"]["additionalProperties"], {"type": "string"})

    def test_object_without_properties_is_closed(self) -> None:
        # The API server prunes unknown fields of such an object, so a field
        # set there would be silently lost: reject it.
        empty = self.schema["properties"]["spec"]["properties"]["empty"]
        self.assertIs(empty["additionalProperties"], False)

    def test_metadata_stays_open(self) -> None:
        metadata = self.schema["properties"]["metadata"]
        self.assertNotIn("additionalProperties", metadata)

    def test_embedded_resource_accepts_object_fields(self) -> None:
        spec = self.schema["properties"]["spec"]["properties"]
        template = spec["template"]
        self.assertIs(template["additionalProperties"], False)
        self.assertEqual(set(template["properties"]), {"apiVersion", "kind", "metadata", "spec"})
        self.assertNotIn("additionalProperties", template["properties"]["metadata"])
        raw = spec["raw"]
        self.assertNotIn("additionalProperties", raw)
        self.assertIn("kind", raw["properties"])

    def test_int_or_string(self) -> None:
        size = self.schema["properties"]["spec"]["properties"]["size"]
        self.assertEqual(size["oneOf"], [{"type": "string"}, {"type": "integer"}])

    def test_input_not_modified(self) -> None:
        source = CRD["spec"]["versions"][0]["schema"]["openAPIV3Schema"]
        self.assertNotIn("additionalProperties", source)


class WriteSchemasTest(unittest.TestCase):
    def test_one_file_per_version_in_kubeconform_layout(self) -> None:
        other = {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "x"}}
        with tempfile.TemporaryDirectory() as tmp:
            written = crd_schemas.write_schemas([CRD, other, None], Path(tmp))
            files = sorted(p.relative_to(tmp).as_posix() for p in Path(tmp).rglob("*.json"))
            self.assertEqual(written, 2)
            self.assertEqual(
                files, ["example.com/widget_v1.json", "example.com/widget_v1beta1.json"]
            )
            schema = json.loads((Path(tmp) / "example.com/widget_v1.json").read_text())
            self.assertIs(schema["additionalProperties"], False)

    def test_yaml_value_key_is_read(self) -> None:
        # Rendered charts contain a bare "=" (YAML 1.1 value key).
        text = "kind: ConfigMap\ndata:\n  ops:\n    - =\n---\n" + json.dumps(CRD)
        with tempfile.TemporaryDirectory() as tmp, redirect_stderr(io.StringIO()):
            self.assertEqual(crd_schemas.main([tmp], stdin=text), 0)

    def test_no_crd_is_an_error(self) -> None:
        with tempfile.TemporaryDirectory() as tmp, redirect_stderr(io.StringIO()):
            self.assertEqual(crd_schemas.main([tmp], stdin="kind: ConfigMap\n"), 1)


if __name__ == "__main__":
    unittest.main()
