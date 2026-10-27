"""Write docs/api.html from the package's interface file and the `///` comments in
its sources. Run from the repository root:

    python scripts/gen_api.py

The output is committed; the docs workflow regenerates it and fails when the
result differs from what is in the tree.
"""

import html
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
PKG = "moonpool"
ROUTE = "moonbitstack/moonpool"
INTRO = (
    "A pool of resources with no I/O of its own: it says which resource to hand out, "
    "whether to make another, which to let go, and when to refuse, and leaves the acting "
    "to the caller."
)

DECL = re.compile(
    r"^(?:pub(?:\((?:all|open)\))?\s+)?(?:\[T\]\s+)?"
    r"(fn|let|struct|enum|suberror|trait|type)\s+"
    r"([A-Za-z_]\w*(?:::[A-Za-z_]\w*)?)"
)
TRAIT_METHODS = re.compile(
    r"::(equal|not_equal|output|to_string|to_repr|hash|hash_combine|compare)\("
)


def docs_of(folder):
    """Doc comments by declared name, and inline `//` notes by `Enum.Variant`."""
    out = {}
    for path in sorted((ROOT / folder).glob("*.mbt")):
        if path.name.endswith("_test.mbt"):
            continue
        lines = path.read_text(encoding="utf-8").splitlines()
        pending, owner = [], None
        for line in lines:
            stripped = line.strip()
            if stripped == "///|":
                pending = []
                continue
            if stripped.startswith("///"):
                pending.append(stripped[3:].strip())
                continue
            m = DECL.match(line)
            if m:
                if pending:
                    out[m.group(2)] = " ".join(p for p in pending if p)
                owner = (
                    m.group(2)
                    if m.group(1) == "enum" and line.rstrip().endswith("{")
                    else None
                )
                pending = []
                continue
            if owner:
                if line.startswith("}"):
                    owner = None
                else:
                    v = re.match(r"\s+([A-Z]\w*)\s*(?://\s*(.*))?$", line)
                    if v and v.group(2):
                        out[owner + "." + v.group(1)] = v.group(2)
            pending = []
    return out


def items_of(folder):
    lines = (ROOT / folder / "pkg.generated.mbti").read_text(encoding="utf-8").splitlines()
    items, block = [], None
    for line in lines:
        if block is not None:
            if line.startswith("}"):
                items.append(block)
                block = None
            else:
                block["variants"].append(line.strip())
            continue
        m = re.match(r"pub(?:\((?:all|open)\))?\s+(enum|struct|suberror)\s+(\w+)", line)
        if m:
            block = {
                "kind": m.group(1),
                "name": m.group(2),
                "sig": line.rstrip(" {"),
                "variants": [],
            }
            if not line.rstrip().endswith("{"):
                items.append(block)
                block = None
            continue
        m = re.match(r"pub fn(?:\[T\])?\s+(\w+)::(\w+)", line)
        if m:
            items.append(
                {
                    "kind": "method",
                    "name": m.group(1) + "::" + m.group(2),
                    "sig": line,
                    "owner": m.group(1),
                }
            )
            continue
        m = re.match(r"pub fn(?:\[T\])?\s+(\w+)", line)
        if m:
            items.append({"kind": "fn", "name": m.group(1), "sig": line})
            continue
        m = re.match(r"pub let (\w+)", line)
        if m:
            items.append({"kind": "let", "name": m.group(1), "sig": line})
            continue
        m = re.match(r"pub using @\w+ \{type (\w+)\}", line)
        if m:
            items.append(
                {"kind": "alias", "name": m.group(1), "sig": "type " + m.group(1)}
            )
            continue
        m = re.match(r"type (\w+)\[T\]", line)
        if m:
            items.append(
                {
                    "kind": "opaque",
                    "name": m.group(1),
                    "sig": "type " + m.group(1) + "[T]",
                }
            )
            continue
        m = re.match(r"pub impl (\w+) for (\w+)", line)
        if m:
            items.append(
                {"kind": "impl", "name": m.group(1), "sig": line, "owner": m.group(2)}
            )
    return items


def prose(text):
    if not text:
        return ""
    # `[`name`]` is a cross-reference in the source; here the name is the link.
    text = re.sub(r"\[`([^`]+)`\]", lambda m: m.group(1), text)
    text = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", html.escape(text, quote=False))
    return f"<p>{text}</p>"


def sig(text):
    return f'<pre class="sig">{html.escape(text.strip(), quote=False)}</pre>'


def anchor(name):
    return f"pool-{name}".replace("::", "-")


def render():
    docs = docs_of(".")
    items = items_of(".")
    entries = [
        i for i in items if i["kind"] != "impl" and not TRAIT_METHODS.search(i["sig"])
    ]
    types = [i for i in entries if i["kind"] in ("enum", "struct", "suberror", "opaque")]
    values = sorted([i for i in entries if i["kind"] == "let"], key=lambda x: x["name"])
    fns = sorted([i for i in entries if i["kind"] == "fn"], key=lambda x: x["name"])
    aliases = sorted([i for i in entries if i["kind"] == "alias"], key=lambda x: x["name"])
    methods = {}
    for i in entries:
        if i["kind"] == "method":
            methods.setdefault(i["owner"], []).append(i)
    for k in methods:
        methods[k].sort(key=lambda x: x["name"])

    nav, body = [], []
    nav.append('<h4>Values</h4><ol>')
    for v in values:
        nav.append(f'<li><a href="#{anchor(v["name"])}">{v["name"]}</a></li>')
    nav.append("</ol>")
    nav.append('<h4>Types</h4><ol>')
    for t in types:
        nav.append(f'<li><a href="#{anchor(t["name"])}">{t["name"]}</a><ol class="sub">')
        for m in methods.get(t["name"], []):
            nav.append(f'<li><a href="#{anchor(m["name"])}">{m["name"].split("::")[1]}</a></li>')
        nav.append("</ol></li>")
    nav.append("</ol>")
    if fns:
        nav.append('<h4>Functions</h4><ol>')
        for f in fns:
            nav.append(f'<li><a href="#{anchor(f["name"])}">{f["name"]}</a></li>')
        nav.append("</ol>")
    if aliases:
        nav.append('<h4>Re-exported</h4><ol>')
        for a in aliases:
            nav.append(f'<li><a href="#{anchor(a["name"])}">{a["name"]}</a></li>')
        nav.append("</ol>")

    body.append(f'<section class="band" id="{anchor("top")}">')
    body.append(
        f'<div class="band-head"><h2>{PKG}</h2><span class="route">{ROUTE}</span></div>'
    )
    body.append(prose(INTRO))

    body.append('<h4 class="group">Values</h4>')
    for v in values:
        body.append(f'<div class="entry" id="{anchor(v["name"])}">')
        body.append(f'<h3><span class="kind">let</span>{v["name"]}</h3>')
        body.append(prose(docs.get(v["name"], "")))
        body.append(sig(v["sig"]))
        body.append("</div>")

    body.append('<h4 class="group">Types</h4>')
    for t in types:
        body.append(f'<div class="entry" id="{anchor(t["name"])}">')
        badge = "error" if t["kind"] == "suberror" else t["kind"]
        cls = "kind" + (" ty" if t["kind"] in ("enum", "struct") else " er")
        body.append(f'<h3><span class="{cls}">{badge}</span>{t["name"]}</h3>')
        body.append(prose(docs.get(t["name"], "")))
        if t.get("variants"):
            body.append(sig(t["sig"] + " {"))
            chips = []
            for v in t["variants"]:
                note = docs.get(f'{t["name"]}.{v}', "")
                chips.append(
                    "<li>"
                    + html.escape(v)
                    + (f"<small>{html.escape(note)}</small>" if note else "")
                    + "</li>"
                )
            body.append(f'<ul class="variants">{"".join(chips)}</ul>')
        else:
            body.append(sig(t["sig"]))
        body.append("</div>")
        for m in methods.get(t["name"], []):
            short = m["name"].split("::")[1]
            body.append(f'<div class="entry" id="{anchor(m["name"])}">')
            body.append(f'<h3><span class="kind">fn</span>{t["name"]}::{short}</h3>')
            body.append(prose(docs.get(m["name"], "")))
            body.append(sig(m["sig"]))
            body.append("</div>")

    if fns:
        body.append('<h4 class="group">Functions</h4>')
        for f in fns:
            body.append(f'<div class="entry" id="{anchor(f["name"])}">')
            body.append(f'<h3><span class="kind">fn</span>{f["name"]}</h3>')
            body.append(prose(docs.get(f["name"], "")))
            body.append(sig(f["sig"]))
            body.append("</div>")

    if aliases:
        body.append('<h4 class="group">Re-exported</h4>')
        for a in aliases:
            body.append(f'<div class="entry" id="{anchor(a["name"])}">')
            body.append(f'<h3><span class="kind ty">type</span>{a["name"]}</h3>')
            body.append(
                prose("An alias of a type the ward's parts are made of, so a pool can be "
                      "described without naming where each part lives.")
            )
            body.append(sig(a["sig"]))
            body.append("</div>")
    body.append("</section>")

    total = len(values) + len(types) + len(fns) + len(aliases) + sum(
        len(v) for v in methods.values()
    )
    page = (ROOT / "docs" / "api.template.html").read_text(encoding="utf-8")
    page = (
        page.replace("<!-- nav -->", "\n".join(nav))
        .replace("<!-- body -->", "\n".join(body))
        .replace("<!-- count -->", f"1 package · {total} public items")
    )
    (ROOT / "docs" / "api.html").write_text(page, encoding="utf-8", newline="\n")
    print(f"docs/api.html: {total} public items")


render()
