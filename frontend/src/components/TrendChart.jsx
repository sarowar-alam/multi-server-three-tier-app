import React, { useEffect, useState } from 'react';
import { Line } from 'react-chartjs-2';
import {
  Chart as ChartJS,
  CategoryScale,
  LinearScale,
  PointElement,
  LineElement,
  Title,
  Tooltip,
  Legend,
  Filler,
} from 'chart.js';
import api from '../api';

ChartJS.register(CategoryScale, LinearScale, PointElement, LineElement, Title, Tooltip, Legend, Filler);

export default function TrendChart() {
  const [chartData, setChartData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  useEffect(() => {
    api.get('/measurements/trends')
      .then(({ data }) => {
        const rows = data.rows;
        if (!rows || rows.length === 0) { setLoading(false); return; }
        setChartData({
          labels: rows.map(r =>
            new Date(r.day).toLocaleDateString('en-US', { month: 'short', day: 'numeric' })
          ),
          datasets: [{
            label: 'Average BMI',
            data: rows.map(r => parseFloat(r.avg_bmi)),
            borderColor: '#4f46e5',
            backgroundColor: 'rgba(79, 70, 229, 0.08)',
            pointBackgroundColor: '#4f46e5',
            pointBorderColor: '#ffffff',
            pointBorderWidth: 2,
            pointRadius: 5,
            pointHoverRadius: 7,
            tension: 0.4,
            fill: true,
          }],
        });
      })
      .catch(() => setError('Failed to load trend data'))
      .finally(() => setLoading(false));
  }, []);

  if (loading) return <div className="loading">Loading chart</div>;
  if (error)   return <div className="alert alert-error">{error}</div>;
  if (!chartData) return (
    <div className="empty-state">
      <p>No trend data yet.</p>
      <p className="empty-hint">Add measurements over multiple days to see your BMI trend.</p>
    </div>
  );

  return (
    <Line
      data={chartData}
      options={{
        responsive: true,
        plugins: {
          legend: {
            position: 'top',
            labels: { font: { family: 'Inter, sans-serif', size: 13 }, usePointStyle: true },
          },
          title: { display: false },
          tooltip: {
            callbacks: { label: ctx => ` BMI: ${ctx.parsed.y}` },
          },
        },
        scales: {
          x: {
            grid: { display: false },
            ticks: { font: { family: 'Inter, sans-serif', size: 12 } },
          },
          y: {
            grid: { color: 'rgba(0, 0, 0, 0.05)' },
            ticks: { font: { family: 'Inter, sans-serif', size: 12 } },
            title: { display: true, text: 'BMI', font: { family: 'Inter, sans-serif', size: 12 } },
          },
        },
      }}
    />
  );
}
