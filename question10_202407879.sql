--Q10
--a
CREATE TABLE students (
student_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
student_number TEXT NOT NULL UNIQUE,
full_name TEXT NOT NULL
);
CREATE TABLE applications (
application_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
student_id BIGINT NOT NULL REFERENCES students(student_id),
age_at_application INTEGER NOT NULL CHECK (age_at_application > 0),
monthly_income NUMERIC(12,2) NOT NULL CHECK (monthly_income >= 0),
average_mark NUMERIC(5,2) NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
submitted_on DATE NOT NULL,
status TEXT NOT NULL DEFAULT 'PENDING'
CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);
CREATE TABLE decision_audit (
audit_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
application_id BIGINT NOT NULL REFERENCES applications(application_id),
old_status TEXT NOT NULL,
new_status TEXT NOT NULL,
changed_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

--b
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(
p_age INTEGER, p_income NUMERIC, p_mark NUMERIC)
RETURNS BOOLEAN LANGUAGE plpgsql AS $$
BEGIN
IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
RAISE EXCEPTION 'Age, income and mark are required';
END IF;
IF p_age <= 0 OR p_income < 0 OR p_mark < 0 OR p_mark > 100 THEN
RAISE EXCEPTION 'Invalid age, income or mark';
END IF;
RETURN p_age BETWEEN 18 AND 25 AND p_income <= 3000 AND p_mark >= 70;
END; $$;


--c
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id BIGINT)
LANGUAGE plpgsql AS $$
DECLARE v_age INTEGER; v_income NUMERIC(12,2); v_mark NUMERIC(5,2);
v_status TEXT; v_eligible BOOLEAN;
BEGIN
SELECT age_at_application, monthly_income, average_mark, status
INTO v_age, v_income, v_mark, v_status
FROM applications WHERE application_id = p_application_id FOR UPDATE;
IF NOT FOUND THEN
RAISE EXCEPTION 'Unknown application ID %', p_application_id;
END IF;
IF v_status <> 'PENDING' THEN
RAISE EXCEPTION 'Application % has already been assessed', p_application_id;
END IF;
v_eligible := fn_scholarship_eligible(v_age, v_income, v_mark);
UPDATE applications
SET status = CASE WHEN v_eligible THEN 'APPROVED' ELSE 'REJECTED' END
WHERE application_id = p_application_id;
END; $$;


--d
CREATE OR REPLACE FUNCTION trg_decision_audit()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
IF OLD.status IS DISTINCT FROM NEW.status THEN
INSERT INTO decision_audit(application_id, old_status, new_status)
VALUES (NEW.application_id, OLD.status, NEW.status);
END IF;
RETURN NEW;
END; $$;
CREATE TRIGGER applications_decision_audit
AFTER UPDATE ON applications FOR EACH ROW
EXECUTE FUNCTION trg_decision_audit();

--e
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT s.student_number, s.full_name, a.average_mark, a.status
FROM applications a
JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';

--f
CREATE INDEX idx_applications_status_submitted ON applications(status, submitted_on);
-- Matching query and plan:
EXPLAIN SELECT application_id, student_id, average_mark
FROM applications
WHERE status = 'PENDING'
AND submitted_on >= CURRENT_DATE - 30 AND submitted_on < CURRENT_DATE + 1;


--g

CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql AS $$
DECLARE a RECORD;
BEGIN
FOR a IN SELECT application_id FROM applications
WHERE status = 'PENDING' ORDER BY application_id -- PENDING only
LOOP
CALL pr_assess_application(a.application_id);
END LOOP;
END; $$;
-- Schedule: every Monday at 08:00.
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('weekly-scholarship-assessment', '0 8 * * 1',
$$CALL pr_assess_pending()$$);

---seeds
INSERT INTO students(student_number, full_name) VALUES
('S001', 'Anna'), ('S002', 'Bwalya'), ('S003', 'Chanda');
-- Six PENDING applications across three students.
INSERT INTO applications(student_id, age_at_application, monthly_income, average_mark, submitted_on)
VALUES
(1, 18, 3000, 70.00, CURRENT_DATE - 6), -- every boundary met -> APPROVED
(1, 25, 2500, 85.00, CURRENT_DATE - 5), -- qualifies -> APPROVED
(2, 17, 2000, 90.00, CURRENT_DATE - 4), -- age too low -> REJECTED
(2, 22, 3001, 80.00, CURRENT_DATE - 3), -- income too high -> REJECTED
(3, 21, 2500, 69.99, CURRENT_DATE - 2), -- mark too low -> REJECTED
(3, 26, 1000, 95.00, CURRENT_DATE - 1); -- age too high -> REJECTED
CALL pr_assess_pending();
CALL pr_assess_pending(); -- rerun: nothing is PENDING, so nothing changes
SELECT * FROM v_approved_applicants ORDER BY student_number;
SELECT application_id, old_status, new_status FROM decision_audit ORDER BY audit_id;