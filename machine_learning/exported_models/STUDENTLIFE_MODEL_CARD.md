# StudentLife Behavioral Risk Model

## Purpose
Predict whether the current usage pattern looks behaviorally risky or low risk.

This model is not a content classifier. It does not decide whether a YouTube title is relevant to a career goal.
Gemini remains the semantic content evaluator.

## Dataset
`machine_learning/processed/studentlife_behavior_dataset.csv`

Source folders used: app_usage, calendar, sensing/phonelock, sensing/activity, and selected EMA responses.

## Target
`behavior_label`: 0 = low behavior risk, 1 = high behavior risk.

## Labeling
Labels are weak behavioral-risk labels derived from StudentLife EMA study-productivity responses when available, otherwise from usage-pattern risk rules. This model does not classify content relevance; Gemini handles semantic content relevance.

## Algorithm
Multinomial Naive Bayes implemented with the Python standard library.

## Evaluation Split
Grouped by user_id so the same student is not in both train and test.

## Metrics
- Accuracy: 0.9312
- High-risk precision: 0.6760
- High-risk recall: 0.6900
- High-risk F1: 0.6829
- Train rows: 51017
- Test rows: 14386
- Train users: 39
- Test users: 10
- Label counts: {'0': 58887, '1': 6516}

## Honest Limitation
The labels are weak supervision, not perfect human ground truth. The model is useful as a contextual risk signal,
but the app should fuse it with Gemini content relevance and the user's goal instead of using it alone.

## Artifact
`studentlife_behavior_model.json`
