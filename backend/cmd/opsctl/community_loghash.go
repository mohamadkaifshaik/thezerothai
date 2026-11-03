package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"

	"github.com/dzeroth/dzeroth/backend/internal/communities"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// communityHashForAudit is the community_hash that opsctl's community commands print (ADR-0031 D13a): the keyed
// logger.HashCommunity the API writes on its moderation request lines, so the operator's output and the logs agree. Without
// CURSOR_HMAC_KEY in the shell it is a marker, never the unkeyed digest the commands printed before then (the
// conversationHashForAudit precedent).
func communityHashForAudit(cid string) string {
	key := os.Getenv(cursorKeyEnv)
	if key == "" || logger.SetConversationKey([]byte(key)) != nil {
		return "unavailable(set-" + cursorKeyEnv + ")"
	}
	return logger.HashCommunity(cid)
}

// communityLogHash is `opsctl community loghash [--community CID] [--post ID] [--user UID]`: no Firestore, no project. It prints
// the keyed pseudonyms the API puts on its Communities moderation request lines so an operator can filter Logs Explorer by them:
// community_hash for a community id, post_hash for a post id, and for a uid both target_hash (the SetMemberRole target) and the
// plain uid_hash (that user's own request lines). Needs CURSOR_HMAC_KEY of the project whose logs are read; a secret rotation
// changes every hash, so use the version that was live when the lines were written. Cost: 0 reads, 0 writes.
func communityLogHash(args []string, key string, out, errOut io.Writer) error {
	fs := flag.NewFlagSet("community loghash", flag.ContinueOnError)
	fs.SetOutput(errOut)
	cid := fs.String("community", "", "community id (19 digits)")
	post := fs.String("post", "", "post id (19 digits)")
	user := fs.String("user", "", "user id")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 0 {
		return fmt.Errorf("community loghash: unexpected argument %q", fs.Arg(0))
	}
	if *cid == "" && *post == "" && *user == "" {
		return errors.New("community loghash needs at least one of --community CID, --post ID, --user UID")
	}
	if *cid != "" {
		if err := communities.ValidateCommunityID(*cid); err != nil {
			return errors.New("community loghash --community needs 19 digits")
		}
	}
	if *post != "" && !ids.ValidPostID(*post) {
		return errors.New("community loghash --post needs 19 digits")
	}
	if *user != "" && !ids.ValidUID(*user) {
		return errors.New("community loghash --user is not a valid user id")
	}
	if key == "" {
		return fmt.Errorf("community loghash needs %s in the environment: the project's cursor-hmac-key secret "+
			"(gcloud secrets versions access latest --secret=cursor-hmac-key --project=<project> | tr -d '\r')", cursorKeyEnv)
	}
	if err := logger.SetConversationKey([]byte(key)); err != nil {
		return err
	}
	if *cid != "" {
		fmt.Fprintf(out, "community_hash=%s\n", logger.HashCommunity(*cid))
	}
	if *post != "" {
		fmt.Fprintf(out, "post_hash=%s\n", logger.HashPost(*post))
	}
	if *user != "" {
		fmt.Fprintf(out, "target_hash=%s\nuid_hash=%s\n", logger.HashTarget(*user), logger.HashUID(*user))
	}
	return nil
}
