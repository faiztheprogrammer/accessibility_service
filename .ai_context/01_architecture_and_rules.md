# System Architecture & Rules

## Tech Stack
- **Frontend**: Flutter (Mobile App, UI Dashboards, WebView).
- **Database**: SQLite (Local Data) / Firebase (Auth).
- **Behavioral ML**: Local Python/Joblib based predictive model (Scikit-learn).
- **Semantic AI**: Cloud-hosted LLM Service (REST API) for NLP text matching.

## Architecture Pattern
3-Tier Architecture with a "Local-First" fallback.

### Layer 1: Managed Browser Frontend (Flutter)
- **Native Observer**: Android Accessibility Service using a Flutter MethodChannel.
- **Content Scraper**: An Android Accessibility Service listens for TYPE_WINDOW_CONTENT_CHANGED events natively and extracts text nodes from the screen (e.g., YouTube video titles) and sends them to Flutter.

### Layer 2: Decision Layer (Inference Engine)
Dual-system evaluation:
- **Model A (Behavioral Guard)**: A local ML model analyzes usage metrics (time of day, session duration, app identity) to generate a Behavioral Risk Score.
- **Model B (Semantic Scorer)**: An LLM evaluates the scraped text against the user's declared Career Goal vector. It returns a Relevance Score (Confidence %).
- **Fusion Engine**: Combines both scores to output a final Verdict (Productive vs. Unproductive).

### Layer 3: Data & Persistence Layer (SQLite)
- Stores usage logs, verdicts, and user goals locally.

## Rules & Constraints
- **Isolate Thread Constraint (NFR_04)**: Scraper execution and ML inference must occur on an Isolate thread to prevent stuttering in the main Flutter UI.
- **Latency Constraint (NFR_01)**: Semantic analysis must complete in < 5.0 seconds.
- **Privacy Constraint (NFR_02)**: Private login credentials and password fields must be explicitly excluded from the scraping script.
