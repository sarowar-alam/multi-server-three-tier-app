-- BMI Health Tracker Database Migration
-- Version: 001
-- Description: Create measurements table
-- Date: 2025-12-12

-- Create measurements table
CREATE TABLE IF NOT EXISTS measurements (
  id SERIAL PRIMARY KEY,
  weight_kg NUMERIC(5,2) NOT NULL CHECK (weight_kg > 20 AND weight_kg < 500),
  height_cm NUMERIC(5,2) NOT NULL CHECK (height_cm > 0 AND height_cm < 300),
  age INTEGER NOT NULL CHECK (age > 0 AND age < 150),
  sex VARCHAR(10) NOT NULL CHECK (sex IN ('male', 'female')),
  activity_level VARCHAR(30) CHECK (activity_level IN ('sedentary', 'light', 'moderate', 'active', 'very_active')),
  bmi NUMERIC(4,1) NOT NULL,
  bmi_category VARCHAR(30),
  bmr INTEGER,
  daily_calories INTEGER,
  measurement_date DATE NOT NULL DEFAULT CURRENT_DATE,
  created_at TIMESTAMPTZ DEFAULT now() NOT NULL
);

-- Create indexes for better query performance
CREATE INDEX IF NOT EXISTS idx_measurements_measurement_date ON measurements(measurement_date DESC);
CREATE INDEX IF NOT EXISTS idx_measurements_created_at ON measurements(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_measurements_bmi ON measurements(bmi);

-- Add comments for documentation
COMMENT ON TABLE measurements IS 'Stores user health measurements including BMI, BMR, and calorie data';
COMMENT ON COLUMN measurements.weight_kg IS 'Weight in kilograms';
COMMENT ON COLUMN measurements.height_cm IS 'Height in centimeters';
COMMENT ON COLUMN measurements.age IS 'Age in years';
COMMENT ON COLUMN measurements.sex IS 'Biological sex (male/female)';
COMMENT ON COLUMN measurements.activity_level IS 'Physical activity level';
COMMENT ON COLUMN measurements.bmi IS 'Body Mass Index';
COMMENT ON COLUMN measurements.bmi_category IS 'BMI category (Underweight/Normal/Overweight/Obese)';
COMMENT ON COLUMN measurements.bmr IS 'Basal Metabolic Rate in calories';
COMMENT ON COLUMN measurements.daily_calories IS 'Daily calorie needs based on activity';
COMMENT ON COLUMN measurements.measurement_date IS 'Date when the measurement was taken (user-specified or current date)';

-- Display confirmation
SELECT 'Migration 001 completed successfully - measurements table created' AS status;
