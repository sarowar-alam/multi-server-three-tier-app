import React, { useState } from 'react';
import api from '../api';

export default function MeasurementForm({ onSaved }) {
  const getTodayDate = () => new Date().toISOString().split('T')[0];
  const [f, sf] = useState({ weightKg: 70, heightCm: 175, age: 30, sex: 'male', activity: 'moderate', measurementDate: getTodayDate() });
  const [error, setError] = useState(null);
  const [success, setSuccess] = useState(false);
  const [loading, setLoading] = useState(false);

  const sub = async e => {
    e.preventDefault();
    setError(null);
    setSuccess(false);
    setLoading(true);
    try {
      await api.post('/measurements', f);
      setSuccess(true);
      setTimeout(() => setSuccess(false), 3000);
      onSaved && onSaved();
    } catch (err) {
      setError(err.response?.data?.error || 'Failed to save measurement');
    } finally {
      setLoading(false);
    }
  };

  return (
    <form onSubmit={sub}>
      {error && <div className="alert alert-error" role="alert" aria-live="assertive">{error}</div>}
      {success && <div className="alert alert-success" role="alert" aria-live="polite">Measurement saved successfully!</div>}

      <div className="form-group-label">Measurement Date</div>
      <div className="form-row">
        <div className="form-group">
          <label htmlFor="measurementDate">Date</label>
          <input
            id="measurementDate"
            type="date"
            value={f.measurementDate}
            onChange={e => sf({ ...f, measurementDate: e.target.value })}
            required
            max={new Date().toISOString().split('T')[0]}
          />
        </div>
      </div>

      <div className="form-group-label">Body Measurements</div>
      <div className="form-row">
        <div className="form-group">
          <label htmlFor="weight">Weight (kg)</label>
          <input
            id="weight"
            type="number"
            value={f.weightKg}
            onChange={e => sf({ ...f, weightKg: +e.target.value })}
            required
            min="1"
            max="500"
            step="0.1"
            placeholder="70"
          />
        </div>

        <div className="form-group">
          <label htmlFor="height">Height (cm)</label>
          <input
            id="height"
            type="number"
            value={f.heightCm}
            onChange={e => sf({ ...f, heightCm: +e.target.value })}
            required
            min="1"
            max="300"
            step="0.1"
            placeholder="175"
          />
        </div>

        <div className="form-group">
          <label htmlFor="age">Age (years)</label>
          <input
            id="age"
            type="number"
            value={f.age}
            onChange={e => sf({ ...f, age: +e.target.value })}
            required
            min="1"
            max="150"
            placeholder="30"
          />
        </div>
      </div>

      <div className="form-group-label">Profile</div>
      <div className="form-row">
        <div className="form-group">
          <label htmlFor="sex">Biological Sex</label>
          <select
            id="sex"
            value={f.sex}
            onChange={e => sf({ ...f, sex: e.target.value })}
            required
          >
            <option value="male">Male</option>
            <option value="female">Female</option>
          </select>
        </div>

        <div className="form-group">
          <label htmlFor="activity">Activity Level</label>
          <select
            id="activity"
            value={f.activity}
            onChange={e => sf({ ...f, activity: e.target.value })}
            required
          >
            <option value="sedentary">Sedentary (Little/No Exercise)</option>
            <option value="light">Light (1-3 days/week)</option>
            <option value="moderate">Moderate (3-5 days/week)</option>
            <option value="active">Active (6-7 days/week)</option>
            <option value="very_active">Very Active (2x per day)</option>
          </select>
        </div>
      </div>

      <button type="submit" disabled={loading}>
        {loading ? 'Saving...' : 'Save Measurement'}
      </button>
    </form>
  );
}
