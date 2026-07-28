const { Pool } = require('pg');

// Fail fast if DATABASE_URL is missing — avoids cryptic connection errors later
if (!process.env.DATABASE_URL) {
  throw new Error('DATABASE_URL environment variable is not set. Check your .env file.');
}

// PostgreSQL connection pool configuration
const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  max: parseInt(process.env.DB_POOL_SIZE || '20', 10), // Configurable pool size
  idleTimeoutMillis: 30000, // Close idle clients after 30 seconds
  connectionTimeoutMillis: 5000, // Return error after 5 seconds if can't connect
});

// Handle pool errors — log only, do NOT exit
// Exiting on idle client errors would crash the server on transient network blips
pool.on('error', (err, client) => {
  console.error('Unexpected error on idle PostgreSQL client:', err.message);
});

// Test connection on startup — non-fatal
// Server stays running even if DB is temporarily unavailable at boot
pool.query('SELECT NOW()', (err, res) => {
  if (err) {
    console.error('[WARN] Database connection failed at startup:', err.message);
    console.error('Server will continue — retrying on next request...');
  } else {
    console.log('[OK] Database connected at:', res.rows[0].now);
  }
});

module.exports = {
  query: (text, params) => pool.query(text, params),
  pool
};