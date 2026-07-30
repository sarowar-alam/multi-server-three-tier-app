import React, { useEffect, useState } from 'react';
import MeasurementForm from './components/MeasurementForm';
import TrendChart from './components/TrendChart';
import api from './api';

// Returns a text color token based on BMI category
function getBmiTextColor(category) {
  switch (category?.toLowerCase()) {
    case 'normal':      return '#1f7a4d';
    case 'overweight':  return '#b5720a';
    case 'obese':       return '#c0362c';
    case 'underweight': return '#0b3d63';
    default:            return '#1a2332';
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
    <div className="app-shell">
      <aside className="sidebar">
        <div className="brand">
          <svg className="brand-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
            <path d="M22 12h-4l-3 9L9 3l-3 9H2" />
          </svg>
          <span className="brand-name">BMI Health Tracker</span>
        </div>

        <nav className="sidebar-nav">
          <a href="#dashboard" className="active">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
              <rect x="3" y="3" width="7" height="7" /><rect x="14" y="3" width="7" height="7" />
              <rect x="14" y="14" width="7" height="7" /><rect x="3" y="14" width="7" height="7" />
            </svg>
            Dashboard
          </a>
          <a href="#history">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
              <circle cx="12" cy="12" r="10" /><polyline points="12 6 12 12 16 14" />
            </svg>
            History
          </a>
          <a href="#trends">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
              <polyline points="22 12 18 12 15 21 9 3 6 12 2 12" />
            </svg>
            Trends
          </a>
        </nav>

        <div className="sidebar-footer">
          BMI &amp; Health Tracker &copy; {new Date().getFullYear()}
        </div>
      </aside>

      <div className="main-content">
        <div className="topbar">
          <h1>Dashboard</h1>
          <div className="status-indicator">
            <span className="status-dot"></span>
            System Online
          </div>
        </div>

        <div className="container">
          {latest && (
            <div className="stats-grid" id="dashboard">
              <div className="stat-card">
                <span className="stat-value">{latest.bmi}</span>
                <span className="stat-label">Current BMI</span>
                <span className="stat-sub" style={{ color: getBmiTextColor(latest.bmi_category) }}>{latest.bmi_category}</span>
              </div>
              <div className="stat-card">
                <span className="stat-value">{latest.bmr}</span>
                <span className="stat-label">BMR (cal)</span>
                <span className="stat-sub">at rest per day</span>
              </div>
              <div className="stat-card">
                <span className="stat-value">{latest.daily_calories}</span>
                <span className="stat-label">Daily Calories</span>
                <span className="stat-sub">based on activity</span>
              </div>
              <div className="stat-card">
                <span className="stat-value">{rows.length}</span>
                <span className="stat-label">Records</span>
                <span className="stat-sub">total measurements</span>
              </div>
            </div>
          )}

          <div className="content-split">
            <div className="card">
              <div className="card-header">
                <h2>
                  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                    <line x1="12" y1="5" x2="12" y2="19" /><line x1="5" y1="12" x2="19" y2="12" />
                  </svg>
                  Add New Measurement
                </h2>
              </div>
              <MeasurementForm onSaved={load} />
            </div>

            <div className="card">
              <div className="card-header">
                <h2>At a Glance</h2>
              </div>
              {latest ? (
                <div className="summary-panel">
                  <div className="summary-row">
                    <span className="summary-label">Last recorded</span>
                    <span className="summary-value">{formatDate(latest.measurement_date || latest.created_at)}</span>
                  </div>
                  <div className="summary-row">
                    <span className="summary-label">BMI category</span>
                    <span className="summary-value" style={{ color: getBmiTextColor(latest.bmi_category) }}>{latest.bmi_category}</span>
                  </div>
                  <div className="summary-row">
                    <span className="summary-label">BMR</span>
                    <span className="summary-value accent">{latest.bmr} cal</span>
                  </div>
                  <div className="summary-row">
                    <span className="summary-label">Daily calories</span>
                    <span className="summary-value accent">{latest.daily_calories} cal</span>
                  </div>
                </div>
              ) : (
                <div className="empty-state">
                  <p>No data yet.</p>
                </div>
              )}
            </div>
          </div>

          <div className="card" id="history">
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
              <table className="measurements-table">
                <thead>
                  <tr>
                    <th>Date</th>
                    <th>BMI</th>
                    <th>Category</th>
                    <th>BMR</th>
                    <th>Daily Calories</th>
                  </tr>
                </thead>
                <tbody>
                  {rows.slice(0, 10).map(r => (
                    <tr key={r.id} style={{ borderLeftColor: getBmiTextColor(r.bmi_category) }}>
                      <td className="date-cell">{formatDate(r.measurement_date || r.created_at)}</td>
                      <td><strong>{r.bmi}</strong></td>
                      <td className="category-text" style={{ color: getBmiTextColor(r.bmi_category) }}>{r.bmi_category}</td>
                      <td>{r.bmr} cal</td>
                      <td>{r.daily_calories} cal</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
          </div>

          <div className="card" id="trends">
            <div className="card-header">
              <h2>30-Day BMI Trend</h2>
            </div>
            <div className="chart-container">
              <TrendChart />
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
