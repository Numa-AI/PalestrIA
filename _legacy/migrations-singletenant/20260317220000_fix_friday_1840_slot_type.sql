-- Fix Friday 18:40-20:00 slot type: personal-training → small-group
-- Affects all future schedule_overrides (from today onwards)

UPDATE schedule_overrides
SET slot_type = 'small-group'
WHERE time = '18:40 - 20:00'
  AND slot_type = 'personal-training'
  AND EXTRACT(DOW FROM date::date) = 5  -- 5 = Friday
  AND date::date >= CURRENT_DATE;
