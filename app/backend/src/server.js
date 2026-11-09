require('dotenv').config();
const express=require('express');
const bodyParser=require('body-parser');
const cors=require('cors');
const client=require('prom-client');
const routes=require('./routes');

const app=express();
const PORT = process.env.PORT || 3000;
const NODE_ENV = process.env.NODE_ENV || 'development';

// ---------- Observability ----------
// Metrics for Prometheus (scraped from /metrics by the ServiceMonitor):
//  - default Node.js metrics: CPU, memory, event loop lag, GC (prefix "process_" / "nodejs_")
//  - http_request_duration_seconds: a histogram per method, route and status code.
//    Prometheus derives request rate, error rate and latency percentiles from it.
client.collectDefaultMetrics();
const httpDuration = new client.Histogram({
  name: 'http_request_duration_seconds',
  help: 'Duration of HTTP requests in seconds',
  labelNames: ['method', 'route', 'status_code'],
  buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5],
});

// One JSON log line per API request. Alloy ships stdout to Loki, where
// `{app="bmi-backend"} | json | status >= 500` filters on these fields.
const log = (level, msg, fields = {}) =>
  console.log(JSON.stringify({ time: new Date().toISOString(), level, msg, ...fields }));

app.use((req, res, next) => {
  if (req.path === '/metrics' || req.path === '/health') return next(); // probes/scrapes are noise
  const end = httpDuration.startTimer();
  const started = Date.now();
  res.on('finish', () => {
    // Use the route pattern (/api/measurements/:id), not the raw URL, to keep label values few.
    const route = req.route ? req.baseUrl + req.route.path : 'unmatched';
    end({ method: req.method, route, status_code: res.statusCode });
    log(res.statusCode >= 500 ? 'error' : 'info', 'request', {
      method: req.method, route, status: res.statusCode, duration_ms: Date.now() - started,
    });
  });
  next();
});

app.get('/metrics', async (req, res) => {
  res.set('Content-Type', client.register.contentType);
  res.end(await client.register.metrics());
});

// CORS configuration
const corsOptions = {
  origin: NODE_ENV === 'production'
    ? process.env.FRONTEND_URL || 'http://localhost'
    : ['http://localhost:5173', 'http://localhost:3000'],
  credentials: true,
  optionsSuccessStatus: 200
};

app.use(cors(corsOptions));
app.use(bodyParser.json());

// Health check endpoint
app.get('/health', (req, res) => {
  res.json({ status: 'ok', environment: NODE_ENV });
});

// API routes
app.use('/api', routes);

// 404 handler
app.use((req, res) => {
  res.status(404).json({ error: 'Route not found' });
});

// Error handler
app.use((err, req, res, next) => {
  log('error', 'unhandled error', { error: err.message, stack: err.stack });
  res.status(500).json({ error: 'Internal server error' });
});

// Start server
app.listen(PORT, () => {
  log('info', 'server started', { port: Number(PORT), environment: NODE_ENV });
});
