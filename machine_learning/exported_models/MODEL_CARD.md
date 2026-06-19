# Behavioral Productivity Model

## Purpose
Predict whether an app-usage session is productive or unproductive.

## Dataset
`machine_learning/data/lsapp.xlsx`

## Algorithm
Multinomial Naive Bayes implemented with the Python standard library.

## Labeling
Labels were loaded from machine_learning/labeling/app_labels.csv. No app taxonomy or hardcoded productivity rules were used during training.

## Evaluation Split
Train/test split is grouped by app_name so the same app does not appear in both training and testing.

## Metrics
- Accuracy: 0.5226
- Productive precision: 0.4391
- Productive recall: 0.7847
- Productive F1: 0.5631
- Train rows: 28414
- Test rows: 9323
- Label counts: {'0': 17904, '1': 19833}

## Artifact
`behavior_model.json` is loaded by `api_server.py`.
