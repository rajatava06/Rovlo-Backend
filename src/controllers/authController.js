const emailService = require('../services/emailService');
const jwt = require('jsonwebtoken');

// In-memory OTP store for rapid performance (or MongoDB/Redis in production)
const otpStore = new Map();

// In-memory User profile store (mirrors Flutter AppUser model)
const userStore = new Map();

const JWT_SECRET = process.env.JWT_SECRET || 'rovlo_default_jwt_secret_2026';

/**
 * Request OTP for Email/Phone Login
 */
exports.requestOtp = async (req, res) => {
  const { email, phoneNumber } = req.body;

  if (!email && !phoneNumber) {
    return res.status(400).json({ error: 'Email or Phone number is required' });
  }

  const identifier = (email || phoneNumber).trim().toLowerCase();
  
  // Generate 6-digit OTP code (or 123456 in dev mode)
  const otpCode = process.env.NODE_ENV === 'development' ? '123456' : Math.floor(100000 + Math.random() * 900000).toString();
  
  // Store with 10 min expiration
  otpStore.set(identifier, {
    code: otpCode,
    expiresAt: Date.now() + 10 * 60 * 1000,
  });

  let emailResult = null;
  if (email) {
    emailResult = await emailService.sendOtpEmail(email, otpCode);
  }

  return res.json({
    message: 'OTP sent successfully',
    identifier,
    demoCode: process.env.NODE_ENV === 'development' ? '123456' : undefined,
    emailResult,
  });
};

/**
 * Verify OTP and Log In
 */
exports.verifyOtp = async (req, res) => {
  const { email, phoneNumber, code, name } = req.body;

  if (!code || (!email && !phoneNumber)) {
    return res.status(400).json({ error: 'Missing credentials or code' });
  }

  const identifier = (email || phoneNumber).trim().toLowerCase();
  const record = otpStore.get(identifier);

  // Accept code matching or demo code '123456'
  const isDemo = code.trim() === '123456';
  const isValid = record && record.code === code.trim() && record.expiresAt > Date.now();

  if (!isValid && !isDemo) {
    return res.status(400).json({ error: 'Invalid or expired OTP code' });
  }

  // Clear OTP
  otpStore.delete(identifier);

  // Retrieve or create User
  let userId = Array.from(userStore.values()).find(u => (u.email === identifier || u.phoneNumber === identifier))?.id;

  if (!userId) {
    userId = `usr_${Date.now()}_${Math.floor(Math.random() * 1000)}`;
    userStore.set(userId, {
      id: userId,
      createdAt: new Date().toISOString(),
      email: email ? identifier : null,
      phoneNumber: phoneNumber ? identifier : null,
      name: name || (email ? identifier.split('@')[0] : 'Traveller'),
      authMethod: email ? 'email' : 'phone',
      travelInterests: ['Backpacking', 'Sightseeing'],
      isVerified: false,
      subscriptionTier: 'free',
      fcmTokens: [],
    });
  }

  const user = userStore.get(userId);
  const token = jwt.sign({ id: user.id, email: user.email }, JWT_SECRET, { expiresIn: '30d' });

  return res.json({
    message: 'Authentication successful',
    token,
    user,
  });
};

/**
 * Social Sign In Handler (Google / Apple)
 */
exports.socialAuth = async (req, res) => {
  const { email, name, photoUrl, firebaseUid, authMethod } = req.body;

  if (!email) {
    return res.status(400).json({ error: 'Email is required for social authentication' });
  }

  const normalized = email.trim().toLowerCase();
  let user = Array.from(userStore.values()).find(u => u.email === normalized);

  if (!user) {
    const userId = firebaseUid || `usr_${Date.now()}`;
    user = {
      id: userId,
      createdAt: new Date().toISOString(),
      email: normalized,
      name: name || normalized.split('@')[0],
      photoUrl: photoUrl || `https://api.dicebear.com/7.x/avataaars/png?seed=${normalized}`,
      authMethod: authMethod || 'google',
      travelInterests: ['Culture', 'Photography'],
      isVerified: true,
      subscriptionTier: 'free',
      fcmTokens: [],
    };
    userStore.set(user.id, user);
  } else if (photoUrl || name) {
    user.photoUrl = photoUrl || user.photoUrl;
    user.name = name || user.name;
    userStore.set(user.id, user);
  }

  const token = jwt.sign({ id: user.id, email: user.email }, JWT_SECRET, { expiresIn: '30d' });

  return res.json({
    message: 'Social login successful',
    token,
    user,
  });
};

exports.userStore = userStore;
