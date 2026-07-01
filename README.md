# AI-Based Intelligent Productivity Enhancement System

**FYP-F25-23 · University of Lahore · BSSE Fall 2022–2026**  
Supervisor: Mr. Syed Zeeshan · Students: Faiz Ur Rehman, Azeem Ur Rehman

---

## What It Does

An Android app that monitors what you're watching on YouTube and Instagram in real time and alerts you when it's a distraction based on your career goal. It reads on-screen content passively via Android's Accessibility Service, scores it with Gemini AI, and combines that with a behavioral risk score from a trained ML model to decide whether to intervene.

---

## Architecture at a Glance

```
YouTube / Instagram
        │  (AccessibilityEvent)
        ▼
Kotlin AccessibilityService
        │  MethodChannel
        ▼
Flutter Decision Engine
   ├── CacheStore (FNV-1a hash) ──► cached? return instantly
   ├── Gemini 2.5 Flash API ──────► relevance_score (0–1)
   └── Naive Bayes Model (on-device) ► risk_score (0–1)
        │
        ▼
   Fusion Engine ──► verdict label ──► Notification + SQLite + Dashboard
```

**Five verdict labels:** `productive` · `productive_high_risk` · `contextual_distraction` · `high_distraction_risk` · `possible_distraction`

---

## Project Structure

```
lib/
├── main.dart
├── screens/
│   ├── monitor_screen.dart       # Core monitoring UI + notification logic
│   ├── dashboard_screen.dart     # Pie chart + trend line analytics
│   ├── login_screen.dart
│   ├── register_screen.dart
│   └── profile_screen.dart       # Career goal + Instagram blocker toggle
└── services/
    ├── decision_engine.dart      # Fusion logic, cache lookup, intervention counter
    ├── api_service.dart          # Gemini API + local fallback evaluator
    ├── behavior_model_service.dart  # On-device Naive Bayes inference
    ├── behavior_analytics_service.dart
    ├── db_service.dart           # SQLite (8 tables, DB version 5)
    └── auth_service.dart         # SHA-256 auth + SharedPreferences session

machine_learning/
├── prepare_studentlife_behavior_dataset.py   # Raw CSV → processed dataset
├── train_studentlife_behavior_model.py       # Train Naive Bayes → JSON model
├── exported_models/
│   └── studentlife_behavior_model.json       # Bundled Flutter asset (~48 KB)
└── processed/
    └── studentlife_behavior_dataset.csv      # 65,403 hourly rows

android/app/src/main/kotlin/.../
└── AccessibilityMonitorService.kt            # Kotlin accessibility service
```

---

## Setup & Run

### Prerequisites
- Flutter 3.x (`flutter --version`)
- Android device with USB debugging enabled
- Accessibility permission granted to the app (Settings → Accessibility → your app)

### Run

Copy the env template and fill in your key:

```bash
cp .env.example .env
# edit .env and set GEMINI_API_KEY
```

Then run:

```bash
flutter pub get
flutter run --dart-define-from-file=.env
```

To build a release APK:

```bash
flutter build apk --release --dart-define-from-file=.env
```

`.env` is gitignored. `.env.example` is committed as the template. The key is injected at compile time via `String.fromEnvironment('GEMINI_API_KEY')`. If the key is missing the app falls back to local keyword scoring — no crash.

> **After install:** Go to Settings → Accessibility → Installed Services → enable the app. Without this the monitor won't fire.

### Build APK (to share with someone)

```bash
flutter build apk --release
# Output: build/app/outputs/flutter-apk/app-release.apk
```

Share `app-release.apk` directly. The recipient needs to allow "Install from unknown sources" in their Android settings.

---

## ML Model

The behavioral risk model is already trained and bundled. You only need to retrain if you change the dataset or feature schema.

### Retrain

```bash
cd machine_learning

# Step 1 — prepare the dataset from raw StudentLife CSVs
python prepare_studentlife_behavior_dataset.py

# Step 2 — train and export the model
python train_studentlife_behavior_model.py
```

Output: `exported_models/studentlife_behavior_model.json` (already listed as a Flutter asset in `pubspec.yaml`)

### Model Details

| Attribute | Value |
|---|---|
| Algorithm | Multinomial Naive Bayes |
| Dataset | StudentLife (Dartmouth, 49 students, 65,403 hourly rows) |
| Features | 24 (3 binary + 21 numeric, bucketed to 74 tokens) |
| Train / test split | User-grouped 80/20 (39 / 10 students) |
| Accuracy | 93.1% |
| High-risk F1 | 68.3% |
| Model size | ~48 KB JSON |

The model runs entirely on-device. No server required for inference.

---

## How Scoring Works

**Content score** — Gemini evaluates the video title + visible text against your career goal and returns a relevance score from 0.0 to 1.0.

**Behavioral risk score** — The Naive Bayes model looks at your current session: time of day, session duration, app switches, entertainment ratio, night usage. Returns a risk score from 0.0 to 1.0. Final score is `max(modelScore, 0.45 × modelScore + 0.55 × liveHeuristic)`.

**Fusion** — `finalRisk = (1 − contextualContentScore) × 0.75 + riskScore × 0.25`

**Intervention tiers** (based on consecutive distraction count):
- Count = 1 → Tier 1: soft notification
- Count = 3 → Tier 2: warning with session stats
- Count ≥ 5 → Tier 3: strong alert

---

## Database

Local SQLite only. Nothing leaves the device.

| Table | Purpose |
|---|---|
| `Users` | Login credentials (SHA-256 hashed passwords) |
| `User_Profile` | Career goal, display name |
| `AppSessions` | Per-app usage sessions |
| `Content` | Detected titles and extracted text |
| `Verdicts` | Relevance score, risk score, label, source per content item |
| `CacheStore` | FNV-1a hash → cached Gemini verdict (skips repeat API calls) |
| `BehavioralMetrics` | Hourly session stats snapshot |
| `Interventions` | Logged intervention tier events |

---

## Key Behaviour Notes

- **Cache hits** show `Cache` as the source label in notifications — Gemini was correctly skipped, the score is from a previous evaluation of the same content.
- **Gemini fallback** kicks in when the API times out (5s), returns HTTP error, or quota is exceeded. Fallback results show `Local` and are not cached.
- **Instagram Reels** are blocked with a full-screen overlay (toggle in Profile screen). Title extraction from Reels is not possible via Accessibility API — only blocking is supported.
- The Gemini API key uses `String.fromEnvironment` with a `defaultValue` — it always works without setting any environment variable.
