#!/usr/bin/env python3

import argparse
import gzip
import json
import shutil
import sqlite3
import sys
from pathlib import Path
from xml.sax.saxutils import escape


DEFAULT_DB_PATH = Path("mounts/pinchflat/db/pinchflat.db")
DEFAULT_METADATA_ROOT = Path("mounts/pinchflat/metadata")
DEFAULT_DOWNLOADS_ROOT = Path("/Volumes/Plex-Storage/media/youtube")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Backfill Plex-style show metadata/art from Pinchflat source metadata."
    )
    selector = parser.add_mutually_exclusive_group(required=True)
    selector.add_argument("--source-id", type=int, help="Pinchflat source ID")
    selector.add_argument("--source-name", help="Pinchflat source custom_name")
    parser.add_argument("--db-path", type=Path, default=DEFAULT_DB_PATH)
    parser.add_argument("--metadata-root", type=Path, default=DEFAULT_METADATA_ROOT)
    parser.add_argument("--downloads-root", type=Path, default=DEFAULT_DOWNLOADS_ROOT)
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def load_source_row(conn: sqlite3.Connection, args: argparse.Namespace) -> sqlite3.Row:
    where = "s.id = ?" if args.source_id is not None else "s.custom_name = ?"
    value = args.source_id if args.source_id is not None else args.source_name
    query = f"""
        SELECT
          s.id,
          s.custom_name,
          s.collection_id,
          s.collection_name,
          s.description,
          sm.metadata_filepath,
          sm.poster_filepath,
          sm.fanart_filepath,
          sm.banner_filepath
        FROM sources s
        LEFT JOIN source_metadata sm ON sm.source_id = s.id
        WHERE {where}
    """
    row = conn.execute(query, (value,)).fetchone()
    if row is None:
        raise SystemExit(f"Source not found for selector: {value!r}")
    return row


def to_local_metadata_path(metadata_root: Path, pinchflat_path: str | None) -> Path | None:
    if not pinchflat_path:
        return None
    prefix = "/config/metadata/"
    if not pinchflat_path.startswith(prefix):
        return None
    return metadata_root / pinchflat_path[len(prefix) :]


def load_source_metadata(metadata_path: Path) -> dict:
    with gzip.open(metadata_path, "rt", encoding="utf-8") as handle:
        return json.load(handle)


def build_tvshow_nfo(source_row: sqlite3.Row, source_metadata: dict) -> str:
    title = source_metadata.get("title") or source_row["collection_name"] or source_row["custom_name"]
    plot = source_metadata.get("description") or source_row["description"] or ""
    uniqueid = (
        source_metadata.get("uploader_id")
        or source_metadata.get("channel_id")
        or source_metadata.get("id")
        or source_row["collection_id"]
        or ""
    )
    lines = [
        '<?xml version="1.0" encoding="UTF-8" standalone="yes" ?>',
        "<tvshow>",
        f"  <title>{escape(str(title))}</title>",
        f"  <plot>{escape(str(plot))}</plot>",
    ]
    if uniqueid:
        lines.append(f'  <uniqueid type="youtube" default="true">{escape(str(uniqueid))}</uniqueid>')
    lines.append("  <genre>YouTube</genre>")
    lines.append("</tvshow>")
    lines.append("")
    return "\n".join(lines)


def ensure_file(path: Path, contents: str, dry_run: bool) -> None:
    print(f"write {path}")
    if dry_run:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(contents, encoding="utf-8")


def copy_if_present(src: Path | None, dst: Path, dry_run: bool) -> None:
    if src is None or not src.exists():
        return
    print(f"copy  {src} -> {dst}")
    if dry_run:
        return
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)


def main() -> int:
    args = parse_args()

    conn = sqlite3.connect(args.db_path)
    conn.row_factory = sqlite3.Row
    try:
        source_row = load_source_row(conn, args)
    finally:
        conn.close()

    metadata_path = to_local_metadata_path(args.metadata_root, source_row["metadata_filepath"])
    if metadata_path is None or not metadata_path.exists():
        raise SystemExit("Source metadata JSON is missing; cannot generate tvshow.nfo")

    source_metadata = load_source_metadata(metadata_path)
    show_dir = args.downloads_root / "shows" / source_row["custom_name"]

    ensure_file(show_dir / "tvshow.nfo", build_tvshow_nfo(source_row, source_metadata), args.dry_run)
    copy_if_present(
        to_local_metadata_path(args.metadata_root, source_row["poster_filepath"]),
        show_dir / "poster.jpg",
        args.dry_run,
    )
    copy_if_present(
        to_local_metadata_path(args.metadata_root, source_row["fanart_filepath"]),
        show_dir / "fanart.jpg",
        args.dry_run,
    )
    copy_if_present(
        to_local_metadata_path(args.metadata_root, source_row["banner_filepath"]),
        show_dir / "banner.jpg",
        args.dry_run,
    )

    return 0


if __name__ == "__main__":
    sys.exit(main())
