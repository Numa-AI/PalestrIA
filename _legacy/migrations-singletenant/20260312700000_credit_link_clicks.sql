-- Log clicks on the "Andrea Pompili" credit link
CREATE TABLE IF NOT EXISTS credit_link_clicks (
    id         UUID        DEFAULT gen_random_uuid() PRIMARY KEY,
    user_name  TEXT,
    user_email TEXT,
    page       TEXT,
    clicked_at TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE credit_link_clicks ENABLE ROW LEVEL SECURITY;

-- Anyone (authenticated or anonymous) can insert click logs
CREATE POLICY "Anyone can insert click logs"
    ON credit_link_clicks FOR INSERT
    TO authenticated, anon
    WITH CHECK (true);

-- Only admins can read logs
CREATE POLICY "Admins can read click logs"
    ON credit_link_clicks FOR SELECT
    TO authenticated
    USING (
        (SELECT raw_app_meta_data->>'role' FROM auth.users WHERE id = auth.uid()) = 'admin'
    );
