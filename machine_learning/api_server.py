import json
import logging
import math
import re
from datetime import datetime
from pathlib import Path
from typing import Optional

from fastapi import FastAPI
from pydantic import BaseModel


logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

BASE_DIR = Path(__file__).resolve().parent
MODEL_PATH = BASE_DIR / "exported_models" / "behavior_model.json"

PRODUCTIVE_KEYWORDS = (
    "algorithm",
    "biology",
    "career",
    "class",
    "code",
    "coding",
    "course",
    "dart",
    "data structure",
    "development",
    "education",
    "engineering",
    "explained",
    "flutter",
    "guide",
    "how to",
    "java",
    "javascript",
    "learn",
    "lecture",
    "math",
    "medical",
    "programming",
    "python",
    "science",
    "software",
    "study",
    "tutorial",
)

DISTRACTION_KEYWORDS = (
    "comedy",
    "drama",
    "funny",
    "gaming",
    "gossip",
    "live",
    "meme",
    "prank",
    "reaction",
    "shorts",
    "song",
    "trailer",
    "vlog",
)


class ContentPayload(BaseModel):
    title: str
    channel: str = ""
    extracted_text: str = ""
    career_goal: str
    app_name: Optional[str] = "YouTube"


app = FastAPI(title="FYP Productivity Evaluator")
behavior_model = None


@app.on_event("startup")
async def load_model() -> None:
    global behavior_model

    if not MODEL_PATH.exists():
        logger.warning("No trained model found at %s; using heuristic fallback.", MODEL_PATH)
        return

    behavior_model = json.loads(MODEL_PATH.read_text(encoding="utf-8"))
    logger.info("Loaded behavioral ML model from %s", MODEL_PATH)


@app.post("/evaluate_content")
async def evaluate(payload: ContentPayload):
    text = f"{payload.title} {payload.channel} {payload.extracted_text}".strip()
    logger.info(
        "Received content -> title=%s goal=%s app=%s",
        payload.title,
        payload.career_goal,
        payload.app_name,
    )

    semantic_score = semantic_goal_score(text, payload.career_goal)
    behavior_score = predict_behavior_score(payload.app_name or "YouTube")
    relevance_score = round((semantic_score * 0.72) + (behavior_score * 0.28), 3)
    is_productive = relevance_score >= 0.55
    source = "ml_fusion" if behavior_model is not None else "heuristic_fusion"

    logger.info(
        "Verdict -> productive=%s relevance=%.3f semantic=%.3f behavior=%.3f source=%s",
        is_productive,
        relevance_score,
        semantic_score,
        behavior_score,
        source,
    )

    return {
        "relevance_score": relevance_score,
        "is_productive": is_productive,
        "semantic_score": round(semantic_score, 3),
        "behavior_score": round(behavior_score, 3),
        "source": source,
    }


def semantic_goal_score(text: str, career_goal: str) -> float:
    normalized_text = text.lower()
    goal_terms = [
        term.strip()
        for term in career_goal.lower().replace("/", " ").replace("-", " ").split()
        if len(term.strip()) >= 3
    ]

    goal_hits = sum(1 for term in goal_terms if term in normalized_text)
    productive_hits = sum(1 for keyword in PRODUCTIVE_KEYWORDS if keyword in normalized_text)
    distraction_hits = sum(1 for keyword in DISTRACTION_KEYWORDS if keyword in normalized_text)

    score = 0.25
    score += min(goal_hits * 0.28, 0.45)
    score += min(productive_hits * 0.08, 0.32)
    score -= min(distraction_hits * 0.12, 0.35)
    return max(0.0, min(score, 1.0))


def predict_behavior_score(app_name: str) -> float:
    if behavior_model is None:
        return heuristic_behavior_score(app_name)

    session = current_session_features(app_name)
    tokens = feature_tokens(session)
    vocabulary = behavior_model["vocabulary"]
    vocab_size = max(len(vocabulary), 1)
    total_docs = sum(int(value) for value in behavior_model["class_counts"].values())

    scores = {}
    for label in (0, 1):
        label_key = str(label)
        class_count = int(behavior_model["class_counts"].get(label_key, 0))
        prior = (class_count + 1) / (total_docs + 2)
        score = math.log(prior)
        token_counts = behavior_model["token_counts"].get(label_key, {})
        total_tokens = int(behavior_model["class_token_totals"].get(label_key, 0))

        for token in tokens:
            count = int(token_counts.get(token, 0))
            score += math.log((count + 1) / (total_tokens + vocab_size))
        scores[label] = score

    max_score = max(scores.values())
    exp_0 = math.exp(scores[0] - max_score)
    exp_1 = math.exp(scores[1] - max_score)
    return exp_1 / (exp_0 + exp_1)


def current_session_features(app_name: str) -> dict[str, object]:
    now = datetime.now()
    return {
        "app_name": app_name,
        "event_type": "session",
        "hour": now.hour,
        "day_of_week": now.weekday(),
        "is_night": int(now.hour >= 22 or now.hour < 6),
        "duration_seconds": 0,
        "event_count": 1,
    }


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


def heuristic_behavior_score(app_name: str) -> float:
    app = app_name.lower()
    if "youtube" in app:
        return 0.35
    if any(token in app for token in ("game", "facebook", "instagram", "tiktok")):
        return 0.15
    if any(token in app for token in ("classroom", "docs", "office", "learn")):
        return 0.85
    return 0.5


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8000)
