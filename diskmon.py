#!/usr/bin/env -S /nix/store/qd7fbw1h6xa5zj91cnzvd5nz366435qw-uv-0.9.26/bin/uv run --script
# /// script
# dependencies = ["psutil", "rich"]
# ///

import fcntl
import os
import subprocess
import threading
import time
from dataclasses import dataclass, field

import psutil
from rich.console import Console
from rich.live import Live
from rich.table import Table
from rich.text import Text

VOLUMES = ["/Volumes/Plex-Storage", "/Volumes/Working-Storage"]
INTERVAL = 1.0       # seconds between live updates
BENCH_SIZE = 512     # MB to write/read during benchmark
CHUNK_SIZE = 1 << 20 # 1 MB chunks

# macOS fcntl flag to bypass page cache on reads (equivalent to O_DIRECT on Linux)
F_NOCACHE = 48


@dataclass
class BenchResult:
    read_mbs: float | None = None   # None = still running
    write_mbs: float | None = None


def diskutil_info(target: str) -> dict:
    try:
        out = subprocess.check_output(
            ["diskutil", "info", target],
            text=True,
            stderr=subprocess.DEVNULL,
        )
        result = {}
        for line in out.splitlines():
            if ":" in line:
                key, _, val = line.partition(":")
                result[key.strip()] = val.strip()
        return result
    except (subprocess.CalledProcessError, FileNotFoundError):
        return {}


def get_disk_device(mount_point: str) -> str | None:
    """Map a mount point to its physical disk name as tracked by psutil (e.g. 'disk4').

    macOS APFS layer:
      /Volumes/Plex-Storage  (APFS volume, disk5s1)
        → container: disk5  (APFS container)
          → physical store: disk4s1  (partition on physical disk)
            → physical disk: disk4   ← what psutil tracks
    """
    info = diskutil_info(mount_point)
    container = info.get("Part of Whole")
    if not container:
        return None

    container_info = diskutil_info(container)
    physical_store = container_info.get("APFS Physical Store")
    if not physical_store:
        return container

    dev = physical_store
    while dev and dev[-1].isdigit():
        dev = dev[:-1]
    if dev.endswith("s"):
        dev = dev[:-1]
    return dev


def benchmark_drive(mount_point: str, result: BenchResult) -> None:
    """Write then read BENCH_SIZE MB on the given volume, storing MB/s into result.

    Both write and read use F_NOCACHE so neither operation touches the page cache.
    This is the only reliable way to get real disk speeds on macOS without sudo purge.
    """
    chunk = b"\x00" * CHUNK_SIZE
    total_bytes = BENCH_SIZE * CHUNK_SIZE
    tmp_path = os.path.join(mount_point, ".diskmon_bench.tmp")
    try:
        # --- Write benchmark (F_NOCACHE = write bypasses page cache) ---
        t0 = time.monotonic()
        with open(tmp_path, "wb", buffering=0) as f:
            fcntl.fcntl(f.fileno(), F_NOCACHE, 1)
            for _ in range(BENCH_SIZE):
                f.write(chunk)
        result.write_mbs = total_bytes / (time.monotonic() - t0) / 1_048_576

        # --- Read benchmark (F_NOCACHE = read bypasses page cache) ---
        # Since the write never populated the cache, the read must come from disk.
        t0 = time.monotonic()
        with open(tmp_path, "rb") as f:
            fcntl.fcntl(f.fileno(), F_NOCACHE, 1)
            while f.read(CHUNK_SIZE):
                pass
        result.read_mbs = total_bytes / (time.monotonic() - t0) / 1_048_576

    except OSError:
        result.read_mbs = -1.0
        result.write_mbs = -1.0
    finally:
        try:
            os.remove(tmp_path)
        except OSError:
            pass


def start_benchmarks(volumes: list[str]) -> dict[str, BenchResult]:
    """Kick off one benchmark thread per volume, return results dict."""
    results = {v: BenchResult() for v in volumes}
    for vol in volumes:
        t = threading.Thread(target=benchmark_drive, args=(vol, results[vol]), daemon=True)
        t.start()
    return results


def bench_label(result: BenchResult) -> str:
    """Return a compact benchmark summary string for the volume column."""
    if result.read_mbs is None or result.write_mbs is None:
        return "[dim]benchmarking…[/dim]"
    if result.read_mbs < 0:
        return "[red]bench failed[/red]"
    return (
        f"[dim]peak R:[/dim][cyan]{result.read_mbs:>5.0f} MB/s[/cyan]  "
        f"[dim]W:[/dim][cyan]{result.write_mbs:>5.0f} MB/s[/cyan]"
    )


def build_table(
    prev_counters: dict,
    curr_counters: dict,
    elapsed: float,
    bench_results: dict[str, BenchResult],
) -> Table:
    table = Table(
        show_header=True,
        header_style="bold white",
        border_style="bright_black",
        expand=True,
    )
    table.add_column("Volume", min_width=20)
    table.add_column("Peak Speeds", min_width=34)
    table.add_column("Read MB/s", justify="right", min_width=12)
    table.add_column("Write MB/s", justify="right", min_width=12)
    table.add_column("Used / Total", justify="right", min_width=24)

    for mount in VOLUMES:
        name = mount.split("/")[-1]
        disk = get_disk_device(mount)

        # Live IO speeds
        read_mbs = write_mbs = 0.0
        if disk and disk in curr_counters and disk in prev_counters:
            rb = curr_counters[disk].read_bytes - prev_counters[disk].read_bytes
            wb = curr_counters[disk].write_bytes - prev_counters[disk].write_bytes
            read_mbs = max(rb / elapsed / 1_048_576, 0)
            write_mbs = max(wb / elapsed / 1_048_576, 0)

        # Disk usage
        try:
            usage = psutil.disk_usage(mount)
            used_gb = usage.used / 1_073_741_824
            total_gb = usage.total / 1_073_741_824
            usage_str = f"{used_gb:,.1f} / {total_gb:,.1f} GB ({usage.percent:.1f}%)"
        except OSError:
            usage_str = "unavailable"

        def speed_color(mbs: float) -> Text:
            if mbs >= 100:
                color = "bright_red"
            elif mbs >= 50:
                color = "yellow"
            elif mbs >= 5:
                color = "green"
            else:
                color = "white"
            return Text(f"{mbs:>8.1f}", style=color)

        table.add_row(
            f"[bold cyan]{name}[/bold cyan]",
            bench_label(bench_results[mount]),
            speed_color(read_mbs),
            speed_color(write_mbs),
            usage_str,
        )

    return table


def main():
    console = Console()
    bench_results = start_benchmarks(VOLUMES)

    prev = psutil.disk_io_counters(perdisk=True)
    prev_time = time.monotonic()

    try:
        with Live(console=console, refresh_per_second=2, screen=False) as live:
            while True:
                time.sleep(INTERVAL)
                curr = psutil.disk_io_counters(perdisk=True)
                curr_time = time.monotonic()

                table = build_table(prev, curr, curr_time - prev_time, bench_results)
                live.update(table)

                prev = curr
                prev_time = curr_time
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
