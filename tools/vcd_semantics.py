"""Bounded four-state VCD artifact oracle (IEEE 1364-2005 18.1–18.2).

This is not a complete VCD conformance validator. It supports the existing
scalar/vector fixtures; real/event/extended records fail loudly as unsupported.
The semantic projection ignores arbitrary identifier assignment, independent
declaration/change order, layout and empty timestamps. Metadata is RETAINED
separately: callers must inspect version/task text and required limit comments.
No simulator output is generated, and no source PDF text is embedded here.
"""

from collections import defaultdict
from dataclasses import dataclass
import re


class VcdError(ValueError):
    pass


@dataclass
class Vcd:
    timescale: tuple
    variables: dict
    events: list
    metadata: list

    def semantic_projection(self):
        return self.timescale, tuple(sorted(self.variables.items())), self.events

    def metadata_text(self, kind):
        return [text for _, keyword, text in self.metadata if keyword == kind]

    def require_metadata(self):
        # Source 18.2.1 requires header date/version; don't erase them merely
        # because their exact values are vendor/run dependent.
        for kind in ("$date", "$version"):
            if not any(text.strip() for text in self.metadata_text(kind)):
                raise VcdError(f"missing nonempty {kind} metadata")


def parse_vcd(text):
    tokens = text.split()
    cursor = 0
    scopes = []
    variables = {}
    codes = defaultdict(list)
    metadata = []
    events = []
    pending = defaultdict(list)
    timescale = None
    time = 0
    in_body = False

    def take():
        nonlocal cursor
        if cursor >= len(tokens):
            raise VcdError("unexpected end of VCD")
        token = tokens[cursor]
        cursor += 1
        return token

    def command_body():
        body = []
        while (token := take()) != "$end":
            body.append(token)
        return body

    def flush_changes():
        if pending:
            events.append((time, "change", tuple(
                sorted((name, tuple(values)) for name, values in pending.items()))))
            pending.clear()

    def value_change(token):
        if token[:1] in "bB":
            bits, code = token[1:], take()
            if not bits or re.fullmatch("[01xXzZ]+", bits) is None:
                raise VcdError("invalid binary value")
        elif token[:1] in "rR":
            raise NotImplementedError("real VCD values need a separate numeric oracle")
        elif token[:1] in "01xXzZ":
            bits, code = token[0], token[1:]
            if not code:
                raise VcdError("scalar value must touch its identifier code")
        elif token.startswith("p"):
            raise NotImplementedError("extended VCD is outside this four-state oracle")
        else:
            raise VcdError(f"unexpected value token {token!r}")
        if code not in codes:
            raise VcdError(f"undeclared identifier code {code!r}")
        results = []
        for name in codes[code]:
            kind, width = variables[name]
            if kind in ("event", "real", "realtime"):
                raise NotImplementedError(f"{kind} needs a separate value oracle")
            if token[:1] not in "bB" and width != 1:
                raise VcdError("scalar record for a vector declaration")
            if len(bits) > width:
                raise VcdError("value wider than declaration")
            normalized = bits.lower()
            if (token[:1] in "bB" and len(normalized) > 1
                    and ((normalized[0] == "0" and normalized[1] in "01")
                         or normalized[:2] in ("xx", "zz"))):
                raise VcdError("vector value is not in shortest form")
            extension = normalized[0] if normalized[0] in "xz" else "0"
            expanded = extension * (width - len(normalized)) + normalized
            results.append((name, expanded))
        return results

    while cursor < len(tokens):
        token = take()
        if token in ("$date", "$version", "$comment"):
            if in_body and token != "$comment":
                raise VcdError("header metadata after enddefinitions")
            metadata.append((time if in_body else None, token,
                             " ".join(command_body())))
        elif token == "$timescale":
            if in_body or timescale is not None:
                raise VcdError("misplaced or duplicate timescale")
            match = re.fullmatch(r"(1|10|100)(s|ms|us|ns|ps|fs)",
                                 "".join(command_body()))
            if not match:
                raise VcdError("invalid timescale")
            timescale = (int(match[1]), match[2])
        elif token == "$scope":
            body = command_body()
            if in_body or len(body) != 2:
                raise VcdError("invalid scope declaration")
            if body[0] not in ("module", "task", "function", "begin", "fork"):
                raise VcdError("invalid four-state scope type")
            scopes.append(tuple(body))
        elif token == "$upscope":
            if in_body or command_body() or not scopes:
                raise VcdError("unbalanced upscope")
            scopes.pop()
        elif token == "$var":
            kind, width_text, code = take(), take(), take()
            reference_tokens = command_body()
            if in_body or not reference_tokens:
                raise VcdError("invalid variable declaration")
            if kind == "port":
                raise NotImplementedError("extended VCD declarations are unsupported")
            if kind not in ("event", "integer", "parameter", "real", "realtime",
                            "reg", "supply0", "supply1", "time", "tri", "triand",
                            "trior", "trireg", "tri0", "tri1", "wand", "wire", "wor"):
                raise VcdError("invalid four-state variable type")
            if not width_text.isdecimal() or int(width_text) < 1:
                raise VcdError("invalid variable width")
            if not code or any(not 33 <= ord(c) <= 126 for c in code):
                raise VcdError("identifier code is not printable ASCII")
            # Keep scope TYPE as well as name. Join optional index spacing, but
            # do not case-fold names or arbitrary identifier codes.
            reference = "".join(reference_tokens)
            name = (tuple(scopes), reference)
            if name in variables:
                raise VcdError("duplicate reference declaration")
            width = int(width_text)
            if any(variables[alias][1] != width for alias in codes[code]):
                raise VcdError("aliased identifier codes have conflicting widths")
            variables[name] = (kind, width)
            codes[code].append(name)
        elif token == "$enddefinitions":
            if in_body or command_body() or timescale is None:
                raise VcdError("invalid enddefinitions")
            in_body = True
        elif token.startswith("#"):
            if not in_body:
                raise VcdError("timestamp before enddefinitions")
            timestamp = token[1:] or take()
            if not timestamp.isdecimal() or int(timestamp) < time:
                raise VcdError("invalid or decreasing timestamp")
            if int(timestamp) != time:
                flush_changes()
                time = int(timestamp)
        elif token in ("$dumpvars", "$dumpoff", "$dumpon", "$dumpall"):
            if not in_body:
                raise VcdError("checkpoint before enddefinitions")
            flush_changes()
            values = {}
            while (value := take()) != "$end":
                for name, bits in value_change(value):
                    if name in values:
                        raise VcdError("duplicate checkpoint value")
                    values[name] = bits
            events.append((time, token, tuple(sorted(values.items()))))
        else:
            if not in_body:
                raise VcdError(f"unexpected declaration {token!r}")
            for name, bits in value_change(token):
                pending[name].append(bits)
    if not in_body:
        raise VcdError("missing enddefinitions")
    flush_changes()
    return Vcd(timescale, variables, events, metadata)


def compare_artifacts(actual_text, reference_text, *, dumpfile_text=None,
                      comment_text=None):
    """Compare bounded semantics and independently check actual metadata.

    dumpfile_text is the task/expression spelling required by the test source,
    not a fabricated writer version. comment_text is an implementation-specific
    diagnostic substring; select it explicitly for a limit-marker test.
    Reference snapshots may intentionally omit nondeterministic metadata.
    """
    actual, reference = parse_vcd(actual_text), parse_vcd(reference_text)
    actual.require_metadata()
    if dumpfile_text is not None and not any(
            dumpfile_text in text for text in actual.metadata_text("$version")):
        raise VcdError("missing required dumpfile task/expression in version")
    if comment_text is not None and not any(
            comment_text in text for text in actual.metadata_text("$comment")):
        raise VcdError("missing required comment marker")
    if actual.semantic_projection() != reference.semantic_projection():
        raise VcdError("VCD semantic artifact mismatch")
    return actual
