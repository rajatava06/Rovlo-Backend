require('dotenv').config();
const express = require('express');
const cors = require('cors');

const authRoutes = require('./routes/authRoutes');
const userRoutes = require('./routes/userRoutes');
const notificationRoutes = require('./routes/notificationRoutes');
const chatRoutes = require('./routes/chatRoutes');

const app = express();
const PORT = process.env.PORT || 5000;

// Middleware
app.use(cors());
app.use(express.json());
app.use(express.urlencoded({ extended: true }));

// Health Check Endpoint
app.get('/health', (req, res) => {
  res.json({
    status: 'OK',
    service: 'Rovlo Backend API',
    timestamp: new Date().toISOString(),
    env: process.env.NODE_ENV || 'development',
  });
});

// API Routes
app.use('/api/auth', authRoutes);
app.use('/api/users', userRoutes);
app.use('/api/notifications', notificationRoutes);
app.use('/api/chat', chatRoutes);

// Error Handling Middleware
app.use((err, req, res, next) => {
  console.error('❌ Server Error:', err.stack);
  res.status(500).json({ error: 'Internal Server Error', message: err.message });
});

// Start Server
app.listen(PORT, () => {
  console.log(`
  🚀 ===================================================
  ✈️  ROVLO BACKEND SERVER IS RUNNING!
  📡  Listening on Port: ${PORT}
  🔗  Health Check: http://localhost:${PORT}/health
  📬  Auth Routes: http://localhost:${PORT}/api/auth
  👥  User Routes: http://localhost:${PORT}/api/users
  🔔  Notification Routes: http://localhost:${PORT}/api/notifications
  ===================================================
  `);
});
