"""Dependency-free reader for the YAML subset used by this repository's
GitHub Actions workflows and configuration.

PyYAML is not guaranteed on developer machines or on every runner image, and a
hardening gate that silently skips when its parser is missing would fail open.
This reader therefore covers exactly the constructs the repository uses and
raises `WorkflowYamlError` on anything else, so an unparsable workflow fails
the gate loudly instead of being ignored.

Supported: block mappings, block sequences (including inline first keys such as
`- uses: x`), plain/quoted scalars, flow sequences (`[a, b]`), and block
scalars (`|`, `>`), plus `#` comments. Not supported (and rejected): anchors,
aliases, tags, flow mappings, multi-document streams.
"""

import re

_FLOW_SEQ = re.compile(r"^\[(.*)\]$")


class WorkflowYamlError(ValueError):
    """Raised when a file uses YAML this reader intentionally does not accept."""


def _strip_comment(text):
    out = []
    quote = None
    for index, char in enumerate(text):
        if quote:
            out.append(char)
            if char == quote:
                quote = None
            continue
        if char in ('"', "'"):
            quote = char
            out.append(char)
        elif char == "#" and (index == 0 or text[index - 1] in " \t"):
            break
        else:
            out.append(char)
    return "".join(out).rstrip()


def _scan_lines(source):
    """Return [indent, content] rows for significant lines."""
    rows = []
    for number, raw in enumerate(source.splitlines(), start=1):
        if "\t" in raw[: len(raw) - len(raw.lstrip(" \t"))]:
            raise WorkflowYamlError(f"line {number}: tab indentation is not supported")
        stripped = raw.lstrip(" ")
        indent = len(raw) - len(stripped)
        content = _strip_comment(stripped)
        if not content:
            continue
        rows.append([indent, content, number, raw])
    return rows


def _reject_unsupported(text, number):
    """Structural positions only; block-scalar bodies are never inspected."""
    if text.startswith(("---", "...", "&", "*", "!", "{")):
        raise WorkflowYamlError(f"line {number}: unsupported YAML construct {text[:16]!r}")


def _split_key(content):
    """Split `key: value` honouring quotes and `${{ ... }}` expressions."""
    quote = None
    depth = 0
    for index, char in enumerate(content):
        if quote:
            if char == quote:
                quote = None
            continue
        if char in ('"', "'"):
            quote = char
        elif char == "{":
            depth += 1
        elif char == "}":
            depth = max(0, depth - 1)
        elif char == ":" and depth == 0:
            rest = content[index + 1 :]
            if rest == "" or rest[0] in " \t":
                return content[:index].strip(), rest.strip()
    return None, None


def _scalar(text):
    if text == "":
        return None
    if len(text) >= 2 and text[0] == text[-1] and text[0] in ('"', "'"):
        return text[1:-1]
    flow = _FLOW_SEQ.match(text)
    if flow:
        inner = flow.group(1).strip()
        if not inner:
            return []
        return [_scalar(part.strip()) for part in _split_flow(inner)]
    if text in ("true", "True", "yes", "on"):
        return True
    if text in ("false", "False", "no", "off"):
        return False
    if text in ("null", "~"):
        return None
    if re.fullmatch(r"-?\d+", text):
        return int(text)
    return text


def _split_flow(inner):
    parts = []
    current = []
    quote = None
    for char in inner:
        if quote:
            current.append(char)
            if char == quote:
                quote = None
            continue
        if char in ('"', "'"):
            quote = char
            current.append(char)
        elif char == ",":
            parts.append("".join(current))
            current = []
        else:
            current.append(char)
    parts.append("".join(current))
    return [part for part in parts if part.strip()]


def _block_scalar(rows, index, parent_indent):
    """Consume an indented literal/folded block and return its raw text."""
    body = []
    while index < len(rows) and rows[index][0] > parent_indent:
        body.append(rows[index][3])
        index += 1
    if not body:
        return "", index
    margin = min(len(line) - len(line.lstrip(" ")) for line in body if line.strip())
    return "\n".join(line[margin:] for line in body), index


def _parse(rows, index, indent):
    if rows[index][1].startswith("- ") or rows[index][1] == "-":
        return _parse_sequence(rows, index, indent)
    return _parse_mapping(rows, index, indent)


def _parse_mapping(rows, index, indent):
    result = {}
    while index < len(rows) and rows[index][0] == indent:
        content = rows[index][1]
        number = rows[index][2]
        _reject_unsupported(content, number)
        key, rest = _split_key(content)
        if key is None:
            raise WorkflowYamlError(f"line {number}: expected `key: value`, got {content!r}")
        index += 1
        if rest in ("|", ">", "|-", ">-", "|+", ">+"):
            result[key], index = _block_scalar(rows, index, indent)
        elif rest == "":
            if index < len(rows) and rows[index][0] > indent:
                result[key], index = _parse(rows, index, rows[index][0])
            elif index < len(rows) and rows[index][0] == indent and rows[index][1].startswith("-"):
                result[key], index = _parse_sequence(rows, index, indent)
            else:
                result[key] = None
        else:
            _reject_unsupported(rest, number)
            result[key] = _scalar(rest)
        if index < len(rows) and rows[index][0] > indent:
            raise WorkflowYamlError(f"line {rows[index][2]}: unexpected indentation")
    return result, index


def _parse_sequence(rows, index, indent):
    items = []
    while index < len(rows) and rows[index][0] == indent and rows[index][1].startswith("-"):
        content = rows[index][1]
        rest = content[1:]
        offset = indent + 1 + (len(rest) - len(rest.lstrip(" ")))
        rest = rest.strip()
        _reject_unsupported(rest, rows[index][2])
        if rest == "":
            index += 1
            if index < len(rows) and rows[index][0] > indent:
                value, index = _parse(rows, index, rows[index][0])
            else:
                value = None
            items.append(value)
            continue
        key, _ = _split_key(rest)
        if key is None:
            items.append(_scalar(rest))
            index += 1
            continue
        rows[index] = [offset, rest, rows[index][2], rows[index][3]]
        value, index = _parse_mapping(rows, index, offset)
        items.append(value)
    return items, index


def loads(source):
    """Parse a YAML document into plain Python structures."""
    rows = _scan_lines(source)
    if not rows:
        return {}
    value, index = _parse(rows, 0, rows[0][0])
    if index != len(rows):
        raise WorkflowYamlError(f"line {rows[index][2]}: trailing content {rows[index][1]!r}")
    return value


def load_file(path):
    with open(path, "r", encoding="utf-8") as handle:
        return loads(handle.read())
