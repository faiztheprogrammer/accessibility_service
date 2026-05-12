# Database Schema (ER Diagram Translation)

The SQLite local database must follow these entity structures:

1. **User_Profile**
   - `user_id` (PK)
   - `focus_goal` (string)
   - `alert_level` (string)
   - `updated_at`

2. **AppSession**
   - `session_id` (PK)
   - `user_id` (FK)
   - `platform` (string)
   - `start_time` (datetime)
   - `end_time` (datetime)
   - `total_duration_sec` (integer)

3. **ContentSnapshot**
   - `content_id` (PK)
   - `session_id` (FK)
   - `title` (string)
   - `url` (string)
   - `captured_at` (datetime)

4. **AI_Verdict**
   - `verdict_id` (PK)
   - `content_id` (FK)
   - `final_label` (string - productive/unproductive)
   - `confidence_score` (float)
   - `decided_at` (datetime)

5. **Intervention**
   - `intervention_id` (PK)
   - `verdict_id` (FK)
   - `intervention_level` (string - tier 1/2/3)
   - `shown_at` (datetime)

6. **BehavioralMetrics**
   - `metrics_id` (PK)
   - `session_id` (FK)
   - `avg_session_duration`
   - `night_usage` (boolean)
   - `session_frequency`
   - `total_time_today`

7. **CacheStore**
   - `cache_id` (PK)
   - `content_hash` (text)
   - `last_relevance_score` (float)
   - `last_label` (text)
   - `cached_at`
