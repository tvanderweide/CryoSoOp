"""yaml_compat -- tiny YAML load/dump shim for the CryoSoOp orchestration + tools.

Design goal: run in the CryoSoOp conda env EXACTLY AS SHIPPED. That env currently
has numpy/scipy/matplotlib but *no* yaml library (neither PyYAML nor ruamel). So
this module prefers a real YAML parser when one is installed and otherwise falls
back to a small pure-stdlib parser that understands the subset used by the Brundage
config files (nested block mappings, scalars with type coercion, quoted strings,
inline/# comments, scalar anchors `&a`/aliases `*a`, and flow lists like
`[[0,0],[0,1]]`).

`load(path)` -> dict.  `dump(obj)` -> str.

The minimal parser is intentionally small; it is a *fallback*, not a general YAML
implementation. If the deployment env gains PyYAML/ruamel this shim silently uses
it and the fallback is never exercised.

This exact file is duplicated under both orchestration/ and tools/ so each
directory stays self-contained for standalone `conda run -n CryoSoOp python ...`.
"""
from __future__ import annotations

import io
import re


# --------------------------------------------------------------------------- #
# Public API
# --------------------------------------------------------------------------- #
def load(path):
    """Load a YAML file into a plain Python dict.

    Prefers PyYAML, then ruamel.yaml (safe), then the bundled minimal parser.
    """
    with io.open(path, "r", encoding="utf-8") as fh:
        text = fh.read()
    return loads(text)


def loads(text):
    # Prefer a real YAML library if available.
    try:
        import yaml  # PyYAML
        return yaml.safe_load(text)
    except ImportError:
        pass
    try:
        from ruamel.yaml import YAML
        y = YAML(typ="safe")
        return y.load(text)
    except ImportError:
        pass
    return _MiniYAML().parse(text)


def dump(obj):
    """Serialize a dict/list/scalar tree to a YAML string.

    Prefers PyYAML, then ruamel, then a minimal block dumper. Anchors/aliases and
    comments are NOT reproduced -- values are fully resolved. Intended for
    provenance snapshots, not round-trip-faithful config editing.
    """
    try:
        import yaml
        return yaml.safe_dump(obj, default_flow_style=False, sort_keys=False)
    except ImportError:
        pass
    try:
        from ruamel.yaml import YAML
        y = YAML(typ="safe")
        y.default_flow_style = False
        buf = io.StringIO()
        y.dump(obj, buf)
        return buf.getvalue()
    except ImportError:
        pass
    buf = io.StringIO()
    _mini_dump(obj, buf, 0)
    return buf.getvalue()


# --------------------------------------------------------------------------- #
# Minimal fallback parser
# --------------------------------------------------------------------------- #
_INT_RE = re.compile(r"^[+-]?\d+$")
_FLOAT_RE = re.compile(
    r"^[+-]?(\d+\.\d*|\.\d+|\d+)([eE][+-]?\d+)?$"
)


def _strip_inline_comment(s):
    """Remove a trailing ' # comment' that is outside of quotes."""
    out = []
    quote = None
    i = 0
    n = len(s)
    while i < n:
        c = s[i]
        if quote:
            out.append(c)
            if c == quote:
                quote = None
        else:
            if c in ("'", '"'):
                quote = c
                out.append(c)
            elif c == "#" and (i == 0 or s[i - 1] in " \t"):
                break
            else:
                out.append(c)
        i += 1
    return "".join(out).rstrip()


def _coerce_scalar(tok):
    """Coerce a bare (unquoted) scalar token to bool/int/float/None/str."""
    t = tok.strip()
    if t == "" or t == "~" or t.lower() == "null":
        return None
    low = t.lower()
    if low in ("true", "yes", "on"):
        return True
    if low in ("false", "no", "off"):
        return False
    if _INT_RE.match(t):
        try:
            return int(t)
        except ValueError:
            pass
    if _FLOAT_RE.match(t):
        try:
            return float(t)
        except ValueError:
            pass
    return t


def _parse_flow(tok):
    """Parse a flow collection like [1,2] or [[0,0],[0,1]] or {a: 1}."""
    val, idx = _parse_flow_node(tok, 0)
    return val


def _parse_flow_node(s, i):
    n = len(s)
    while i < n and s[i] in " \t":
        i += 1
    if i < n and s[i] == "[":
        seq = []
        i += 1
        while i < n:
            while i < n and s[i] in " \t,":
                i += 1
            if i < n and s[i] == "]":
                i += 1
                break
            item, i = _parse_flow_node(s, i)
            seq.append(item)
            while i < n and s[i] in " \t":
                i += 1
            if i < n and s[i] == ",":
                i += 1
            elif i < n and s[i] == "]":
                i += 1
                break
        return seq, i
    # scalar up to , ] or end
    start = i
    depth = 0
    quote = None
    while i < n:
        c = s[i]
        if quote:
            if c == quote:
                quote = None
        elif c in ("'", '"'):
            quote = c
        elif c in ",]":
            break
        i += 1
    raw = s[start:i].strip()
    if len(raw) >= 2 and raw[0] in ("'", '"') and raw[-1] == raw[0]:
        return raw[1:-1], i
    return _coerce_scalar(raw), i


def _parse_value(raw, anchors):
    """Parse the RHS of `key: RHS`, handling anchors/aliases/quotes/flow."""
    raw = raw.strip()
    if raw == "":
        return None, False  # (value, is_block_start)
    # alias
    if raw.startswith("*"):
        name = raw[1:].strip()
        return anchors.get(name), False
    # anchor
    anchor_name = None
    if raw.startswith("&"):
        m = re.match(r"&(\S+)\s*(.*)$", raw, re.DOTALL)
        anchor_name = m.group(1)
        raw = m.group(2).strip()
        if raw == "":
            # anchor on a block mapping -- handled by caller
            return ("__ANCHOR_BLOCK__", anchor_name), True
    if raw and raw[0] in "[{":
        val = _parse_flow(raw)
    elif len(raw) >= 2 and raw[0] in ("'", '"') and raw[-1] == raw[0]:
        val = raw[1:-1]
    else:
        val = _coerce_scalar(raw)
    if anchor_name is not None:
        anchors[anchor_name] = val
    return val, False


class _MiniYAML(object):
    def parse(self, text):
        anchors = {}
        root = {}
        # stack of (indent, container)
        stack = [(-1, root)]
        pending_anchor = None  # (indent_of_key, anchor_name) awaiting its block
        for lineno, rawline in enumerate(text.splitlines(), 1):
            line = _strip_inline_comment(rawline)
            if line.strip() == "":
                continue
            indent = len(line) - len(line.lstrip(" "))
            content = line.strip()
            if content.startswith("- "):
                # block sequence item -- not used by these configs; skip gracefully
                continue
            if ":" not in content:
                continue
            key, _, rhs = content.partition(":")
            key = key.strip()
            if len(key) >= 2 and key[0] in ("'", '"') and key[-1] == key[0]:
                key = key[1:-1]
            # pop to correct parent
            while stack and indent <= stack[-1][0]:
                stack.pop()
            if not stack:
                stack = [(-1, root)]
            parent = stack[-1][1]
            value, is_block = _parse_value(rhs, anchors)
            if is_block or rhs.strip() == "" or (
                isinstance(value, tuple) and value and value[0] == "__ANCHOR_BLOCK__"
            ):
                child = {}
                parent[key] = child
                stack.append((indent, child))
                if isinstance(value, tuple) and value and value[0] == "__ANCHOR_BLOCK__":
                    anchors[value[1]] = child
            else:
                parent[key] = value
        return root


# --------------------------------------------------------------------------- #
# Minimal fallback dumper
# --------------------------------------------------------------------------- #
def _mini_dump(obj, buf, indent):
    pad = "  " * indent
    if isinstance(obj, dict):
        if not obj:
            buf.write(pad + "{}\n")
            return
        for k, v in obj.items():
            if isinstance(v, dict) and v:
                buf.write("%s%s:\n" % (pad, k))
                _mini_dump(v, buf, indent + 1)
            elif isinstance(v, (list, tuple)):
                buf.write("%s%s: %s\n" % (pad, k, _flow_repr(v)))
            else:
                buf.write("%s%s: %s\n" % (pad, k, _scalar_repr(v)))
    elif isinstance(obj, (list, tuple)):
        buf.write(pad + _flow_repr(obj) + "\n")
    else:
        buf.write(pad + _scalar_repr(obj) + "\n")


def _flow_repr(seq):
    return "[" + ", ".join(
        _flow_repr(x) if isinstance(x, (list, tuple)) else _scalar_repr(x)
        for x in seq
    ) + "]"


def _scalar_repr(v):
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    s = str(v)
    if s == "" or re.search(r"[:#\[\]{},&*]", s) or s.strip() != s:
        return '"%s"' % s.replace('"', '\\"')
    return s
