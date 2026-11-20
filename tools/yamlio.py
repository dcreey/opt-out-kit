"""Reads and writes the repository's YAML (directory/*.yml, terms/library.yml, and the hand-written files) for the tools.

Every tool goes through here, so all YAML is written one way: the rules in .yamllint.yml (github.com/abcxyz/actions), checked by CI's lint-yaml job.
String values are single-quoted, mappings are blocks (never inline `{ }`), indentation is 2 with sequences indented, `null` is written out, and lines
are never wrapped. Reading keeps comments, key order and anything a person edited by hand, so a tool that changes one field leaves the rest of the
file as it was.

    import yamlio
    doc = yamlio.load(path)              # a dict (ruamel's CommentedMap: comments kept)
    doc["persistence"] = {...}           # plain dicts, lists and strings are fine
    yamlio.save(path, doc)
    for path, doc in yamlio.entries("directory"): ...

Needs ruamel.yaml (tools/requirements.txt: `pip install -r tools/requirements.txt`).
"""
import glob
import io
import os
import re

from ruamel.yaml import YAML
from ruamel.yaml.comments import CommentedMap, CommentedSeq
from ruamel.yaml.scalarstring import FoldedScalarString, LiteralScalarString, ScalarString, SingleQuotedScalarString


# Words YAML 1.1 (PyYAML, and so many tools) reads as true or false when they are not quoted.
BOOLEAN_WORDS = {"y", "n", "yes", "no", "on", "off", "true", "false"}


def _yaml():
    y = YAML()                                   # round trip: comments and key order kept
    y.preserve_quotes = True
    y.width = 1_000_000                          # never wrap a line
    y.indent(mapping=2, sequence=4, offset=2)
    y.representer.add_representer(type(None), lambda r, d: r.represent_scalar("tag:yaml.org,2002:null", "null"))
    return y


def styled(node, depth=0):
    """The value in the house style: string values single-quoted, mappings and sequences of mappings as blocks. Block scalars (`|`, `>`) stay."""
    if isinstance(node, dict):
        out = node if isinstance(node, CommentedMap) else CommentedMap(node)
        out.fa.set_block_style()
        for pos, k in enumerate(list(out.keys())):
            v = styled(out[k], depth + 1)
            # A key a YAML 1.1 reader would take for true or false (Norwegian's language code `no`) is quoted; any other key is written plainly,
            # even one that came "quoted" from inline JSON.
            # (GitHub Actions' top-level `on:` stays plain: the rules allow it, and it is how every workflow is written.)
            boolean = isinstance(k, str) and str(k).lower() in BOOLEAN_WORDS and not (str(k) == "on" and depth == 0)
            want = SingleQuotedScalarString(str(k)) if boolean else (str(k) if isinstance(k, ScalarString) else k)
            if want is not k or type(want) is not type(k):
                del out[k]
                out.insert(pos, want, v)
            else:
                out[k] = v
        return out
    if isinstance(node, (list, tuple)):
        out = node if isinstance(node, CommentedSeq) else CommentedSeq(list(node))
        if any(isinstance(x, (dict, list, tuple)) for x in out):
            out.fa.set_block_style()
        else:
            out.fa.set_flow_style()              # a list of plain values stays on one line: ['a', 'b']
        for i, x in enumerate(out):
            out[i] = styled(x, depth + 1)
        return out
    if isinstance(node, (LiteralScalarString, FoldedScalarString)):
        return node
    if isinstance(node, str):
        return SingleQuotedScalarString(str(node))
    return node


def loads(text):
    return _yaml().load(text)


def dumps(doc):
    out = io.StringIO()
    _yaml().dump(styled(doc), out)
    return out.getvalue()


def load(path):
    with open(path, encoding="utf-8") as f:
        return loads(f.read())


def save(path, doc):
    """Writes the document in the house style; nothing is written when it is unchanged (so file times and diffs stay quiet)."""
    text = dumps(doc)
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            if f.read() == text:
                return False
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)
    return True


def entry_path(folder, domain):
    """The directory file for a domain: lower case, every run of other characters as one `_` (example.co.uk -> example_co_uk.yml)."""
    return os.path.join(folder, re.sub(r"[^a-z0-9]+", "_", domain.lower()).strip("_") + ".yml")


def entries(folder):
    """(path, document) for every *.yml in the folder, in name order."""
    for path in sorted(glob.glob(os.path.join(folder, "*.yml"))):
        yield path, load(path)


def any_found(doc):
    """Whether any block of the entry records `found: true` (a live look or a check that found the form)."""
    return any(isinstance(v, dict) and v.get("found") is True for v in doc.values())


def http(v):
    """The value when it is a web address, else None."""
    return v if isinstance(v, str) and v.startswith(("http://", "https://")) else None


def live_page(doc):
    """The page a live look found the opt-out form on (`live_form.page`), when it found one or recorded the page."""
    return http((doc.get("live_form") or {}).get("page"))


def form_page(doc):
    """The page the stored form was read from (`opt_out_form.page`)."""
    return http((doc.get("opt_out_form") or {}).get("page"))


def plain(node):
    """The value as plain Python (dicts, lists, str), for comparing or for json.dumps."""
    if isinstance(node, dict):
        return {str(k): plain(v) for k, v in node.items()}
    if isinstance(node, list):
        return [plain(v) for v in node]
    if isinstance(node, ScalarString):
        return str(node)
    return node


def set_comment(doc, text):
    """Sets the comment at the top of a new document (each line gets `# `)."""
    doc.yaml_set_start_comment(text)
    return doc
