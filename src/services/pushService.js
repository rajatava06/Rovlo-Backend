const admin = require('firebase-admin');
const fs = require('fs');
const path = require('path');

class PushNotificationService {
  constructor() {
    this.initialized = false;
    this.initFirebase();
  }

  initFirebase() {
    try {
      const serviceAccountPath = process.env.FIREBASE_SERVICE_ACCOUNT_PATH 
        ? path.resolve(process.env.FIREBASE_SERVICE_ACCOUNT_PATH)
        : path.resolve(__dirname, '../../config/serviceAccountKey.json');

      if (fs.existsSync(serviceAccountPath)) {
        const serviceAccount = require(serviceAccountPath);
        admin.initializeApp({
          credential: admin.credential.cert(serviceAccount),
        });
        this.initialized = true;
        console.log('✅ [PushService] Firebase Admin SDK initialized for FCM Push Notifications.');
      } else {
        console.log('⚠️ [PushService] serviceAccountKey.json not found. FCM running in Demo/Log mode.');
      }
    } catch (err) {
      console.error('❌ [PushService] Firebase Admin init failed:', err.message);
    }
  }

  /**
   * Send FCM Push Notification to a target device token
   */
  async sendToDevice(fcmToken, title, body, data = {}) {
    if (!this.initialized) {
      console.log(`[Demo Push] Target Token: ${fcmToken} | Title: "${title}" | Body: "${body}"`);
      return { success: true, mode: 'demo' };
    }

    const message = {
      token: fcmToken,
      notification: {
        title,
        body,
      },
      data: {
        click_action: 'FLUTTER_NOTIFICATION_CLICK',
        ...data,
      },
    };

    try {
      const response = await admin.messaging().send(message);
      console.log(`✅ [PushService] Push Notification sent successfully:`, response);
      return { success: true, messageId: response };
    } catch (err) {
      console.error(`❌ [PushService] FCM send error:`, err.message);
      return { success: false, error: err.message };
    }
  }

  /**
   * Send FCM Push Notification to a topic (e.g., 'all_users')
   */
  async sendToTopic(topic, title, body, data = {}) {
    if (!this.initialized) {
      console.log(`[Demo Push Topic] Topic: ${topic} | Title: "${title}" | Body: "${body}"`);
      return { success: true, mode: 'demo' };
    }

    const message = {
      topic: topic,
      notification: {
        title,
        body,
      },
      data: data,
    };

    try {
      const response = await admin.messaging().send(message);
      console.log(`✅ [PushService] Topic notification sent:`, response);
      return { success: true, messageId: response };
    } catch (err) {
      console.error(`❌ [PushService] FCM topic send error:`, err.message);
      return { success: false, error: err.message };
    }
  }
}

module.exports = new PushNotificationService();
