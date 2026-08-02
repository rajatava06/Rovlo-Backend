const express = require('express');
const router = express.Router();
const authController = require('../controllers/authController');

router.post('/send-otp', authController.requestOtp);
router.post('/verify-otp', authController.verifyOtp);
router.post('/social', authController.socialAuth);

module.exports = router;
