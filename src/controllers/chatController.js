const messagesStore = [];

/**
 * Get messages between two users or for a conversation
 */
exports.getMessages = (req, res) => {
  const { conversationId, userId } = req.query;

  let filtered = messagesStore;
  if (conversationId) {
    filtered = filtered.filter(m => m.conversationId === conversationId);
  } else if (userId) {
    filtered = filtered.filter(m => m.senderId === userId || m.receiverId === userId);
  }

  res.json({ success: true, count: filtered.length, messages: filtered });
};

/**
 * Send Message
 */
exports.sendMessage = (req, res) => {
  const { senderId, receiverId, content, conversationId } = req.body;

  if (!senderId || !content) {
    return res.status(400).json({ error: 'senderId and content are required' });
  }

  const message = {
    id: `msg_${Date.now()}`,
    conversationId: conversationId || `conv_${[senderId, receiverId].sort().join('_')}`,
    senderId,
    receiverId,
    content,
    timestamp: new Date().toISOString(),
    isRead: false,
  };

  messagesStore.push(message);
  res.json({ success: true, message });
};
