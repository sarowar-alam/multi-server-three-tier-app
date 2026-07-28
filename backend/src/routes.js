const express = require('express');
const router  = express.Router();
const db      = require('./db');
const { calculateMetrics } = require('./calculations');

// POST /api/measurements - Create new measurement
router.post('/measurements', async (req, res) => {
  try {
    const { weightKg, heightCm, age, sex, activity, measurementDate } = req.body;

    // Presence validation
    if (!weightKg || !heightCm || !age || !sex) {
      return res.status(400).json({ error: 'Missing required fields' });
    }
    if (weightKg <= 0 || heightCm <= 0 || age <= 0) {
      return res.status(400).json({ error: 'Invalid values: must be positive numbers' });
    }

    // calculateMetrics throws on bad input — caught below and returned as 400
    const metrics = calculateMetrics({ weightKg, heightCm, age, sex, activity });
    const date    = measurementDate || new Date().toISOString().split('T')[0];

    const sql    = `INSERT INTO measurements
                      (weight_kg, height_cm, age, sex, activity_level,
                       bmi, bmi_category, bmr, daily_calories, measurement_date, created_at)
                    VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10, now())
                    RETURNING *`;
    const values = [
      weightKg, heightCm, age, sex, activity,
      metrics.bmi, metrics.bmiCategory, metrics.bmr, metrics.dailyCalories, date,
    ];
    const result = await db.query(sql, values);

    if (!result.rows || !result.rows[0]) {
      throw new Error('Insert did not return the created row');
    }
    res.status(201).json({ measurement: result.rows[0] });
  } catch (e) {
    console.error('Error creating measurement:', e);
    // Validation errors from calculateMetrics are user-facing; all others are generic
    const isValidationError = e.message && (
      e.message.startsWith('Invalid') || e.message.startsWith('Missing')
    );
    res.status(isValidationError ? 400 : 500).json({
      error: isValidationError ? e.message : 'Failed to create measurement',
    });
  }
});

// GET /api/measurements - Get measurements (most recent first, capped at 100)
router.get('/measurements', async (req, res) => {
  try {
    const limit  = Math.min(parseInt(req.query.limit  || '100', 10), 100);
    const offset = Math.max(parseInt(req.query.offset || '0',   10), 0);
    const result = await db.query(
      'SELECT * FROM measurements ORDER BY measurement_date DESC, created_at DESC LIMIT $1 OFFSET $2',
      [limit, offset]
    );
    res.json({ rows: result.rows });
  } catch (e) {
    console.error('Error fetching measurements:', e);
    res.status(500).json({ error: 'Failed to fetch measurements' });
  }
});

// GET /api/measurements/trends - Rolling BMI averages (default 30 days, max 365)
router.get('/measurements/trends', async (req, res) => {
  try {
    const days = Math.min(Math.max(parseInt(req.query.days || '30', 10), 1), 365);
    const sql  = `SELECT measurement_date AS day, ROUND(AVG(bmi)::numeric, 1) AS avg_bmi
                  FROM measurements
                  WHERE measurement_date >= CURRENT_DATE - ($1 || ' days')::interval
                  GROUP BY measurement_date
                  ORDER BY measurement_date`;
    const result = await db.query(sql, [days]);
    res.json({ rows: result.rows });
  } catch (e) {
    console.error('Error fetching trends:', e);
    res.status(500).json({ error: 'Failed to fetch trends' });
  }
});

module.exports = router;
