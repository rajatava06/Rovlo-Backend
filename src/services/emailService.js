const nodemailer = require('nodemailer');

class EmailService {
  constructor() {
    this.transporter = null;
    this.initTransporter();
  }

  initTransporter() {
    const host = process.env.SMTP_HOST;
    const user = process.env.SMTP_USER;
    const pass = process.env.SMTP_PASS;

    if (host && user && pass && user !== 'your_email@gmail.com') {
      this.transporter = nodemailer.createTransport({
        host: host,
        port: parseInt(process.env.SMTP_PORT || '587'),
        secure: process.env.SMTP_SECURE === 'true',
        auth: {
          user: user,
          pass: pass,
        },
      });
      console.log('✅ [EmailService] SMTP Transporter configured successfully.');
    } else {
      console.log('⚠️ [EmailService] SMTP credentials not provided or using defaults. Running in Demo/Development Mode.');
    }
  }

  /**
   * Send OTP Verification Code to User's Email
   */
  async sendOtpEmail(toEmail, otpCode) {
    const subject = `${otpCode} is your Rovlo verification code`;
    const htmlContent = `
      <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px; border: 1px solid #e0e0e0; border-radius: 12px; background-color: #ffffff;">
        <div style="text-align: center; margin-bottom: 20px;">
          <h1 style="color: #6C5CE7; margin: 0;">✈️ Rovlo</h1>
          <p style="color: #666; font-size: 14px;">Your Travel Companion</p>
        </div>
        <hr style="border: 0; border-top: 1px solid #eeeeee; margin: 20px 0;" />
        <h2 style="color: #2d3436; text-align: center;">Verification Code</h2>
        <p style="color: #555555; font-size: 16px; text-align: center;">Use the code below to log in or complete your registration on Rovlo:</p>
        <div style="background-color: #f1f0fe; padding: 16px; border-radius: 8px; text-align: center; margin: 24px 0;">
          <span style="font-size: 32px; font-weight: bold; letter-spacing: 6px; color: #6C5CE7;">${otpCode}</span>
        </div>
        <p style="color: #888888; font-size: 13px; text-align: center;">This code will expire in 10 minutes. If you did not request this code, please ignore this email.</p>
        <hr style="border: 0; border-top: 1px solid #eeeeee; margin: 20px 0;" />
        <p style="color: #aaaaaa; font-size: 12px; text-align: center;">&copy; ${new Date().getFullYear()} Rovlo Companion. All rights reserved.</p>
      </div>
    `;

    if (!this.transporter) {
      console.log(`[Demo Mode] OTP sent to ${toEmail}: ${otpCode}`);
      return { success: true, mode: 'demo', otpCode };
    }

    try {
      const info = await this.transporter.sendMail({
        from: process.env.EMAIL_FROM || '"Rovlo Companion" <noreply@rovlo.app>',
        to: toEmail,
        subject: subject,
        html: htmlContent,
      });
      console.log(`✅ [EmailService] OTP email sent to ${toEmail}: ${info.messageId}`);
      return { success: true, messageId: info.messageId };
    } catch (err) {
      console.error(`❌ [EmailService] Error sending email to ${toEmail}:`, err.message);
      // Fallback log so dev is not blocked
      return { success: false, error: err.message, fallbackCode: otpCode };
    }
  }

  /**
   * Send Email Notification
   */
  async sendNotificationEmail(toEmail, title, body) {
    const htmlContent = `
      <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px; border: 1px solid #e0e0e0; border-radius: 12px;">
        <h2 style="color: #6C5CE7;">${title}</h2>
        <p style="color: #333333; font-size: 15px; line-height: 1.5;">${body}</p>
        <br/>
        <p style="color: #888888; font-size: 12px;">The Rovlo Team</p>
      </div>
    `;

    if (!this.transporter) {
      console.log(`[Demo Mode] Email Notification to ${toEmail}: ${title}`);
      return { success: true, mode: 'demo' };
    }

    try {
      await this.transporter.sendMail({
        from: process.env.EMAIL_FROM || '"Rovlo Companion" <noreply@rovlo.app>',
        to: toEmail,
        subject: title,
        html: htmlContent,
      });
      return { success: true };
    } catch (err) {
      console.error(`❌ [EmailService] Error sending notification email:`, err.message);
      return { success: false, error: err.message };
    }
  }
}

module.exports = new EmailService();
