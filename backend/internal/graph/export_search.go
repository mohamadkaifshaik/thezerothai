package graph

import graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"

// RelationshipFor is the caller's Relationship to uid computed from the caller's own Snapshot only (ADR-0008 D4): follow
// state incl. REQUESTED, blocking, muting; never followed_by, never BlockedBy. 0 reads. It is the one builder other
// modules (search, ADR-0028 D2) use for a UserListItem row, so a list outside graph renders exactly as a graph list.
func RelationshipFor(snap Snapshot, uid string) Relationship { return relationshipFor(snap, uid) }

// ListItemsToProto converts rows to graphv1.UserListItem with the one builder the graph lists use (AuthorSnapshot with
// the 96 px avatar thumb and the is_private lock badge, the Relationship, since only when set).
func ListItemsToProto(items []ListItem) []*graphv1.UserListItem { return toProtoListItems(items) }
