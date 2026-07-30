import React, { useEffect, useState } from 'react';
import MeasurementForm from './components/MeasurementForm';
import TrendChart from './components/TrendChart';
import api from './api';

// Returns a text color token based on BMI category
function getBmiTextColor(category) {
  switch (category?.toLowerCase()) {
    case 'normal':      return '#1f5c4a';
    case 'overweight':  return '#96620a';
    case 'obese':       return '#a4342b';
    case 'underweight': return '#3a5470';
    default:            return '#20242c';
  }
}

function formatDate(raw) {
  if (!raw) return 'N/A';
  const d = new Date(raw);
  return isNaN(d) ? 'N/A' : d.toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' });
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
      <div className="topbar">
        <div className="brand">
          <svg className="brand-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
            <path d="M22 12h-4l-3 9L9 3l-3 9H2" />
          </svg>
          <span className="brand-name">BMI Health Tracker</span>
        </div>
        <nav className="topbar-nav">
          <a href="#dashboard">Dashboard</a>
          <a href="#history">History</a>
          <a href="#trends">Trends</a>
        </nav>
      </div>

      <div className="container">
        <h1 className="page-title" id="dashboard">Your Health Summary</h1>
        <p className="page-subtitle">A running record of your body composition and energy needs.</p>

        {latest && (
          <div className="stats-grid">
            <div className="stat-card">
              <span className="stat-label">Current BMI</span>
              <span className="stat-value">{latest.bmi}</span>
              <span className="stat-sub" style={{ color: getBmiTextColor(latest.bmi_category) }}>{latest.bmi_category}</span>
            </div>
            <div className="stat-card">
              <span className="stat-label">BMR</span>
              <span className="stat-value">{latest.bmr}</span>
              <span className="stat-sub">calories at rest</span>
            </div>
            <div className="stat-card">
              <span className="stat-label">Daily Calories</span>
              <span className="stat-value">{latest.daily_calories}</span>
              <span className="stat-sub">based on activity</span>
            </div>
            <div className="stat-card">
              <span className="stat-label">Records</span>
              <span className="stat-value">{rows.length}</span>
              <span className="stat-sub">total entries</span>
            </div>
          </div>
        )}

        <div className="section">
          <div className="section-label">Add New Measurement</div>
          <div className="form-box">
            <MeasurementForm onSaved={load} />
          </div>
        </div>

        <div className="section" id="history">
          <div className="section-label">Recent Measurements</div>
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
              {rows.slice(0, 10).map(r => (
                <li key={r.id} className="measurement-item">
                  <span className="measurement-date">{formatDate(r.measurement_date || r.created_at)}</span>
                  <div className="measurement-data">
                    <span>BMI <strong>{r.bmi}</strong> &mdash; <span className="category-text" style={{ color: getBmiTextColor(r.bmi_category) }}>{r.bmi_category}</span></span>
                    <span>BMR <strong>{r.bmr}</strong> cal</span>
                    <span>Daily <strong>{r.daily_calories}</strong> cal</span>
                  </div>
                </li>
              ))}
            </ul>
          )}
        </div>

        <div className="section" id="trends">
          <div className="section-label">30-Day BMI Trend</div>
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
