#!/usr/bin/env python3
# =============================================================================
# Put the tracked Custom CSS into Jellyfin's branding config
# -----------------------------------------------------------------------------
# RUNS ON THE SERVER, from an ExecStartPre= on jellyfin.container, before the
# container starts. Jellyfin reads branding.xml at startup, so writing it here
# is what makes the CSS take effect without an API call or a login.
#
# WHY THIS EXISTS. The Custom CSS box in Jellyfin's dashboard is real
# configuration - it is what the whole UI looks like - and it lived only in
# config/jellyfin/branding.xml, which is gitignored runtime state. It was not in
# git, so a `git grep` did not find it, and a restore from a backup taken before
# it was set would have silently reverted the theme. Same class of problem as
# Tdarr's plugin and Sonarr's scripts, and the same answer: track the file, copy
# it in on every start, let git be authoritative.
#
# THE COST, WHICH IS REAL: an edit made in Jellyfin's UI survives only until the
# next restart, and podman-auto-update restarts Jellyfin nightly. So a change
# made in the browser will look like it worked and quietly revert overnight.
# Edit apps/jellyfin/custom.css instead.
#
# IT REPLACES ONE ELEMENT, NOT THE FILE. LoginDisclaimer and SplashscreenEnabled
# live in the same document and are genuinely the UI's to own, so the document is
# parsed and only CustomCss is touched. Writing a fresh two-element file here
# would silently turn the splash screen off.
#
# The quadlet calls it with a leading `-`, so a failure cannot stop Jellyfin.
# This is cosmetics; it must never be able to take the media server down.
#
# Usage:  bin/render-jellyfin-branding.py [--dry-run]
# =============================================================================

import os
import sys
import xml.etree.ElementTree as ET

CSS = os.environ.get(
    "JELLYFIN_CUSTOM_CSS", "/var/media-stack/apps/jellyfin/custom.css"
)
BRANDING = os.environ.get(
    "JELLYFIN_BRANDING",
    os.path.join(
        os.environ.get("DOCKER_VOLUME_CONFIG", "/var/media-stack/config"),
        "jellyfin",
        "branding.xml",
    ),
)
DRY = "--dry-run" in sys.argv

# The XML declaration Jellyfin itself writes. ElementTree's own is single-quoted
# and omits standalone, which would rewrite the first line on every start and
# make every diff of this file noise.
DECL = '<?xml version="1.0" encoding="utf-8"?>'
NS = {
    "xmlns:xsi": "http://www.w3.org/2001/XMLSchema-instance",
    "xmlns:xsd": "http://www.w3.org/2001/XMLSchema",
}


def log(msg):
    print("render-jellyfin-branding: %s" % msg, file=sys.stderr)


def main():
    if not os.path.exists(CSS):
        # Not an error worth failing on: no tracked CSS means leave whatever the
        # UI has alone. Failing here would be a cosmetic file blocking a start.
        log("no %s - leaving %s untouched" % (CSS, BRANDING))
        return 0

    with open(CSS, encoding="utf-8") as fh:
        # One trailing newline is a property of a text file, not of the CSS.
        # Stripping it keeps the element byte-identical to what the UI stores,
        # so this does not rewrite branding.xml on every single start.
        css = fh.read().rstrip("\n")

    if os.path.exists(BRANDING):
        try:
            tree = ET.parse(BRANDING)
            root = tree.getroot()
        except ET.ParseError as exc:
            # A corrupt branding.xml is Jellyfin's to regenerate. Rewriting it
            # from here could destroy a LoginDisclaimer nobody has in git.
            log("%s is not parseable (%s) - leaving it alone" % (BRANDING, exc))
            return 1
    else:
        root = ET.Element("BrandingOptions")
        ET.SubElement(root, "LoginDisclaimer")
        ET.SubElement(root, "SplashscreenEnabled").text = "false"
        tree = ET.ElementTree(root)
        log("no %s yet - creating it" % BRANDING)

    # ElementTree treats xmlns:* on a parsed root as namespace declarations and
    # drops them when serialising, so a round-trip would quietly strip the two
    # .NET puts there. Setting them back as plain attributes is what keeps this
    # file in the shape Jellyfin writes, rather than one it merely tolerates.
    for key, value in NS.items():
        root.set(key, value)

    node = root.find("CustomCss")
    if node is None:
        node = ET.SubElement(root, "CustomCss")

    if node.text == css:
        log("already current (%d bytes)" % len(css))
        return 0

    node.text = css

    if DRY:
        log("would write %d bytes of CSS to %s" % (len(css), BRANDING))
        return 0

    # Two-space indentation, matching what .NET writes, so that a hand-inspected
    # diff of this file shows the CSS changing and nothing else.
    ET.indent(tree, space="  ")
    # ET.tostring escapes &, < and > in element text, which is what makes a CSS
    # child selector (`.a > .b`) safe to embed. Do not hand-build this document.
    body = ET.tostring(root, encoding="unicode")
    tmp = BRANDING + ".tmp"
    os.makedirs(os.path.dirname(BRANDING), exist_ok=True)
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(DECL + "\n" + body)
    # Atomic, so a crash mid-write cannot leave Jellyfin a truncated document to
    # start against.
    os.replace(tmp, BRANDING)
    log("wrote %d bytes of CSS to %s" % (len(css), BRANDING))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # noqa: BLE001 - never take Jellyfin down
        log("failed: %s" % exc)
        sys.exit(1)
