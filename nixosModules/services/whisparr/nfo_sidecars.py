"""Write .nfo sidecars next to Whisparr's imported files.

Jellyfin's movie resolver renames a folder holding exactly one video after
the FOLDER, not the file: MovieResolver.FindMovie ends with
`movie.Name = Path.GetFileName(movie.ContainingFolderPath)` whenever the
collection type is `movies` and the folder resolved to a single item. A
studio folder holding one scene therefore enters the library as the studio
name, and whatever remote provider is enabled answers a query built from
that ("Scoop" -> the 2024 film).

A sidecar pins the title instead. The NFO reader is an ILocalMetadataProvider,
so RefreshWithProviders runs it before the remote providers, and both that
merge and ExecuteRemoteProviders' merge pass replaceData=False -- a field the
NFO filled cannot be overwritten downstream. MovieNfoSaver.GetMovieSavePaths
always yields `Path.ChangeExtension(item.Path, ".nfo")` as its last candidate,
so a same-stem sidecar is found whether or not the file sits alone in its
folder.

The title is Whisparr's own filename minus the parts Whisparr added:

    <date> - <studio> - <title> [<quality>].<ext>

The studio segment is taken from the parent directory name rather than parsed
out, because studio names contain " - " themselves ("FansDB - Emakarter1
(onlyfans)", "Pornhub - Danika Mori") and a non-greedy split cuts them in
half. A name that doesn't match the shape at all falls back to the stem,
which still beats the folder name.

Pure stdlib.
"""
import os
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

DATE_PREFIX = re.compile(r"^(\d{4}-\d{2}-\d{2}) - ")
QUALITY_SUFFIX = re.compile(r" \[[^\]]*\]$")

# Extensions we generate sidecars for. Orphan removal deliberately does NOT
# consult this list (see sweep), so an extension missing here costs nothing
# worse than a file without a sidecar.
VIDEO_EXTENSIONS = {
    "mp4", "mkv", "avi", "mov", "flv", "wmv", "m4v", "ts", "webm", "mpg",
    "mpeg", "m2ts",
}


def parse(path):
    """Return (title, premiered) for a video file; premiered may be None."""
    stem = path.stem
    studio = path.parent.name

    premiered = None
    match = DATE_PREFIX.match(stem)
    if match:
        premiered = match.group(1)
        stem = stem[match.end():]

    if stem.startswith(studio + " - "):
        stem = stem[len(studio) + 3:]

    title = QUALITY_SUFFIX.sub("", stem).strip()
    return title or path.stem, premiered


def nfo_bytes(title, premiered):
    movie = ET.Element("movie")
    ET.SubElement(movie, "title").text = title
    if premiered is not None:
        ET.SubElement(movie, "premiered").text = premiered
    ET.indent(movie, space="  ")
    return ET.tostring(movie, encoding="utf-8", xml_declaration=True) + b"\n"


def sweep(roots):
    written = 0
    removed = 0

    for root in roots:
        for dirpath, _dirnames, filenames in os.walk(root):
            names = set(filenames)

            for name in filenames:
                path = Path(dirpath) / name
                suffix = path.suffix.lower().lstrip(".")

                if suffix in VIDEO_EXTENSIONS:
                    title, premiered = parse(path)
                    wanted = nfo_bytes(title, premiered)
                    target = path.with_suffix(".nfo")
                    if not target.exists() or target.read_bytes() != wanted:
                        target.write_bytes(wanted)
                        written += 1

                elif suffix == "nfo":
                    # Whisparr renames the video on a metadata refresh but
                    # leaves the sidecar behind. Key the orphan test on "any
                    # sibling shares this stem" rather than on
                    # VIDEO_EXTENSIONS, so a container we don't generate for
                    # can never have its sidecar deleted out from under it.
                    stem = path.stem
                    if not any(
                        other != name and Path(other).stem == stem
                        for other in names
                    ):
                        path.unlink()
                        removed += 1

    return written, removed


def main(argv):
    if len(argv) < 2:
        print("usage: whisparr-nfo-sidecars <root> [root...]", file=sys.stderr)
        return 2

    written, removed = sweep([Path(root) for root in argv[1:]])
    print(f"nfo sidecars: {written} written, {removed} removed")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
