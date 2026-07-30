import React, { useEffect, useState } from 'react';
import MeasurementForm from './components/MeasurementForm';
import TrendChart from './components/TrendChart';
import api from './api';

// Returns color tokens based on BMI category
function getBmiStyle(category) {
  switch (category?.toLowerCase()) {
    case 'normal':      return { border: '#10b981', bg: '#f0fdf4', text: '#065f46' };
    case 'overweight':  return { border: '#f59e0b', bg: '#fffbeb', text: '#92400e' };
    case 'obese':       return { border: '#ef4444', bg: '#fef2f2', text: '#991b1b' };
    case 'underweight': return { border: '#3b82f6', bg: '#eff6ff', text: '#1e40af' };
    default:            return { border: '#6366f1', bg: '#eef2ff', text: '#3730a3' };
  }
}

export default function App() {
  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  const load = async () => {
    setLoading(true);
    setError(null);
    try {
      const r = await api.get('/measurements');
      setRows(r.data.rows);
    } catch (err) {
      setError(err.response?.data?.error || 'Failed to load measurements');
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => { load(); }, []);

  const latest = rows[0];

  return (
    <>
      <header className="app-header">
        <h1>BMI &amp; Health Tracker</h1>
        <p className="app-subtitle">Monitor your health metrics &middot; Track progress &middot; Reach your goals</p>
      </header>

      <div className="container">
        {/* Stat Summary Cards */}
        {latest && (
          <div className="stats-grid">
            <div className="stat-card" style={{ background: 'linear-gradient(135deg, #4f46e5 0%, #4338ca 100%)' }}>
              <span className="stat-value">{latest.bmi}</span>
              <span className="stat-label">Current BMI</span>
              <span className="stat-sub">{latest.bmi_category}</span>
            </div>
            <div className="stat-card" style={{ background: 'linear-gradient(135deg, #f59e0b 0%, #d97706 100%)' }}>
              <span className="stat-value">{latest.bmr}</span>
              <span className="stat-label">BMR (cal)</span>
              <span className="stat-sub">at rest per day</span>
            </div>
            <div className="stat-card" style={{ background: 'linear-gradient(135deg, #10b981 0%, #059669 100%)' }}>
              <span className="stat-value">{latest.daily_calories}</span>
              <span className="stat-label">Daily Calories</span>
              <span className="stat-sub">based on activity</span>
            </div>
            <div className="stat-card" style={{ background: 'linear-gradient(135deg, #8b5cf6 0%, #7c3aed 100%)' }}>
              <span className="stat-value">{rows.length}</span>
              <span className="stat-label">Records</span>
              <span className="stat-sub">total measurements</span>
            </div>
          </div>
        )}

        {/* Add Measurement */}
        <div className="card">
          <div className="card-header">
            <h2>Add New Measurement</h2>
          </div>
          <MeasurementForm onSaved={load} />
        </div>

        {/* Measurement History */}
        <div className="card">
          <div className="card-header">
            <h2>Recent Measurements</h2>
          </div>
          {error && <div className="alert alert-error">{error}</div>}
          {loading ? (
            <div className="loading">Loading your data</div>
          ) : rows.length === 0 ? (
            <div className="empty-state">
              <p>No measurements yet.</p>
              <p className="empty-hint">Add your first measurement above to get started!</p>
            </div>
          ) : (
            <ul className="measurements-list">
              {rows.slice(0, 10).map(r => {
                const bmiStyle = getBmiStyle(r.bmi_category);
                return (
                  <li key={r.id} className="measurement-item" style={{ borderLeftColor: bmiStyle.border }}>
                    <span className="measurement-date">
                      {(() => {
                        const raw = r.measurement_date || r.created_at;
                        if (!raw) return 'N/A';
                        const d = new Date(raw);
                        return isNaN(d) ? 'N/A' : d.toLocaleDateString('en-US', {
                          month: 'short', day: 'numeric', year: 'numeric',
                        });
                      })()}
                    </span>
                    <div className="measurement-data">
                      <span className="measurement-badge" style={{ background: bmiStyle.bg, color: bmiStyle.text }}>
                        BMI <strong>{r.bmi}</strong> &mdash; {r.bmi_category}
                      </span>
                      <span className="measurement-badge badge-bmr">
                        BMR <strong>{r.bmr}</strong> cal
                      </span>
                      <span className="measurement-badge badge-calories">
                        Daily <strong>{r.daily_calories}</strong> cal
                      </span>
                    </div>
                  </li>
                );
              })}
            </ul>
          )}
        </div>

        {/* BMI Trend Chart */}
        <div className="card">
          <div className="card-header">
            <h2>30-Day BMI Trend</h2>
          </div>
          <div className="chart-container">
            <TrendChart />
          </div>
        </div>
      </div>

      <footer className="app-footer">
        <p>BMI &amp; Health Tracker &copy; {new Date().getFullYear()} &mdash; Track your health, reach your goals</p>
      </footer>
    </>
  );
}
