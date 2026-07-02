# AI-Based Intelligent Productivity Enhancement System

**FYP-F22-26 · University of Lahore · BSSE Fall 2022–2026**  
Supervisor: Mr. Syed Zeeshan · Students: Faiz Ur Rehman, Azeem Ur Rehman

---

## Quick Reference

| Task | Command |
|---|---|
| Run app (debug, with Gemini) | `flutter run --dart-define-from-file=.env` |
| Run on a specific device | `flutter run --dart-define-from-file=.env -d <device-id>` |
| List connected devices | `flutter devices` |
| Get device ID via ADB | `adb devices` |
| Build release APK | `flutter build apk --release --dart-define-from-file=.env` |
| Install APK via ADB | `adb install build/app/outputs/flutter-apk/app-release.apk` |
| Install debug APK via ADB | `adb install build/app/outputs/flutter-apk/app-debug.apk` |
| Watch logcat (Flutter only) | `adb logcat -s flutter` |
| Watch all app logs | `adb logcat --pid=$(adb shell pidof com.example.accessibility_service)` |
| Retrain ML model | `cd machine_learning && python train_studentlife_behavior_model.py` |
| Install dependencies | `flutter pub get` |

> **After every `.env` change:** The key is baked in at compile time. You must rebuild (`flutter run` again) — restarting the app is not enough.

> **After install on a new device:** Settings → Accessibility → Installed Services → enable the app. Without this the monitor will not fire at all.

---

## What It Does

An Android app that monitors what you watch on YouTube and Instagram in real time and alerts you when it's a distraction based on your career goal. It reads on-screen content passively via Android's Accessibility Service, scores it with Gemini AI, and combines that with a behavioral risk score from a trained Naive Bayes model to decide whether to intervene.

---

## Architecture at a Glance

```
YouTube / Instagram
        │  (AccessibilityEvent)
        ▼
Kotlin AccessibilityService
        │  sendBroadcast → MainActivity.eventReceiver → MethodChannel
        ▼
Flutter Decision Engine
   ├── CacheStore (FNV-1a hash) ──► cached? return instantly
   ├── Gemini 2.5 Flash API ──────► relevance_score (0–1)
   └── Naive Bayes Model (on-device) ► behavior_risk_score (0–1)
        │
        ▼
   Fusion Engine ──► verdict label ──► Notification + SQLite + Dashboard
```

**Five verdict labels:**

| Label | UI Display | Meaning |
|---|---|---|
| `productive` | Productive | Goal-aligned content, low behavioral risk |
| `productive_high_risk` | Productive, But Prolonged | Goal-aligned but session pattern suggests overuse |
| `contextual_distraction` | Contextual Distraction | Content is relevant but behavior context makes it distracting |
| `high_distraction_risk` | High Distraction Risk | Unrelated content + risky session behavior |
| `possible_distraction` | Possible Distraction | Unrelated content, low session risk |

---

## Project Structure

```
lib/
├── main.dart
├── screens/
│   ├── monitor_screen.dart          # Core monitoring UI + MethodChannel handler + notifications
│   ├── dashboard_screen.dart        # Pie chart + trend analytics
│   ├── login_screen.dart
│   ├── register_screen.dart
│   └── profile_screen.dart          # Career goal + Instagram blocker toggle
└── services/
    ├── decision_engine.dart         # Fusion logic, cache lookup, intervention counter
    ├── api_service.dart             # Gemini API + local keyword fallback scorer
    ├── behavior_model_service.dart  # On-device Naive Bayes inference + proxy features
    ├── behavior_analytics_service.dart
    ├── db_service.dart              # SQLite (8 tables)
    └── auth_service.dart            # SHA-256 auth + SharedPreferences session

machine_learning/
├── prepare_studentlife_behavior_dataset.py   # Raw CSV → processed dataset
├── train_studentlife_behavior_model.py       # Train Naive Bayes → JSON model
├── exported_models/
│   └── studentlife_behavior_model.json       # Bundled Flutter asset (~48 KB)
└── processed/
    └── studentlife_behavior_dataset.csv      # 65,403 hourly rows

android/app/src/main/kotlin/.../
├── AccessibilityMonitorService.kt   # Detects content via AccessibilityEvents, sends broadcast
└── MainActivity.kt                  # Receives broadcast, forwards to Flutter via MethodChannel

.env                  # Your real Gemini key — gitignored, never commit this
.env.example          # Committed template (no real key)
```

---

## Setup & Run

### 1. Prerequisites

- Flutter 3.x — verify with `flutter --version`
- Android device with USB debugging on (Settings → Developer Options → USB Debugging)
- Accessibility permission after install (Settings → Accessibility → your app → enable)

### 2. First-time setup

```bash
# Copy template and add your key
cp .env.example .env
# Open .env and set: GEMINI_API_KEY=your_actual_key_here

flutter pub get
```

### 3. Run

```bash
flutter run --dart-define-from-file=.env
```

If you have multiple devices connected:

```bash
adb devices                          # find your device ID
flutter run --dart-define-from-file=.env -d D6Q8DENVFMTGS8A6
```

### 4. After changing the Gemini API key

Edit `.env`, then **rebuild** — the key is compile-time, not runtime:

```bash
flutter run --dart-define-from-file=.env
```

Simply restarting the app on the phone does nothing.

### 5. Build & install release APK

```bash
# Build
flutter build apk --release --dart-define-from-file=.env

# Install directly to connected device
adb install build/app/outputs/flutter-apk/app-release.apk

# Or share the file — recipient needs "Install from unknown sources" enabled
```

---

## Gemini API Key

- Stored in `.env` as `GEMINI_API_KEY=...`
- Injected at compile time via `--dart-define-from-file=.env`
- Read in code as `String.fromEnvironment('GEMINI_API_KEY')`
- If the key is empty or invalid, the app falls back to local keyword scoring — no crash
- Notifications show the source: `Gemini` = API called, `Local` = fallback used, `Cache` = previous result reused

**To rotate the key:** update `.env` and run `flutter run --dart-define-from-file=.env` again.

---

## How Scoring Works

### Content score (Gemini)

Gemini evaluates the video title + visible text against your career goal. The prompt instructs it to first infer the full domain of the goal (e.g. "Flutter Developer" → mobile dev, Dart, software engineering, adjacent JS/web ecosystem, CS fundamentals) before scoring.

| Range | Meaning |
|---|---|
| 0.80–1.00 | Core skill — directly teaches the goal's primary domain |
| 0.55–0.79 | Adjacent — useful for someone on this career path |
| 0.30–0.54 | Loosely related — general education, weak alignment |
| 0.00–0.29 | Not relevant — entertainment, gaming, gossip, unrelated content |

Threshold for `is_productive = true`: relevance ≥ 0.55

### Behavioral risk score (Naive Bayes model)

The model takes 24 features bucketed into 74 tokens. Three features that the app cannot directly observe are computed as proxies:

| Feature | How it's derived at runtime |
|---|---|
| `study_productivity` | Today's productive-verdict ratio × 5 (0% productive → score 1.0 = `low`) |
| `stress_level` | `app_switches × 0.15 + distraction_ratio × 3.5` clamped 1–5 |
| `sleep_hours` | Fixed at 6.0 (not observable — neutral default) |

The model uses a **balanced 50/50 prior** (not the training distribution's 9:1 imbalance) so feature evidence drives the output rather than the base rate.

Final risk: `max(modelRisk, 0.45 × modelRisk + 0.55 × liveHeuristic)`

### Fusion

```
behaviorPenalty     = f(contentScore, behaviorRiskScore)   # 0–0.25
contextualScore     = contentScore − behaviorPenalty        # clamp 0–1
finalRisk           = (1 − contextualScore) × 0.75 + behaviorRiskScore × 0.25
```

### Verdict logic

```
contentProductive AND contextualScore < 0.55  →  contextual_distraction
contentProductive AND behaviorRisk ≥ 0.50     →  productive_high_risk
contentProductive                             →  productive
behaviorRisk ≥ 0.45                           →  high_distraction_risk
otherwise                                     →  possible_distraction
```

### Intervention tiers (consecutive distraction count)

The engine counts consecutive distracting verdicts and escalates through three tiers. Thresholds are set higher than you might expect because YouTube Shorts can fire many verdicts in quick succession as the user swipes between videos.

| Count | Tier | In-app (app open) | Overlay (app backgrounded) |
|---|---|---|---|
| 1st | Tier 1 | Banner changes to "Heads Up" | — |
| 6th | Tier 2 | Banner escalates to orange | High-priority heads-up notification over YouTube (with vibration) |
| 12th+ | Tier 3 | Blocking `AlertDialog` requiring acknowledgement | High-priority heads-up notification over YouTube (with vibration) |

**How it works end-to-end:**
1. Flutter `DecisionEngine` increments `_consecutiveUnproductiveCount` on each distraction verdict and returns an `interventionTier`.
2. `MonitorScreen._triggerIntervention()` updates the in-app UI and calls `MethodChannel → show_intervention_alert` with the tier number and message.
3. `MainActivity` broadcasts `ACTION_SHOW_INTERVENTION` to `AccessibilityMonitorService`.
4. The service posts a notification on the `focus_interventions` channel (`IMPORTANCE_HIGH`), which Android delivers as a heads-up banner even while the user is inside YouTube.

A productive verdict resets `_consecutiveUnproductiveCount` to zero.

---

## ML Model

The model is already trained and bundled — you do not need to retrain for normal use.

### Model details

| Attribute | Value |
|---|---|
| Algorithm | Multinomial Naive Bayes |
| Dataset | StudentLife (Dartmouth, 49 students, 65,403 hourly rows) |
| Features | 24 (3 binary + 21 numeric, bucketed to 74 tokens) |
| Train / test split | User-grouped 80/20 (39 / 10 students) |
| Accuracy | 93.1% |
| High-risk F1 | 68.3% |
| Model size | ~48 KB JSON |
| Inference | On-device, no server required |

### Retrain (only if you change the dataset or feature schema)

```bash
cd machine_learning

# Step 1 — prepare dataset from raw StudentLife CSVs
python prepare_studentlife_behavior_dataset.py

# Step 2 — train and export
python train_studentlife_behavior_model.py
# Output: exported_models/studentlife_behavior_model.json
```

The output path is already declared as a Flutter asset in `pubspec.yaml` — no further config needed.

---

## Database

Local SQLite only. Nothing leaves the device.

| Table | Purpose |
|---|---|
| `Users` | Login credentials (SHA-256 hashed passwords) |
| `User_Profile` | Career goal, display name |
| `AppSessions` | Per-app usage sessions with start/end times |
| `Content` | Detected titles and extracted visible text |
| `Verdicts` | Relevance score, risk score, label, source per content item |
| `CacheStore` | FNV-1a hash → cached verdict (skips repeat API calls for identical content) |
| `BehavioralMetrics` | Hourly session stats snapshot |
| `Interventions` | Logged intervention tier events |

---

## Key Behaviour Notes

- **Cache hits** — if the same content (same title + text + goal) was evaluated before, the result is reused instantly. Notification shows `Cache`. Gemini is not called again.
- **Gemini fallback** — if the API times out (5s limit), returns an HTTP error, or quota is exceeded, local keyword scoring runs instead. Notification shows `Local`. Local results are not cached.
- **Key not compiled in** — if `.env` was missing during the build, `GEMINI_API_KEY` will be an empty string and every evaluation goes to local fallback. Rebuild with `--dart-define-from-file=.env`.
- **Instagram Reels** — blocked with a full-screen overlay (toggle in Profile screen). Title extraction from Reels is not possible via the Accessibility API, so only blocking is supported, not scoring.
- **`productive_high_risk` ("Productive, But Prolonged")** — fires when content is relevant (score ≥ 0.55) but `behaviorRiskScore ≥ 0.50`. This means the session history (many distractions earlier, high app switches) is flagging overuse even on goal-aligned content.
- **`contextual_distraction`** — fires when content scores as productive but the behavior penalty pulls `contextualProductivityScore` below 0.55. Common when relevant content appears late in a heavily distracted session.
