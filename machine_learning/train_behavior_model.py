from __future__ import annotations

import argparse
import csv
import json
import math
import re
import zipfile
from collections import Counter, defaultdict
from datetime import datetime
from pathlib import Path
from xml.etree import ElementTree


REQUIRED_LABELS = {"0", "1"}


def read_xlsx(path: Path) -> list[dict[str, str]]:
    with zipfile.ZipFile(path) as workbook:
        shared_strings = read_shared_strings(workbook)
        sheet_name = first_sheet_name(workbook)
        with workbook.open(sheet_name) as sheet:
            return read_sheet_rows(sheet, shared_strings)


def read_shared_strings(workbook: zipfile.ZipFile) -> list[str]:
    if "xl/sharedStrings.xml" not in workbook.namelist():
        return []

    namespace = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"
    root = ElementTree.fromstring(workbook.read("xl/sharedStrings.xml"))
    strings = []

    for item in root.iter(f"{namespace}si"):
        text_parts = [node.text or "" for node in item.iter(f"{namespace}t")]
        strings.append("".join(text_parts))

    return strings


def first_sheet_name(workbook: zipfile.ZipFile) -> str:
    sheets = sorted(
        name
        for name in workbook.namelist()
        if name.startswith("xl/worksheets/sheet") and name.endswith(".xml")
    )
    if not sheets:
        raise ValueError("No worksheet found in XLSX file.")
    return sheets[0]


def read_sheet_rows(sheet, shared_strings: list[str]) -> list[dict[str, str]]:
    rows = []
    header = None
    namespace = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"

    for _, row in ElementTree.iterparse(sheet, events=("end",)):
        if row.tag != f"{namespace}row":
            continue

        values = {}
        for cell in row.iter(f"{namespace}c"):
            ref = cell.attrib.get("r", "")
            column_index = column_to_index(re.sub(r"\d", "", ref))
            values[column_index] = cell_value(cell, shared_strings, namespace)

        row.clear()
        if not values:
            continue

        dense = [values.get(i, "") for i in range(max(values) + 1)]
        if header is None:
            header = [item.strip() for item in dense]
            continue

        rows.append(
            {
                header[index]: dense[index]
                for index in range(min(len(header), len(dense)))
                if header[index]
            }
        )

    return rows


def column_to_index(column: str) -> int:
    index = 0
    for char in column:
        index = index * 26 + (ord(char.upper()) - ord("A") + 1)
    return index - 1


def cell_value(cell: ElementTree.Element, shared_strings: list[str], namespace: str) -> str:
    value_node = cell.find(f"{namespace}v")
    if value_node is None or value_node.text is None:
        return ""

    value = value_node.text
    if cell.attrib.get("t") == "s":
        return shared_strings[int(value)]
    return value


def build_sessions(rows: list[dict[str, str]]) -> list[dict[str, object]]:
    required = {"user_id", "session_id", "timestamp", "app_name", "event_type"}
    missing = required.difference(rows[0].keys() if rows else [])
    if missing:
        raise ValueError(f"Dataset is missing columns: {sorted(missing)}")

    grouped = defaultdict(list)
    for row in rows:
        key = (row["user_id"], row["session_id"], row["app_name"])
        grouped[key].append(row)

    sessions = []
    for (user_id, session_id, app_name), events in grouped.items():
        parsed_events = []
        for event in events:
            timestamp = parse_timestamp(event["timestamp"])
            if timestamp is None:
                continue
            parsed_events.append((timestamp, event["event_type"]))

        if not parsed_events:
            continue

        parsed_events.sort(key=lambda item: item[0])
        opened = [item[0] for item in parsed_events if item[1].lower() == "opened"]
        closed = [item[0] for item in parsed_events if item[1].lower() == "closed"]
        start = min(opened) if opened else parsed_events[0][0]
        end = max(closed) if closed else parsed_events[-1][0]
        duration = max(int((end - start).total_seconds()), 0)

        sessions.append(
            {
                "user_id": user_id,
                "session_id": session_id,
                "app_name": app_name,
                "event_type": "session",
                "session_date": start.strftime("%Y-%m-%d"),
                "hour": start.hour,
                "day_of_week": start.weekday(),
                "is_night": int(start.hour >= 22 or start.hour < 6),
                "duration_seconds": duration,
                "event_count": len(parsed_events),
            }
        )

    return sessions


def parse_timestamp(value: str) -> datetime | None:
    value = str(value).strip()
    for pattern in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S"):
        try:
            return datetime.strptime(value, pattern)
        except ValueError:
            pass

    try:
        serial = float(value)
    except ValueError:
        return None

    excel_epoch = datetime(1899, 12, 30)
    return excel_epoch.fromordinal(excel_epoch.toordinal() + int(serial))


def export_app_label_template(sessions: list[dict[str, object]], output_path: Path) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    stats = {}

    for session in sessions:
        app = str(session["app_name"])
        current = stats.setdefault(
            app,
            {
                "app_name": app,
                "session_count": 0,
                "total_duration_seconds": 0,
                "night_session_count": 0,
                "label": "",
                "notes": "",
            },
        )
        current["session_count"] += 1
        current["total_duration_seconds"] += int(session["duration_seconds"])
        current["night_session_count"] += int(session["is_night"])

    rows = sorted(stats.values(), key=lambda row: (-row["session_count"], row["app_name"]))
    with output_path.open("w", newline="", encoding="utf-8") as file:
        writer = csv.DictWriter(
            file,
            fieldnames=[
                "app_name",
                "session_count",
                "total_duration_seconds",
                "night_session_count",
                "label",
                "notes",
            ],
        )
        writer.writeheader()
        writer.writerows(rows)


def load_app_labels(path: Path) -> dict[str, int]:
    labels = {}
    with path.open(newline="", encoding="utf-8") as file:
        reader = csv.DictReader(file)
        for row in reader:
            label = (row.get("label") or "").strip()
            if not label:
                continue
            if label not in REQUIRED_LABELS:
                raise ValueError(
                    f"Invalid label '{label}' for app '{row.get('app_name')}'. "
                    "Use 1 for productive or 0 for unproductive."
                )
            labels[(row.get("app_name") or "").strip()] = int(label)
    return labels


def attach_labels(
    sessions: list[dict[str, object]],
    app_labels: dict[str, int],
) -> list[dict[str, object]]:
    labeled = []
    for session in sessions:
        app_name = str(session["app_name"])
        if app_name not in app_labels:
            continue
        row = dict(session)
        row["label"] = app_labels[app_name]
        labeled.append(row)
    return labeled


def feature_tokens(session: dict[str, object]) -> list[str]:
    app_name = str(session["app_name"]).lower()
    tokens = re.findall(r"[a-z0-9]+", app_name)
    tokens.extend(
        [
            f"hour_{session['hour']}",
            f"dow_{session['day_of_week']}",
            f"night_{session['is_night']}",
            f"event_{session['event_type']}",
            duration_bucket(int(session["duration_seconds"])),
            event_count_bucket(int(session["event_count"])),
        ]
    )
    return tokens


def duration_bucket(seconds: int) -> str:
    if seconds < 60:
        return "duration_under_1m"
    if seconds < 5 * 60:
        return "duration_1m_5m"
    if seconds < 30 * 60:
        return "duration_5m_30m"
    return "duration_over_30m"


def event_count_bucket(count: int) -> str:
    if count <= 2:
        return "events_low"
    if count <= 10:
        return "events_medium"
    return "events_high"


def train_naive_bayes(labeled_sessions: list[dict[str, object]]) -> dict[str, object]:
    if len(labeled_sessions) < 20:
        raise ValueError(
            "Not enough labeled sessions to train. Add labels to more apps in "
            "machine_learning/labeling/app_labels.csv."
        )

    label_counts = Counter(int(row["label"]) for row in labeled_sessions)
    if set(label_counts) != {0, 1}:
        raise ValueError("Training requires both labels: 0 unproductive and 1 productive.")

    train_rows, test_rows = split_by_app(labeled_sessions)

    class_counts = Counter(int(row["label"]) for row in train_rows)
    token_counts = {0: Counter(), 1: Counter()}
    class_token_totals = Counter()
    vocabulary = set()

    for row in train_rows:
        label = int(row["label"])
        tokens = feature_tokens(row)
        token_counts[label].update(tokens)
        class_token_totals[label] += len(tokens)
        vocabulary.update(tokens)

    model = {
        "model_type": "MultinomialNaiveBayes",
        "class_counts": {str(key): value for key, value in class_counts.items()},
        "token_counts": {
            str(label): dict(counts) for label, counts in token_counts.items()
        },
        "class_token_totals": {
            str(key): value for key, value in class_token_totals.items()
        },
        "vocabulary": sorted(vocabulary),
        "label_mapping": {"0": "unproductive", "1": "productive"},
    }

    metrics = evaluate_model(model, test_rows)
    metrics.update(
        {
            "dataset_rows": len(labeled_sessions),
            "train_rows": len(train_rows),
            "test_rows": len(test_rows),
            "labeling_note": (
                "Labels were loaded from machine_learning/labeling/app_labels.csv. "
                "No app taxonomy or hardcoded productivity rules were used during training."
            ),
            "split_strategy": (
                "Train/test split is grouped by app_name so the same app does not "
                "appear in both training and testing."
            ),
            "label_counts": {str(key): value for key, value in label_counts.items()},
        }
    )
    model["metrics"] = metrics
    return model


def split_by_app(
    labeled_sessions: list[dict[str, object]],
) -> tuple[list[dict[str, object]], list[dict[str, object]]]:
    app_labels = {}
    for row in labeled_sessions:
        app_labels[str(row["app_name"])] = int(row["label"])

    train_apps = set()
    test_apps = set()
    apps_by_label = defaultdict(list)

    for app_name, label in app_labels.items():
        apps_by_label[label].append(app_name)

    for label, apps in apps_by_label.items():
        apps = sorted(apps)
        split_index = max(1, int(len(apps) * 0.8))
        if split_index >= len(apps):
            split_index = len(apps) - 1

        train_apps.update(apps[:split_index])
        test_apps.update(apps[split_index:])

    train_rows = [
        row for row in labeled_sessions if str(row["app_name"]) in train_apps
    ]
    test_rows = [
        row for row in labeled_sessions if str(row["app_name"]) in test_apps
    ]

    if not train_rows or not test_rows:
        raise ValueError("Could not create train/test split from labeled apps.")

    return train_rows, test_rows


def predict_probability(model: dict[str, object], session: dict[str, object]) -> float:
    tokens = feature_tokens(session)
    vocabulary = model["vocabulary"]
    vocab_size = max(len(vocabulary), 1)
    total_docs = sum(int(value) for value in model["class_counts"].values())

    scores = {}
    for label in (0, 1):
        label_key = str(label)
        class_count = int(model["class_counts"].get(label_key, 0))
        prior = (class_count + 1) / (total_docs + 2)
        score = math.log(prior)
        token_counts = model["token_counts"].get(label_key, {})
        total_tokens = int(model["class_token_totals"].get(label_key, 0))

        for token in tokens:
            count = int(token_counts.get(token, 0))
            score += math.log((count + 1) / (total_tokens + vocab_size))
        scores[label] = score

    max_score = max(scores.values())
    exp_0 = math.exp(scores[0] - max_score)
    exp_1 = math.exp(scores[1] - max_score)
    return exp_1 / (exp_0 + exp_1)


def evaluate_model(model: dict[str, object], rows: list[dict[str, object]]) -> dict[str, object]:
    true_positive = true_negative = false_positive = false_negative = 0

    for row in rows:
        probability = predict_probability(model, row)
        predicted = 1 if probability >= 0.5 else 0
        actual = int(row["label"])

        if predicted == 1 and actual == 1:
            true_positive += 1
        elif predicted == 0 and actual == 0:
            true_negative += 1
        elif predicted == 1 and actual == 0:
            false_positive += 1
        else:
            false_negative += 1

    total = max(len(rows), 1)
    accuracy = (true_positive + true_negative) / total
    precision = true_positive / max(true_positive + false_positive, 1)
    recall = true_positive / max(true_positive + false_negative, 1)
    f1 = 2 * precision * recall / max(precision + recall, 1e-9)

    return {
        "accuracy": accuracy,
        "precision_productive": precision,
        "recall_productive": recall,
        "f1_productive": f1,
        "confusion_matrix": [
            [true_negative, false_positive],
            [false_negative, true_positive],
        ],
    }


def write_outputs(model: dict[str, object], output_dir: Path) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    model_path = output_dir / "behavior_model.json"
    metrics_path = output_dir / "behavior_model_metrics.json"
    card_path = output_dir / "MODEL_CARD.md"

    model_path.write_text(json.dumps(model, indent=2), encoding="utf-8")
    metrics_path.write_text(json.dumps(model["metrics"], indent=2), encoding="utf-8")
    metrics = model["metrics"]

    card_path.write_text(
        "\n".join(
            [
                "# Behavioral Productivity Model",
                "",
                "## Purpose",
                "Predict whether an app-usage session is productive or unproductive.",
                "",
                "## Dataset",
                "`machine_learning/data/lsapp.xlsx`",
                "",
                "## Algorithm",
                "Multinomial Naive Bayes implemented with the Python standard library.",
                "",
                "## Labeling",
                metrics["labeling_note"],
                "",
                "## Evaluation Split",
                metrics["split_strategy"],
                "",
                "## Metrics",
                f"- Accuracy: {metrics['accuracy']:.4f}",
                f"- Productive precision: {metrics['precision_productive']:.4f}",
                f"- Productive recall: {metrics['recall_productive']:.4f}",
                f"- Productive F1: {metrics['f1_productive']:.4f}",
                f"- Train rows: {metrics['train_rows']}",
                f"- Test rows: {metrics['test_rows']}",
                f"- Label counts: {metrics['label_counts']}",
                "",
                "## Artifact",
                "`behavior_model.json` is loaded by `api_server.py`.",
                "",
            ]
        ),
        encoding="utf-8",
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data", default="data/lsapp.xlsx")
    parser.add_argument("--labels", default="labeling/app_labels.csv")
    parser.add_argument("--output-dir", default="exported_models")
    parser.add_argument(
        "--prepare-labels",
        action="store_true",
        help="Export app label template and stop without training.",
    )
    args = parser.parse_args()

    base_dir = Path(__file__).resolve().parent
    rows = read_xlsx((base_dir / args.data).resolve())
    sessions = build_sessions(rows)
    labels_path = (base_dir / args.labels).resolve()

    if args.prepare_labels or not labels_path.exists():
        export_app_label_template(sessions, labels_path)
        print(f"Label template written to: {labels_path}")
        print("Fill the label column with 1 productive or 0 unproductive, then rerun training.")
        return

    app_labels = load_app_labels(labels_path)
    labeled_sessions = attach_labels(sessions, app_labels)
    model = train_naive_bayes(labeled_sessions)
    write_outputs(model, (base_dir / args.output_dir).resolve())
    print(json.dumps(model["metrics"], indent=2))


if __name__ == "__main__":
    main()
