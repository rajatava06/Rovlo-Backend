const express = require('express');
const router = express.Router();
const notificationController = require('../controllers/notificationController');

router.post('/register-token', notificationController.registerFcmToken);
router.post('/send', notificationController.sendNotification);
router.get('/', notificationController.getNotifications);

module.exports = router;
