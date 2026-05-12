import logging
import random
from fastapi import FastAPI
from pydantic import BaseModel

# Setup logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI()

class ContentPayload(BaseModel):
    title: str
    channel: str
    extracted_text: str
    career_goal: str

@app.post("/evaluate_content")
async def evaluate(payload: ContentPayload):
    logger.info(f"Received content for evaluation -> Title: {payload.title}, Goal: {payload.career_goal}")
    
    # Tier 2: Enhanced Keyword Heuristic (Simulating ML Model)
    # We want to make sure technical tutorials are considered productive
    productive_keywords = [
        "tutorial", "education", "physics", "code", "programming", 
        "course", "study", "c++", "python", "flutter", "java", "math",
        "science", "history", "learning", "how to", "explained"
    ]
    
    text_to_analyze = f"{payload.title} {payload.extracted_text}".lower()
    
    is_productive = False
    # If it contains any productive keywords, mark as productive
    if any(k in text_to_analyze for k in productive_keywords):
        is_productive = True
        relevance_score = round(random.uniform(0.85, 0.99), 2)
    else:
        # Fallback for entertainment/shorts
        is_productive = False
        relevance_score = round(random.uniform(0.1, 0.4), 2)

    logger.info(f"Verdict -> is_productive: {is_productive}, relevance_score: {relevance_score}")
    
    return {
        "relevance_score": relevance_score,
        "is_productive": is_productive
    }

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
