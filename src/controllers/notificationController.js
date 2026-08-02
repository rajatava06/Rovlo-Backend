const pushService = require('../services/pushService');
const emailService = require('../services/emailService');
const { userStore } = require('./authController');

const notificationsList = [];

/**
 * Register FCM Token for User
 */
exports.registerFcmToken = (req, res) => {
  const { userId, fcmToken } = req.body;

  if (!userId || !fcmToken) {
    return res.status(400).json({ error: 'userId and fcmToken are required' });
  }

  const user = userStore.get(userId);
  if (user) {
    user.fcmTokens = user.fcmTokens || [];
    if (!user.fcmTokens.includes(fcmToken)) {
      user.fcmTokens.push(fcmToken);
      userStore.set(userId, user);
    }
  }

  console.log(`📱 [NotificationController] Registered FCM token for user ${userId}`);
  return res.json({ success: true, message: 'FCM Token registered successfully' });
};

/**
 * Trigger Push Notification (and optional email)
 */
exports.sendNotification = async (req, res) => {
  const { title, body, userId, targetAudience = 'All Users', sendEmail = false } = req.body;

  if (!title || !body) {
    return res.status(400).json({ error: 'Title and body are required' });
  }

  const notification = {
    id: `notif_${Date.now()}`,
    title,
    body,
    sentAt: new Date().toISOString(),
    targetAudience,
    userId: userId || null,
  };

  notificationsList.unshift(notification);

  let pushResult = null;
  let emailResult = null;

  if (userId) {
    const targetUser = userStore.get(userId);
    if (targetUser && targetUser.fcmTokens && targetUser.fcmTokens.length > 0) {
      pushResult = await pushService.sendToDevice(targetUser.fcmTokens[0], title, body);
    }
    if (sendEmail && targetUser && targetUser.email) {
      emailResult = await emailService.sendNotificationEmail(targetUser.email, title, body);
    }
  } else {
    // Send to FCM topic 'all_users'
    pushResult = await pushService.sendToTopic('all_users', title, body);
  }

  return res.json({
    success: true,
    message: 'Notification processed',
    notification,
    pushResult,
    emailResult,
  });
};

/**
 * Get Notifications List
 */
exports.getNotifications = (req, res) => {
  res.json({ success: true, count: notificationsList.length, notifications: notificationsList });
};
