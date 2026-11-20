CREATE TABLE "vault_device" ("slot" TEXT NOT NULL, "device_id" BLOB NOT NULL, "device_state" BLOB NOT NULL, PRIMARY KEY ("slot"));
CREATE TABLE "vault_groups" ("conversation_id" TEXT NOT NULL, "generation" INTEGER NOT NULL, "epoch" INTEGER NOT NULL, "state" BLOB NOT NULL, "pending_commit" BLOB NOT NULL, PRIMARY KEY ("conversation_id"));
CREATE TABLE "vault_messages" ("conversation_id" TEXT NOT NULL, "message_id" TEXT NOT NULL, "sort_key" TEXT NOT NULL, "state" TEXT NOT NULL, "generation" INTEGER NOT NULL, "epoch" INTEGER NOT NULL, "from_self" BLOB NOT NULL, "content" BLOB NULL, PRIMARY KEY ("conversation_id", "message_id"));
CREATE INDEX vault_messages_by_sort ON vault_messages (conversation_id, sort_key);
CREATE TABLE "vault_meta" ("meta_key" TEXT NOT NULL, "owner_uid" TEXT NOT NULL, "schema_version" INTEGER NOT NULL, "sentinel" BLOB NOT NULL, PRIMARY KEY ("meta_key"));
CREATE TABLE "vault_outbox" ("idempotency_key" TEXT NOT NULL, "conversation_id" TEXT NULL, "sort_key" TEXT NOT NULL, "generation" INTEGER NOT NULL, "epoch" INTEGER NOT NULL, "recipient_user_id" BLOB NULL, "ciphertext" BLOB NOT NULL, "report_commitment" BLOB NOT NULL, "content" BLOB NOT NULL, "attempts" BLOB NOT NULL, "last_error" BLOB NULL, PRIMARY KEY ("idempotency_key"));
CREATE TABLE "vault_settings" ("setting_key" TEXT NOT NULL, "value" BLOB NOT NULL, PRIMARY KEY ("setting_key"));
PRAGMA user_version = 1;
