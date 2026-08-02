const { userStore } = require('./authController');

/**
 * Get All User Profiles
 */
exports.getAllUsers = (req, res) => {
  const users = Array.from(userStore.values());
  res.json({ success: true, count: users.length, users });
};

/**
 * Get User Profile by ID
 */
exports.getUserById = (req, res) => {
  const user = userStore.get(req.params.id);
  if (!user) {
    return res.status(404).json({ error: 'User profile not found' });
  }
  res.json({ success: true, user });
};

/**
 * Update Profile Details
 */
exports.updateProfile = (req, res) => {
  const userId = req.params.id;
  const user = userStore.get(userId);
  if (!user) {
    return res.status(404).json({ error: 'User profile not found' });
  }

  const updated = {
    ...user,
    ...req.body,
    updatedAt: new Date().toISOString(),
  };

  userStore.set(userId, updated);
  res.json({ success: true, message: 'Profile updated successfully', user: updated });
};

/**
 * Block / Unblock User
 */
exports.setBlocked = (req, res) => {
  const { id } = req.params;
  const { isBlocked } = req.body;

  const user = userStore.get(id);
  if (!user) {
    return res.status(404).json({ error: 'User not found' });
  }

  user.isBlocked = isBlocked ?? true;
  userStore.set(id, user);
  res.json({ success: true, user });
};
