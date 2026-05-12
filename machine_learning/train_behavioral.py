import os
import pandas as pd
import numpy as np
from sklearn.model_selection import train_test_split
from sklearn.ensemble import RandomForestClassifier
from sklearn.metrics import accuracy_score, f1_score, confusion_matrix
import joblib

print("Loading dataset...")
data_path = 'machine_learning/data/lsapp.xlsx'
df = pd.read_excel(data_path)

print("Preprocessing and Feature Engineering...")
# Ensure timestamp is datetime
df['timestamp'] = pd.to_datetime(df['timestamp'])

# Sort values to process sequences chronologically
df = df.sort_values(by=['user_id', 'timestamp'])

# To calculate session duration, we need to pair 'Opened' and 'Closed' events.
# A simplified approach for this dataset (given it's just event logs):
# We'll calculate the time difference between consecutive events for the same user and app.
# If an event is 'Closed', duration is time since previous 'Opened'.

df['prev_event_type'] = df.groupby(['user_id', 'session_id', 'app_name'])['event_type'].shift(1)
df['prev_timestamp'] = df.groupby(['user_id', 'session_id', 'app_name'])['timestamp'].shift(1)

# Consider duration only when current event is Closed and prev is Opened
duration_mask = (df['event_type'] == 'Closed') & (df['prev_event_type'] == 'Opened')
df.loc[duration_mask, 'session_duration_sec'] = (df['timestamp'] - df['prev_timestamp']).dt.total_seconds()

# Filter down to rows where duration was calculated (i.e., completed sessions)
sessions = df[duration_mask].copy()

# Feature 1: Night Usage (between 22:00 and 06:00)
sessions['hour'] = sessions['timestamp'].dt.hour
sessions['night_usage'] = ((sessions['hour'] >= 22) | (sessions['hour'] < 6)).astype(int)

# Feature 2: Session Duration
# We have `session_duration_sec`. Let's handle any NaN or negative values (just in case)
sessions['session_duration_sec'] = sessions['session_duration_sec'].fillna(0).clip(lower=0)

# Feature 3: Session Frequency (Total sessions in the last 24 hours for the user)
# We can approximate this by grouping by date.
sessions['date'] = sessions['timestamp'].dt.date
session_freq = sessions.groupby(['user_id', 'date']).size().reset_index(name='session_frequency')
sessions = pd.merge(sessions, session_freq, on=['user_id', 'date'], how='left')

# Feature 4: Total Time Today
total_time = sessions.groupby(['user_id', 'date'])['session_duration_sec'].sum().reset_index(name='total_time_today_sec')
sessions = pd.merge(sessions, total_time, on=['user_id', 'date'], how='left')

# Drop NA to avoid issues in model
features_df = sessions[['session_duration_sec', 'night_usage', 'session_frequency', 'total_time_today_sec']].dropna()

# Generate Heuristic Target Proxy: is_distracted
# Rules: distracted if night_usage is True AND session_duration > 300 seconds (5 mins) 
# OR if total_time_today > 14400 (4 hours)
print("Generating heuristic target proxy...")
target_conditions = (
    (features_df['night_usage'] == 1) & (features_df['session_duration_sec'] > 300) |
    (features_df['total_time_today_sec'] > 14400)
)
features_df['is_distracted'] = target_conditions.astype(int)

print(f"Dataset shape after preprocessing: {features_df.shape}")

# Prepare Data for Training
X = features_df[['session_duration_sec', 'night_usage', 'session_frequency', 'total_time_today_sec']]
y = features_df['is_distracted']

X_train, X_test, y_train, y_test = train_test_split(X, y, test_size=0.2, random_state=42)

# Train Model
print("Training RandomForest Classifier...")
model = RandomForestClassifier(n_estimators=100, random_state=42)
model.fit(X_train, y_train)

# Evaluate Model
y_pred = model.predict(X_test)
accuracy = accuracy_score(y_test, y_pred)
f1 = f1_score(y_test, y_pred)
conf_matrix = confusion_matrix(y_test, y_pred)

print("\n--- Evaluation Metrics ---")
print(f"Accuracy:  {accuracy:.4f}")
print(f"F1-Score:  {f1:.4f}")
print("Confusion Matrix:")
print(conf_matrix)

# Export Model
model_dir = 'machine_learning/exported_models'
os.makedirs(model_dir, exist_ok=True)
model_path = os.path.join(model_dir, 'behavioral_model.joblib')
joblib.dump(model, model_path)

print(f"\nModel successfully saved to {model_path}")
