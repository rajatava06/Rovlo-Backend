# ✈️ Rovlo Backend Server

Production-ready Node.js & Express backend for **Rovlo — Travel Companion App**.

---

## 🌟 Features

- **Authentication & Email OTP**: Email / Phone OTP login with Nodemailer integration.
- **Push Notification System**: Firebase Cloud Messaging (FCM) integration for device & topic notifications.
- **User Profile Management**: REST API endpoints for user profiles, travel interests, verification, and blocking.
- **Chat & Messaging**: Real-time message store endpoints for traveler connections.
- **Environment & Security**: Configurable `.env` support with `.env.example` ready for safe Git pushing.

---

## 🚀 Getting Started

### 1. Installation

```bash
cd Rovlo-Backend
npm install
```

### 2. Configure Environment Variables (`.env`)

Copy `.env.example` to `.env`:

```bash
cp .env.example .env
```

Edit `.env` with your credentials:

```env
PORT=5000
JWT_SECRET=your_jwt_secret

# Email OTP Credentials (Nodemailer)
SMTP_HOST=smtp.gmail.com
SMTP_PORT=587
SMTP_USER=your_email@gmail.com
SMTP_PASS=your_app_password
EMAIL_FROM="Rovlo Companion <noreply@rovlo.app>"

# Google Maps API Key
GOOGLE_MAPS_API_KEY=AIzaSyYourKeyHere
```

### 3. Run the Server

```bash
# Development Mode with live reload
npm run dev

# Production Mode
npm start
```

Server will run at `http://localhost:5000`.

---

## 📡 API Endpoints Summary

| Method | Endpoint | Description |
|---|---|---|
| `GET` | `/health` | Server Health Check |
| `POST` | `/api/auth/send-otp` | Send Email / Phone OTP |
| `POST` | `/api/auth/verify-otp` | Verify OTP Code & Login |
| `POST` | `/api/auth/social` | Sync Google / Apple Sign In |
| `GET` | `/api/users` | Get List of User Profiles |
| `PUT` | `/api/users/:id` | Update User Profile |
| `POST` | `/api/notifications/register-token` | Register Device FCM Token |
| `POST` | `/api/notifications/send` | Send Push Notification |
| `GET` | `/api/chat` | Get Conversation Messages |
| `POST` | `/api/chat/send` | Send Message |
