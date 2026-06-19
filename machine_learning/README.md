# Machine Learning Pipeline

This folder contains the required behavioral ML component for the FYP.

## Dataset

`data/lsapp.xlsx`

Expected columns:

- `user_id`
- `session_id`
- `timestamp`
- `app_name`
- `event_type`

## Model

`train_behavior_model.py` trains a Multinomial Naive Bayes classifier that predicts whether an app usage session is productive.

The original dataset does not contain explicit productivity labels. The training script does not hardcode labels. It first exports a labeling CSV, and the model only trains after the `label` column has been filled manually.

## Prepare Labels

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
.\.venv\Scripts\python.exe train_behavior_model.py --prepare-labels
```

This writes:

`labeling/app_labels.csv`

Fill the `label` column:

- `1` = productive
- `0` = unproductive

The CSV is app-level on purpose, so one human label applies consistently to all sessions for that app.

## Train

```powershell
.\.venv\Scripts\python.exe train_behavior_model.py
```

The training script itself uses only the Python standard library. The packages in `requirements.txt` are only for serving the FastAPI endpoint.

Expected outputs:

- `exported_models/behavior_model.json`
- `exported_models/behavior_model_metrics.json`
- `exported_models/MODEL_CARD.md`

## Serve

```powershell
.\.venv\Scripts\python.exe api_server.py
```

The Flutter app calls:

`http://192.168.100.201:8000/evaluate_content`

When the model artifact exists, `api_server.py` returns `source: "ml_fusion"`. If the artifact is unavailable, it falls back to `source: "heuristic_fusion"`.

## StudentLife Behavioral Risk Pipeline

The StudentLife dataset is used as a behavioral/context model, not as the YouTube content classifier.
Gemini remains responsible for semantic relevance to the user's career goal.

Prepare the hourly behavior dataset:

```powershell
.\.venv\Scripts\python.exe prepare_studentlife_behavior_dataset.py --row-stride 5
```

Train the StudentLife behavioral-risk model:

```powershell
.\.venv\Scripts\python.exe train_studentlife_behavior_model.py
```

Outputs:

- `processed/studentlife_behavior_dataset.csv`
- `exported_models/studentlife_behavior_model.json`
- `exported_models/studentlife_behavior_metrics.json`
- `exported_models/STUDENTLIFE_MODEL_CARD.md`

`behavior_label` means:

- `0` = low behavioral risk
- `1` = high behavioral risk

The labels are weak supervision. EMA study-productivity responses are used when available; otherwise usage-pattern risk rules are used. Treat this model as one input to the final Decision Engine, not as final truth.
