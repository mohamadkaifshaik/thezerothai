package config

// MessagingConfig holds the direct-message values that are neither a rate limit nor a daily quota (ADR-0027 D13). The
// SendMessage and read buckets and the daily send cap are RateLimitConfig fields; the new-conversation quota is a
// QuotaConfig field. Every value is > 0: a 0 would lock every user out of the feature or disable a cap, so startup fails
// instead.
type MessagingConfig struct {
	// NewAccountSendsPerDay is the SendMessage daily cap for accounts younger than Quota.NewAccountWindow
	// (MESSAGES_NEW_ACCOUNT_SENDS_PER_DAY, default 50; the standard value is RateLimit.MessagesSendsPerDay, 300). The
	// interceptor's DailyCap is one number per procedure, so the service applies this tier (W7-5).
	NewAccountSendsPerDay int
	// RequestMaxUnanswered is the most messages a sender may leave unanswered in a REQUEST conversation
	// (MESSAGES_REQUEST_MAX_UNANSWERED, default 3), enforced exactly in the send transaction.
	RequestMaxUnanswered int
	// PushesPerRecipientPerHour caps message pushes to one recipient (MESSAGES_PUSHES_PER_RECIPIENT_PER_HOUR, default 20;
	// per instance, 60/h with 3). Messages are still stored; only the FCM send is skipped.
	PushesPerRecipientPerHour int
	// ConversationCacheEntries is the size of the per-instance conversation cache (CACHE_MESSAGING_CONVERSATION_ENTRIES,
	// default 5,000).
	ConversationCacheEntries int
}

// loadMessaging reads and validates the MESSAGES_* and CACHE_MESSAGING_* keys; a value <= 0 fails startup.
func loadMessaging() (MessagingConfig, error) {
	var c MessagingConfig
	err := loadPositiveInts([]positiveInt{
		{&c.NewAccountSendsPerDay, "MESSAGES_NEW_ACCOUNT_SENDS_PER_DAY", 50},
		{&c.RequestMaxUnanswered, "MESSAGES_REQUEST_MAX_UNANSWERED", 3},
		{&c.PushesPerRecipientPerHour, "MESSAGES_PUSHES_PER_RECIPIENT_PER_HOUR", 20},
		{&c.ConversationCacheEntries, "CACHE_MESSAGING_CONVERSATION_ENTRIES", 5000},
	})
	return c, err
}
