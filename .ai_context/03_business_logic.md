# Business Logic & Workflows

## 1. Tiered Feedback Intervention Logic (UC_11)
If the Decision Engine returns an "Unproductive" verdict, the system executes non-intrusive nudges escalating to strict blocks:
- **Tier 1**: Display a colored floating chip/nudge.
- **Tier 2**: If wasteful browsing persists for 3 continuous minutes, display a full warning banner.
- **Tier 3**: Display a Blackout Overlay (Forced Exit) for severe goal deviation.
- **Exception Handling**: The user can click "I am still working", which temporarily whitelists the current content category.

## 2. Scraping & Fusion Engine (15-second rules)
- A JavaScript script is injected into the WebView **every 15 seconds** to extract visible text content.
- Execution must happen on an Isolate thread.
- **Fusion Engine Logic**: Combines Behavioral Risk Score (Locally calculated) and Semantic Relevance Score (LLM confidence %) to output a final Verdict (Productive vs. Unproductive).

## 3. Semantic Relevance Evaluation (UC_10 & FR_04)
Workflow:
1. Get User Goal.
2. Get Scraped Text.
3. Check Local CacheStore (using Hash of text).
4. If Cache Hit: Return Score from CacheStore.
5. If Cache Miss: Call LLM API (must be < 5.0 seconds).
6. Return Score & Save to CacheStore.

## 4. Visual Analytics (UC_12 & FR_07)
- A Dashboard visualizes daily and weekly success rates via Pie and Line charts.
- Displays a specific percentage of "Goal-Aligned" content vs. "General Scrolling".
