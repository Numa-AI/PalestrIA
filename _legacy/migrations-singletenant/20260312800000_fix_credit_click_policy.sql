-- Fix: allow anonymous users to insert click logs too
DROP POLICY IF EXISTS "Anyone can insert click logs" ON credit_link_clicks;

CREATE POLICY "Anyone can insert click logs"
    ON credit_link_clicks FOR INSERT
    TO authenticated, anon
    WITH CHECK (true);
