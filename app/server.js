// app/server.js
// Status monitor — runs health checks against all three tiers.
// Container build: all wiring comes from env vars (see package.json / k8s ConfigMap).

const express = require('express');
const { Pool }  = require('pg');
const http      = require('http');
const os        = require('os');

const app  = express();
const port = parseInt(process.env.PORT || '3000');

// Web tier host used by the Nginx round-trip check. In k8s this is the web Service DNS name.
const WEB_HOST = process.env.WEB_HOST || 'web';

app.use(express.json());
app.use((_req, res, next) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  next();
});

// ─── Database connection pool ─────────────────────────────────────────────────

const pool = new Pool({
  host:            process.env.DB_HOST,
  port:            parseInt(process.env.DB_PORT || '5432'),
  database:        process.env.DB_NAME,
  user:            process.env.DB_USER,
  password:        process.env.DB_PASSWORD,
  connectionTimeoutMillis: 3000,
  idleTimeoutMillis:       5000,
});

// ─── Check helpers ────────────────────────────────────────────────────────────

// Times how long an async fn takes; returns { ok, latencyMs, error? }
async function timed(fn) {
  const start = Date.now();
  try {
    await fn();
    return { ok: true, latencyMs: Date.now() - start };
  } catch (err) {
    return { ok: false, latencyMs: Date.now() - start, error: err.message };
  }
}

// HTTP GET with a timeout — resolves on 2xx, rejects otherwise
function httpGet(url, timeoutMs = 3000) {
  return new Promise((resolve, reject) => {
    const req = http.get(url, { timeout: timeoutMs }, (res) => {
      if (res.statusCode >= 200 && res.statusCode < 300) {
        res.resume();
        resolve(res.statusCode);
      } else {
        reject(new Error(`HTTP ${res.statusCode}`));
      }
    });
    req.on('timeout', () => { req.destroy(); reject(new Error('Timeout')); });
    req.on('error',   (err) => reject(err));
  });
}

// ─── Individual checks ────────────────────────────────────────────────────────

// 1. Self — this process is clearly alive if it responds; report system vitals
async function checkSelf() {
  const uptimeSec = Math.floor(process.uptime());
  const memMb     = (process.memoryUsage().rss / 1024 / 1024).toFixed(1);
  const loadAvg   = os.loadavg()[0].toFixed(2);
  return {
    ok:        true,
    latencyMs: 0,
    detail:    `uptime ${fmtUptime(uptimeSec)} · ${memMb} MB RSS · load ${loadAvg}`,
  };
}

// 2. Nginx — hit the /health endpoint on the web tier
async function checkNginx() {
  const result = await timed(() => httpGet(`http://${WEB_HOST}/health`));
  return {
    ...result,
    detail: result.ok ? 'HTTP 200 from /health' : result.error,
  };
}

// 3. PostgreSQL — run a real round-trip query
async function checkDatabase() {
  const result = await timed(async () => {
    const client = await pool.connect();
    try {
      await client.query('SELECT 1');
    } finally {
      client.release();
    }
  });
  return {
    ...result,
    detail: result.ok ? 'SELECT 1 succeeded' : result.error,
  };
}

function fmtUptime(sec) {
  const d = Math.floor(sec / 86400);
  const h = Math.floor((sec % 86400) / 3600);
  const m = Math.floor((sec % 3600)  / 60);
  const s = sec % 60;
  if (d > 0) return `${d}d ${h}h`;
  if (h > 0) return `${h}h ${m}m`;
  if (m > 0) return `${m}m ${s}s`;
  return `${s}s`;
}

// ─── Aggregation + persistence ──────────────────────────────────────────────────

// How often the background sampler records a snapshot into the DB.
const SAMPLE_INTERVAL_MS = parseInt(process.env.SAMPLE_INTERVAL_MS || '30000');

// Run all three checks in parallel; returns them tagged with name/tier.
async function runChecks() {
  const [nginx, self_, db] = await Promise.all([
    checkNginx(),
    checkSelf(),
    checkDatabase(),
  ]);
  return [
    { name: 'Nginx',      tier: 'web', ...nginx },
    { name: 'Node.js',    tier: 'app', ...self_ },
    { name: 'PostgreSQL', tier: 'db',  ...db    },
  ];
}

// Persist one row per service into the incidents table in a single INSERT.
// checked_at uses the column's DEFAULT NOW(), so all rows share one timestamp.
async function persistChecks(services) {
  const tuples = [];
  const values = [];
  services.forEach((s, i) => {
    const b = i * 4;
    tuples.push(`($${b + 1}, $${b + 2}, $${b + 3}, $${b + 4})`);
    values.push(s.name, s.ok ? 'up' : 'down', s.latencyMs, s.detail || s.error || null);
  });
  await pool.query(
    `INSERT INTO incidents (service, status, latency_ms, detail) VALUES ${tuples.join(', ')}`,
    values,
  );
}

// Background sampler — records check history on a fixed cadence so data accrues
// even with no traffic. Failures are logged, never fatal (retried next tick).
async function sampleAndStore() {
  try {
    await persistChecks(await runChecks());
  } catch (err) {
    console.error('sample failed:', err.message);
  }
}

// ─── Routes ───────────────────────────────────────────────────────────────────

// Main status endpoint — live snapshot of all three tiers (read-only).
app.get('/api/status', async (_req, res) => {
  const services  = await runChecks();
  const allOk     = services.every((s) => s.ok);

  res.status(allOk ? 200 : 503).json({
    overall:   allOk ? 'healthy' : 'degraded',
    checkedAt: new Date().toISOString(),
    services,
  });
});

// History endpoint — recent persisted checks, newest first.
app.get('/api/history', async (req, res) => {
  const limit = Math.min(Math.max(parseInt(req.query.limit || '50') || 50, 1), 500);
  try {
    const { rows } = await pool.query(
      `SELECT service, status, latency_ms, detail, checked_at
         FROM incidents
        ORDER BY checked_at DESC, id DESC
        LIMIT $1`,
      [limit],
    );
    res.json({ count: rows.length, incidents: rows });
  } catch (err) {
    res.status(503).json({ error: err.message });
  }
});

// Lightweight liveness/readiness probe (used by Nginx and by k8s probes)
app.get('/health', (_req, res) => res.json({ status: 'ok' }));

// ─── Start ────────────────────────────────────────────────────────────────────

app.listen(port, '0.0.0.0', () => {
  console.log(`Status monitor listening on :${port}`);
  console.log(`DB host: ${process.env.DB_HOST} · web host: ${WEB_HOST}`);
  console.log(`Sampling check history every ${SAMPLE_INTERVAL_MS}ms`);
});

// Background sampler: take one snapshot now, then on a fixed cadence.
sampleAndStore();
setInterval(sampleAndStore, SAMPLE_INTERVAL_MS);
