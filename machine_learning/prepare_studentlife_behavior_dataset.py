from __future__ import annotations

import csv
import json
import re
import argparse
from collections import Counter, defaultdict
from datetime import datetime
from pathlib import Path


BASE_DIR = Path(__file__).resolve().parent
DATA_DIR = BASE_DIR / "data" / "studentlifedataset"
OUTPUT_PATH = BASE_DIR / "processed" / "studentlife_behavior_dataset.csv"


PACKAGE_CATEGORY_KEYWORDS = {
    "academic": [
        "dartmouth",
        "piazza",
        "canvas",
        "blackboard",
        "moodle",
        "classroom",
        "education",
    ],
    "productivity": [
        "gmail",
        "calendar",
        "chrome",
        "browser",
        "docs",
        "drive",
        "dropbox",
        "evernote",
        "office",
        "word",
        "excel",
        "pdf",
    ],
    "communication": [
        "mail",
        "messag",
        "talk",
        "skype",
        "whatsapp",
        "phone",
        "contacts",
    ],
    "social": [
        "facebook",
        "twitter",
        "instagram",
        "snapchat",
        "tumblr",
    ],
    "entertainment": [
        "youtube",
        "netflix",
        "hulu",
        "spotify",
        "music",
        "game",
        "games",
        "pandora",
        "video",
    ],
    "utility": [
        "settings",
        "launcher",
        "systemui",
        "installer",
        "clock",
        "camera",
        "maps",
        "filemanager",
    ],
}


FIELDNAMES = [
    "user_id",
    "date",
    "hour",
    "day_of_week",
    "is_weekend",
    "is_night",
    "total_app_events",
    "unique_apps",
    "app_switches",
    "estimated_active_seconds",
    "academic_events",
    "productivity_events",
    "communication_events",
    "social_events",
    "entertainment_events",
    "utility_events",
    "unknown_events",
    "academic_ratio",
    "productivity_ratio",
    "communication_ratio",
    "social_ratio",
    "entertainment_ratio",
    "utility_ratio",
    "unknown_ratio",
    "has_calendar_event",
    "phone_lock_events",
    "locked_seconds",
    "activity_stationary_events",
    "activity_walking_events",
    "activity_running_events",
    "study_productivity",
    "stress_level",
    "sleep_hours",
    "behavior_risk_score",
    "behavior_label",
    "label_source",
]


def parse_uid(path: Path) -> str:
    match = re.search(r"u\d+", path.stem)
    return match.group(0) if match else "unknown"


def parse_epoch(value: object) -> datetime | None:
    try:
        raw = str(value).strip()
        if not raw:
            return None
        return datetime.fromtimestamp(float(raw))
    except (OSError, ValueError):
        return None


def hour_key(user_id: str, timestamp: datetime) -> tuple[str, str, int]:
    return (user_id, timestamp.strftime("%Y-%m-%d"), timestamp.hour)


def category_for_package(package_name: str) -> str:
    package = package_name.lower()
    for category, keywords in PACKAGE_CATEGORY_KEYWORDS.items():
        if any(keyword in package for keyword in keywords):
            return category
    return "unknown"


def empty_row(user_id: str, timestamp: datetime) -> dict[str, object]:
    return {
        "user_id": user_id,
        "date": timestamp.strftime("%Y-%m-%d"),
        "hour": timestamp.hour,
        "day_of_week": timestamp.weekday(),
        "is_weekend": int(timestamp.weekday() >= 5),
        "is_night": int(timestamp.hour >= 22 or timestamp.hour < 6),
        "total_app_events": 0,
        "unique_apps": 0,
        "app_switches": 0,
        "estimated_active_seconds": 0,
        "academic_events": 0,
        "productivity_events": 0,
        "communication_events": 0,
        "social_events": 0,
        "entertainment_events": 0,
        "utility_events": 0,
        "unknown_events": 0,
        "academic_ratio": 0.0,
        "productivity_ratio": 0.0,
        "communication_ratio": 0.0,
        "social_ratio": 0.0,
        "entertainment_ratio": 0.0,
        "utility_ratio": 0.0,
        "unknown_ratio": 0.0,
        "has_calendar_event": 0,
        "phone_lock_events": 0,
        "locked_seconds": 0,
        "activity_stationary_events": 0,
        "activity_walking_events": 0,
        "activity_running_events": 0,
        "study_productivity": "",
        "stress_level": "",
        "sleep_hours": "",
        "behavior_risk_score": 0.0,
        "behavior_label": "",
        "label_source": "",
        "_packages": set(),
        "_last_package": "",
        "_last_timestamp": None,
    }


def row_for(rows: dict[tuple[str, str, int], dict[str, object]], user_id: str, timestamp: datetime):
    key = hour_key(user_id, timestamp)
    if key not in rows:
        rows[key] = empty_row(user_id, timestamp)
    return rows[key]


def read_csv(path: Path):
    with path.open(newline="", encoding="utf-8") as file:
        yield from csv.DictReader(file)


def load_app_usage(rows: dict[tuple[str, str, int], dict[str, object]], row_stride: int) -> None:
    for path in sorted((DATA_DIR / "app_usage").glob("running_app_u*.csv")):
        user_id = parse_uid(path)
        previous_timestamp = None
        previous_package = ""

        for index, record in enumerate(read_csv(path)):
            if row_stride > 1 and index % row_stride != 0:
                continue

            timestamp = parse_epoch(record.get("timestamp"))
            if timestamp is None:
                continue
            package = (
                record.get("RUNNING_TASKS_topActivity_mPackage")
                or record.get("RUNNING_TASKS_baseActivity_mPackage")
                or ""
            ).strip()
            if not package:
                continue

            row = row_for(rows, user_id, timestamp)
            category = category_for_package(package)
            row["total_app_events"] = int(row["total_app_events"]) + 1
            row[f"{category}_events"] = int(row[f"{category}_events"]) + 1
            row["_packages"].add(package)

            last_package = str(row["_last_package"])
            if last_package and last_package != package:
                row["app_switches"] = int(row["app_switches"]) + 1
            row["_last_package"] = package

            if previous_timestamp is not None and previous_package:
                delta = int((timestamp - previous_timestamp).total_seconds())
                if 0 < delta <= 600:
                    previous_row = row_for(rows, user_id, previous_timestamp)
                    previous_row["estimated_active_seconds"] = (
                        int(previous_row["estimated_active_seconds"]) + min(delta, 300)
                    )

            previous_timestamp = timestamp
            previous_package = package


def load_calendar(rows: dict[tuple[str, str, int], dict[str, object]]) -> None:
    for path in sorted((DATA_DIR / "calendar").glob("calendar_u*.csv")):
        user_id = parse_uid(path)
        for record in read_csv(path):
            timestamp = parse_epoch(record.get("timestamp"))
            if timestamp is None:
                continue
            row_for(rows, user_id, timestamp)["has_calendar_event"] = 1


def load_phone_locks(rows: dict[tuple[str, str, int], dict[str, object]]) -> None:
    lock_dir = DATA_DIR / "sensing" / "phonelock"
    if not lock_dir.exists():
        return

    for path in sorted(lock_dir.glob("phonelock_u*.csv")):
        user_id = parse_uid(path)
        for record in read_csv(path):
            start = parse_epoch(record.get("start"))
            end = parse_epoch(record.get("end"))
            if start is None:
                continue

            row = row_for(rows, user_id, start)
            row["phone_lock_events"] = int(row["phone_lock_events"]) + 1
            if end is not None:
                seconds = max(0, min(int((end - start).total_seconds()), 12 * 60 * 60))
                row["locked_seconds"] = int(row["locked_seconds"]) + seconds


def load_activity(rows: dict[tuple[str, str, int], dict[str, object]]) -> None:
    activity_dir = DATA_DIR / "sensing" / "activity"
    if not activity_dir.exists():
        return

    for path in sorted(activity_dir.glob("activity_u*.csv")):
        user_id = parse_uid(path)
        for record in read_csv(path):
            timestamp = parse_epoch(record.get("timestamp"))
            if timestamp is None:
                continue

            inference = str(record.get(" activity inference") or record.get("activity inference") or "").strip()
            row = row_for(rows, user_id, timestamp)
            if inference == "0":
                row["activity_stationary_events"] = int(row["activity_stationary_events"]) + 1
            elif inference == "1":
                row["activity_walking_events"] = int(row["activity_walking_events"]) + 1
            elif inference == "2":
                row["activity_running_events"] = int(row["activity_running_events"]) + 1


def load_ema_numeric(folder_name: str, field_names: list[str]) -> dict[tuple[str, str, int], list[float]]:
    result = defaultdict(list)
    folder = DATA_DIR / "EMA" / "response" / folder_name
    if not folder.exists():
        return result

    for path in sorted(folder.glob("*.json")):
        user_id = parse_uid(path)
        try:
            records = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            continue

        for record in records if isinstance(records, list) else []:
            timestamp = parse_epoch(record.get("resp_time"))
            if timestamp is None:
                continue

            for field_name in field_names:
                value = record.get(field_name)
                try:
                    numeric = float(str(value).strip())
                except (TypeError, ValueError):
                    continue
                result[hour_key(user_id, timestamp)].append(numeric)
                break

    return result


def attach_ema(rows: dict[tuple[str, str, int], dict[str, object]]) -> None:
    study = load_ema_numeric("Study Spaces", ["productivity"])
    stress = load_ema_numeric("Stress", ["level", "null"])
    sleep = load_ema_numeric("Sleep", ["hour"])

    for key, values in study.items():
        row = rows.get(key)
        if row:
            row["study_productivity"] = round(sum(values) / len(values), 2)

    for key, values in stress.items():
        row = rows.get(key)
        if row:
            row["stress_level"] = round(sum(values) / len(values), 2)

    for key, values in sleep.items():
        row = rows.get(key)
        if row:
            row["sleep_hours"] = round(sum(values) / len(values), 2)


def finalize_rows(rows: dict[tuple[str, str, int], dict[str, object]]) -> list[dict[str, object]]:
    finalized = []
    categories = [
        "academic",
        "productivity",
        "communication",
        "social",
        "entertainment",
        "utility",
        "unknown",
    ]

    for row in rows.values():
        total = max(int(row["total_app_events"]), 1)
        row["unique_apps"] = len(row["_packages"])

        for category in categories:
            row[f"{category}_ratio"] = round(int(row[f"{category}_events"]) / total, 4)

        risk_score = compute_behavior_risk_score(row)
        row["behavior_risk_score"] = round(risk_score, 4)
        row["behavior_label"], row["label_source"] = assign_label(row, risk_score)

        row.pop("_packages", None)
        row.pop("_last_package", None)
        row.pop("_last_timestamp", None)

        if int(row["total_app_events"]) > 0:
            finalized.append(row)

    return sorted(finalized, key=lambda item: (item["user_id"], item["date"], int(item["hour"])))


def numeric(row: dict[str, object], key: str, default: float = 0.0) -> float:
    value = row.get(key, default)
    if value == "":
        return default
    return float(value)


def compute_behavior_risk_score(row: dict[str, object]) -> float:
    total = max(numeric(row, "total_app_events"), 1.0)
    switch_rate = min(numeric(row, "app_switches") / total, 1.0)
    active_hours = min(numeric(row, "estimated_active_seconds") / 3600.0, 1.0)
    locked_hours = min(numeric(row, "locked_seconds") / 3600.0, 1.0)
    productive_context = (
        numeric(row, "academic_ratio")
        + numeric(row, "productivity_ratio") * 0.8
        + numeric(row, "has_calendar_event") * 0.15
    )

    risk = (
        numeric(row, "entertainment_ratio") * 0.35
        + numeric(row, "social_ratio") * 0.25
        + switch_rate * 0.20
        + numeric(row, "is_night") * 0.15
        + active_hours * 0.10
        - productive_context * 0.20
        - locked_hours * 0.05
    )

    stress = row.get("stress_level")
    if stress != "":
        risk += max(0.0, (float(stress) - 3.0) / 10.0)

    study_productivity = row.get("study_productivity")
    if study_productivity != "":
        risk -= max(0.0, (float(study_productivity) - 3.0) / 8.0)
        risk += max(0.0, (3.0 - float(study_productivity)) / 8.0)

    return max(0.0, min(risk, 1.0))


def assign_label(row: dict[str, object], risk_score: float) -> tuple[int, str]:
    study_productivity = row.get("study_productivity")
    if study_productivity != "":
        value = float(study_productivity)
        if value >= 4:
            return 0, "ema_study_productivity_high"
        if value <= 2:
            return 1, "ema_study_productivity_low"

    if risk_score >= 0.30:
        return 1, "weak_behavior_risk_rule"
    return 0, "weak_behavior_risk_rule"


def write_output(rows: list[dict[str, object]]) -> None:
    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    with OUTPUT_PATH.open("w", newline="", encoding="utf-8") as file:
        writer = csv.DictWriter(file, fieldnames=FIELDNAMES)
        writer.writeheader()
        writer.writerows([{key: row.get(key, "") for key in FIELDNAMES} for row in rows])


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--row-stride",
        type=int,
        default=5,
        help="Read every Nth app_usage row. Use 1 for full processing.",
    )
    parser.add_argument(
        "--include-activity",
        action="store_true",
        help="Also process sensing/activity. This is slower and optional.",
    )
    args = parser.parse_args()

    if not DATA_DIR.exists():
        raise FileNotFoundError(f"StudentLife dataset not found: {DATA_DIR}")

    rows: dict[tuple[str, str, int], dict[str, object]] = {}
    load_app_usage(rows, max(args.row_stride, 1))
    load_calendar(rows)
    load_phone_locks(rows)
    if args.include_activity:
        load_activity(rows)
    attach_ema(rows)

    finalized = finalize_rows(rows)
    write_output(finalized)

    label_counts = Counter(str(row["behavior_label"]) for row in finalized)
    sources = Counter(str(row["label_source"]) for row in finalized)
    print(f"Wrote {len(finalized)} hourly behavior rows to {OUTPUT_PATH}")
    print(f"Label counts: {dict(label_counts)}")
    print(f"Label sources: {dict(sources)}")


if __name__ == "__main__":
    main()
