from __future__ import annotations

import argparse
import csv
import json
import math
from collections import Counter, defaultdict
from pathlib import Path


BASE_DIR = Path(__file__).resolve().parent
DEFAULT_DATASET = BASE_DIR / "processed" / "studentlife_behavior_dataset.csv"
DEFAULT_OUTPUT_DIR = BASE_DIR / "exported_models"


NUMERIC_FEATURES = [
    "hour",
    "day_of_week",
    "total_app_events",
    "unique_apps",
    "app_switches",
    "estimated_active_seconds",
    "academic_ratio",
    "productivity_ratio",
    "communication_ratio",
    "social_ratio",
    "entertainment_ratio",
    "utility_ratio",
    "unknown_ratio",
    "phone_lock_events",
    "locked_seconds",
    "activity_stationary_events",
    "activity_walking_events",
    "activity_running_events",
    "study_productivity",
    "stress_level",
    "sleep_hours",
]


BINARY_FEATURES = [
    "is_weekend",
    "is_night",
    "has_calendar_event",
]


def read_dataset(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as file:
        return list(csv.DictReader(file))


def bucket_feature(name: str, value: str) -> str:
    if value == "":
        return f"{name}=missing"

    try:
        numeric = float(value)
    except ValueError:
        return f"{name}={value}"

    if name == "hour":
        if 5 <= numeric < 12:
            return "hour=morning"
        if 12 <= numeric < 17:
            return "hour=afternoon"
        if 17 <= numeric < 22:
            return "hour=evening"
        return "hour=night"

    if name == "day_of_week":
        return f"day_of_week={int(numeric)}"

    if name.endswith("_ratio"):
        if numeric == 0:
            return f"{name}=none"
        if numeric < 0.25:
            return f"{name}=low"
        if numeric < 0.60:
            return f"{name}=medium"
        return f"{name}=high"

    if name.endswith("_seconds"):
        if numeric < 60:
            return f"{name}=under_1m"
        if numeric < 5 * 60:
            return f"{name}=1m_5m"
        if numeric < 30 * 60:
            return f"{name}=5m_30m"
        return f"{name}=over_30m"

    if name in {"study_productivity", "stress_level", "sleep_hours"}:
        if numeric <= 2:
            return f"{name}=low"
        if numeric <= 4:
            return f"{name}=medium"
        return f"{name}=high"

    if numeric == 0:
        return f"{name}=none"
    if numeric <= 3:
        return f"{name}=low"
    if numeric <= 10:
        return f"{name}=medium"
    return f"{name}=high"


def feature_tokens(row: dict[str, str]) -> list[str]:
    tokens = []
    for feature in BINARY_FEATURES:
        tokens.append(f"{feature}={row.get(feature, '0')}")
    for feature in NUMERIC_FEATURES:
        tokens.append(bucket_feature(feature, row.get(feature, "")))
    return tokens


def split_by_user(rows: list[dict[str, str]]) -> tuple[list[dict[str, str]], list[dict[str, str]]]:
    by_label = defaultdict(list)
    for row in rows:
        by_label[int(row["behavior_label"])].append(row["user_id"])

    train_users = set()
    test_users = set()

    for label, users in by_label.items():
        unique_users = sorted(set(users))
        split_index = max(1, int(len(unique_users) * 0.8))
        if split_index >= len(unique_users):
            split_index = len(unique_users) - 1
        train_users.update(unique_users[:split_index])
        test_users.update(unique_users[split_index:])

    train_rows = [row for row in rows if row["user_id"] in train_users]
    test_rows = [row for row in rows if row["user_id"] in test_users]

    if not train_rows or not test_rows:
        raise ValueError("Could not create a user-grouped train/test split.")

    return train_rows, test_rows


def train_naive_bayes(rows: list[dict[str, str]]) -> dict[str, object]:
    label_counts = Counter(int(row["behavior_label"]) for row in rows)
    if set(label_counts) != {0, 1}:
        raise ValueError("Training requires both behavior labels: 0 low risk and 1 high risk.")

    train_rows, test_rows = split_by_user(rows)
    class_counts = Counter(int(row["behavior_label"]) for row in train_rows)
    token_counts = {0: Counter(), 1: Counter()}
    class_token_totals = Counter()
    vocabulary = set()

    for row in train_rows:
        label = int(row["behavior_label"])
        tokens = feature_tokens(row)
        token_counts[label].update(tokens)
        class_token_totals[label] += len(tokens)
        vocabulary.update(tokens)

    model = {
        "model_type": "StudentLifeBehaviorRiskNaiveBayes",
        "label_mapping": {"0": "low_behavior_risk", "1": "high_behavior_risk"},
        "feature_schema": {
            "binary_features": BINARY_FEATURES,
            "numeric_features_binned": NUMERIC_FEATURES,
            "prediction_target": "behavior_label",
        },
        "class_counts": {str(key): value for key, value in class_counts.items()},
        "token_counts": {str(key): dict(value) for key, value in token_counts.items()},
        "class_token_totals": {str(key): value for key, value in class_token_totals.items()},
        "vocabulary": sorted(vocabulary),
    }

    metrics = evaluate_model(model, test_rows)
    metrics.update(
        {
            "dataset_rows": len(rows),
            "train_rows": len(train_rows),
            "test_rows": len(test_rows),
            "train_users": len(set(row["user_id"] for row in train_rows)),
            "test_users": len(set(row["user_id"] for row in test_rows)),
            "label_counts": {str(key): value for key, value in label_counts.items()},
            "split_strategy": "Grouped by user_id so the same student is not in both train and test.",
            "labeling_note": (
                "Labels are weak behavioral-risk labels derived from StudentLife EMA study-productivity "
                "responses when available, otherwise from usage-pattern risk rules. This model does not "
                "classify content relevance; Gemini handles semantic content relevance."
            ),
        }
    )
    model["metrics"] = metrics
    return model


def predict_high_risk_probability(model: dict[str, object], row: dict[str, str]) -> float:
    tokens = feature_tokens(row)
    vocab_size = max(len(model["vocabulary"]), 1)
    total_docs = sum(int(value) for value in model["class_counts"].values())
    scores = {}

    for label in (0, 1):
        label_key = str(label)
        class_count = int(model["class_counts"].get(label_key, 0))
        score = math.log((class_count + 1) / (total_docs + 2))
        token_counts = model["token_counts"].get(label_key, {})
        token_total = int(model["class_token_totals"].get(label_key, 0))

        for token in tokens:
            token_count = int(token_counts.get(token, 0))
            score += math.log((token_count + 1) / (token_total + vocab_size))
        scores[label] = score

    max_score = max(scores.values())
    exp_low = math.exp(scores[0] - max_score)
    exp_high = math.exp(scores[1] - max_score)
    return exp_high / (exp_low + exp_high)


def evaluate_model(model: dict[str, object], rows: list[dict[str, str]]) -> dict[str, object]:
    true_positive = true_negative = false_positive = false_negative = 0

    for row in rows:
        probability = predict_high_risk_probability(model, row)
        predicted = 1 if probability >= 0.5 else 0
        actual = int(row["behavior_label"])

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
        "precision_high_risk": precision,
        "recall_high_risk": recall,
        "f1_high_risk": f1,
        "confusion_matrix": [
            [true_negative, false_positive],
            [false_negative, true_positive],
        ],
    }


def write_outputs(model: dict[str, object], output_dir: Path) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    model_path = output_dir / "studentlife_behavior_model.json"
    metrics_path = output_dir / "studentlife_behavior_metrics.json"
    card_path = output_dir / "STUDENTLIFE_MODEL_CARD.md"

    model_path.write_text(json.dumps(model, indent=2), encoding="utf-8")
    metrics_path.write_text(json.dumps(model["metrics"], indent=2), encoding="utf-8")

    metrics = model["metrics"]
    card_path.write_text(
        "\n".join(
            [
                "# StudentLife Behavioral Risk Model",
                "",
                "## Purpose",
                "Predict whether the current usage pattern looks behaviorally risky or low risk.",
                "",
                "This model is not a content classifier. It does not decide whether a YouTube title is relevant to a career goal.",
                "Gemini remains the semantic content evaluator.",
                "",
                "## Dataset",
                "`machine_learning/processed/studentlife_behavior_dataset.csv`",
                "",
                "Source folders used: app_usage, calendar, sensing/phonelock, sensing/activity, and selected EMA responses.",
                "",
                "## Target",
                "`behavior_label`: 0 = low behavior risk, 1 = high behavior risk.",
                "",
                "## Labeling",
                metrics["labeling_note"],
                "",
                "## Algorithm",
                "Multinomial Naive Bayes implemented with the Python standard library.",
                "",
                "## Evaluation Split",
                metrics["split_strategy"],
                "",
                "## Metrics",
                f"- Accuracy: {metrics['accuracy']:.4f}",
                f"- High-risk precision: {metrics['precision_high_risk']:.4f}",
                f"- High-risk recall: {metrics['recall_high_risk']:.4f}",
                f"- High-risk F1: {metrics['f1_high_risk']:.4f}",
                f"- Train rows: {metrics['train_rows']}",
                f"- Test rows: {metrics['test_rows']}",
                f"- Train users: {metrics['train_users']}",
                f"- Test users: {metrics['test_users']}",
                f"- Label counts: {metrics['label_counts']}",
                "",
                "## Honest Limitation",
                "The labels are weak supervision, not perfect human ground truth. The model is useful as a contextual risk signal,",
                "but the app should fuse it with Gemini content relevance and the user's goal instead of using it alone.",
                "",
                "## Artifact",
                "`studentlife_behavior_model.json`",
                "",
            ]
        ),
        encoding="utf-8",
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data", default=str(DEFAULT_DATASET))
    parser.add_argument("--output-dir", default=str(DEFAULT_OUTPUT_DIR))
    args = parser.parse_args()

    dataset_path = Path(args.data)
    rows = read_dataset(dataset_path)
    model = train_naive_bayes(rows)
    write_outputs(model, Path(args.output_dir))
    print(json.dumps(model["metrics"], indent=2))


if __name__ == "__main__":
    main()
