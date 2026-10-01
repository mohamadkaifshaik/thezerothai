package posts

import "context"

// NopEvents is the PostEvents hook used until notifications ship (P6, ADR-0010): it does nothing. Mention and
// reply notifications will replace it with a Pub/Sub publisher without touching CreatePost or DeletePost.
type NopEvents struct{}

// Created implements PostEvents.
func (NopEvents) Created(context.Context, *Post) {}

// Deleted implements PostEvents.
func (NopEvents) Deleted(context.Context, string, string) {}

var _ PostEvents = NopEvents{}
