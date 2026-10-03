#!/usr/bin/env python3
"""Summarize finite energy profiles after excluding startup intervals."""
import argparse
import csv
import json
import math
from pathlib import Path
from statistics import mean, median


def summarize(path, warm_up):
    intervals = []
    previous_wall = 0.0
    with path.open(newline="") as stream:
        for record in csv.DictReader(stream):
            row = {key: float(value) for key, value in record.items()}
            if not all(math.isfinite(value) for value in row.values()):
                raise ValueError(f"Nonfinite measurement in {path.name}")
            wall = row["wall_seconds"]
            elapsed = wall - previous_wall
            if previous_wall >= warm_up and elapsed > 0 and row["draws"] > 0:
                row["elapsed"] = elapsed
                intervals.append(row)
            previous_wall = wall
    if len(intervals) < 2:
        raise ValueError(f"Need at least two drawing intervals after warm-up in {path.name}")
    elapsed = sum(row["elapsed"] for row in intervals)
    draws = sum(row["draws"] for row in intervals)
    edge_count = max(1, len(intervals) // 10)

    def memory_summary(key):
        values = [row[key] for row in intervals]
        times = [row["wall_seconds"] for row in intervals]
        average_time, average_value = mean(times), mean(values)
        variance = sum((time - average_time) ** 2 for time in times)
        slope = sum((time - average_time) * (value - average_value) for time, value in zip(times, values)) / variance
        return {
            "first_median_bytes": median(values[:edge_count]),
            "last_median_bytes": median(values[-edge_count:]),
            "range_bytes": max(values) - min(values),
            "trend_bytes_per_hour": round(slope * 3600, 2),
        }

    return {
        "file": str(path),
        "measured_wall_seconds": round(elapsed, 3),
        "final_simulation_seconds": intervals[-1]["simulation_seconds"],
        "draws_per_second": round(draws / elapsed, 3),
        "cpu_percent_of_one_core": round(sum(row["cpu_percent"] * row["elapsed"] for row in intervals) / elapsed, 3),
        "mean_draw_ms": round(sum(row["mean_draw_ms"] * row["draws"] for row in intervals) / draws, 4),
        "resident": memory_summary("resident_bytes"),
        "footprint": memory_summary("footprint_bytes"),
        "live_malloc": memory_summary("live_malloc_bytes"),
        "live_malloc_blocks_range": [min(row["live_malloc_blocks"] for row in intervals), max(row["live_malloc_blocks"] for row in intervals)],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("profiles", type=Path, nargs="+")
    parser.add_argument("--warm-up", type=float, default=10, help="Exclude intervals beginning before this wall time")
    args = parser.parse_args()
    if not math.isfinite(args.warm_up) or args.warm_up < 0:
        parser.error("warm-up must be a finite nonnegative duration")
    try:
        print(json.dumps([summarize(path, args.warm_up) for path in args.profiles], indent=2))
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(1, f"Invalid profile: {error}\n")


if __name__ == "__main__":
    main()
