#!/usr/bin/env python3
# =============================================================================
# Put the tracked encoding decisions into Jellyfin's encoding config
# -----------------------------------------------------------------------------
# RUNS ON THE SERVER, from an ExecStartPre= on jellyfin.container, before the
# container starts. Jellyfin reads encoding.xml at startup.
#
# WHY THIS EXISTS. config/jellyfin/encoding.xml holds real decisions - which
# codecs decode in hardware, which extensions get a keyframe-accurate HLS
# playlist, whether transcodes throttle - and it was gitignored runtime state,
# so a `git grep` did not find any of it and a restore brought back whatever
# happened to be in the snapshot. CLAUDE.md has named that gap for a while. The
# Backrooms subtitle-drift investigation is what made it concrete: the diagnosis
# turned on AllowOnDemandMetadataBasedKeyframeExtractionForExtensions containing
# "mkv", a setting that existed nowhere anybody could review it.
#
# IT WRITES ONLY THE ELEMENTS NAMED IN apps/jellyfin/encoding.conf, AND IT NEVER
# CREATES THE FILE. encoding.xml has about fifty elements - tonemapping, VAAPI
# devices, CRF targets, deinterlacing - and they are genuinely Jellyfin's to
# own. Authoring a fresh document from a handful of tracked keys would silently
# reset every one of them to whatever ElementTree left out. Same argument as
# render-jellyfin-branding.py touching only CustomCss, one step further: if
# there is no document, there is nothing to edit, and that is not an error.
#
# LIST ELEMENTS ARE DECLARED WITH [], NOT DETECTED. HardwareDecodingCodecs holds
# <string> children; EnableThrottling holds text. Inferring that from the
# document is tempting and wrong: an emptied list is written `<Foo />`, which has
# no children and so is indistinguishable from a scalar - and that is precisely
# the state this script exists to repair. Tried it, watched it write
# `<AllowOnDemand...>mkv</AllowOnDemand...>` where <string>mkv</string> belonged,
# which Jellyfin reads as an empty list. So the shape is stated in the conf file.
#
# The quadlet calls it with a leading `-`, so a failure cannot stop Jellyfin.
#
# Usage:  bin/render-jellyfin-encoding.py [--dry-run]
# =============================================================================

import os
import sys
import xml.etree.ElementTree as ET

# Derived from this file's own location rather than hardcoded, for the reason
# render-jellyfin-branding.py gives: a stale literal here fails every start.
REPO = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))

CONF = os.environ.get(
    "JELLYFIN_ENCODING_CONF", os.path.join(REPO, "apps", "jellyfin", "encoding.conf")
)
ENCODING = os.environ.get(
    "JELLYFIN_ENCODING",
    os.path.join(
        os.environ.get("DOCKER_VOLUME_CONFIG", os.path.join(REPO, "config")),
        "jellyfin",
        "encoding.xml",
    ),
)
DRY = "--dry-run" in sys.argv

# The declaration and namespace attributes .NET writes. See render-jellyfin-branding.py:
# ElementTree would otherwise rewrite the first line and drop the two xmlns
# attributes on every start, making every diff of this file noise.
DECL = '<?xml version="1.0" encoding="utf-8"?>'
NS = {
    "xmlns:xsi": "http://www.w3.org/2001/XMLSchema-instance",
    "xmlns:xsd": "http://www.w3.org/2001/XMLSchema",
}


def log(msg):
    print("render-jellyfin-encoding: %s" % msg, file=sys.stderr)


def read_conf(path):
    """Element = value, or Element[] = a,b,c for a list of <string> children.

    Order is preserved so the log names things in the order they are written.
    """
    wanted = []
    with open(path, encoding="utf-8") as fh:
        for lineno, raw in enumerate(fh, 1):
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            if "=" not in line:
                log("%s:%d: no '=' in %r - ignored" % (path, lineno, line))
                continue
            key, value = line.split("=", 1)
            key, value = key.strip(), value.strip()
            is_list = key.endswith("[]")
            if is_list:
                key = key[:-2].strip()
            if not key:
                log("%s:%d: empty element name - ignored" % (path, lineno))
                continue
            wanted.append((key, value, is_list))
    return wanted


def apply_value(node, value, is_list):
    """Return True if the document changed."""
    children = list(node)

    if children and not is_list:
        # The document says list, the conf says scalar. Writing text here would
        # drop every child, so refuse and let the mismatch be visible.
        log("%s has <string> children - declare it as %s[] - skipped" % (node.tag, node.tag))
        return False

    if is_list:
        # Compare before rewriting, so an unchanged document is left
        # byte-identical and this does not rewrite encoding.xml on every start.
        current = [(c.text or "").strip() for c in children]
        desired = [v.strip() for v in value.split(",") if v.strip()]
        if current == desired and (children or not desired):
            return False
        for child in children:
            node.remove(child)
        node.text = None
        for item in desired:
            ET.SubElement(node, "string").text = item
        return True

    desired = value if value != "" else None
    if (node.text or None) == desired:
        return False
    node.text = desired
    return True


def main():
    if not os.path.exists(CONF):
        log("no %s - leaving %s untouched" % (CONF, ENCODING))
        return 0

    if not os.path.exists(ENCODING):
        # Jellyfin writes this on first run. Creating it here from a handful of
        # tracked keys would define the whole document by omission.
        log("no %s yet - Jellyfin will write it; nothing to edit" % ENCODING)
        return 0

    try:
        tree = ET.parse(ENCODING)
        root = tree.getroot()
    except ET.ParseError as exc:
        log("%s is not parseable (%s) - leaving it alone" % (ENCODING, exc))
        return 1

    for key, value in NS.items():
        root.set(key, value)

    changed = []
    missing = []
    for key, value, is_list in read_conf(CONF):
        node = root.find(key)
        if node is None:
            # Deliberately not created. An element Jellyfin does not know is one
            # this version has renamed or dropped, and inventing it hides that.
            missing.append(key)
            continue
        if apply_value(node, value, is_list):
            changed.append(key)

    for key in missing:
        log("%s is not an element of %s - skipped, check the spelling" % (key, ENCODING))

    if not changed:
        log("already current")
        return 0 if not missing else 1

    if DRY:
        log("would set: %s" % ", ".join(changed))
        return 0

    ET.indent(tree, space="  ")
    body = ET.tostring(root, encoding="unicode")
    tmp = ENCODING + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(DECL + "\n" + body)
    # Atomic, so a crash mid-write cannot leave Jellyfin a truncated document.
    os.replace(tmp, ENCODING)
    log("set: %s" % ", ".join(changed))
    return 0 if not missing else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # noqa: BLE001 - never take Jellyfin down
        log("failed: %s" % exc)
        sys.exit(1)
