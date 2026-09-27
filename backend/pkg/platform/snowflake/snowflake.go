// Package snowflake generates 64-bit, time-ordered IDs for posts/media (ADR-0003, rule 1): 41 bits of
// milliseconds since 2026-01-01T00:00:00Z, 10 bits of node id (random per process start), 12 bits of
// per-millisecond sequence. Rendered as a 19-digit zero-padded decimal string so lexicographic order
// equals time order in Firestore doc IDs and cursors.
package snowflake

import (
	"crypto/rand"
	"encoding/binary"
	"fmt"
	"sync"
	"time"
)

const (
	nodeBits = 10
	seqBits  = 12

	maxNode = (1 << nodeBits) - 1
	maxSeq  = (1 << seqBits) - 1

	nodeShift = seqBits
	timeShift = seqBits + nodeBits
)

// Epoch is the custom epoch fixed by ADR-0003. Never change it after any ID has been generated in a
// live environment — doing so breaks time ordering and can produce collisions.
var Epoch = time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)

var epochMillis = Epoch.UnixMilli()

// Node generates IDs. Safe for concurrent use; construct one per process (main.go) and share it.
type Node struct {
	mu         sync.Mutex
	node       int64
	lastMillis int64
	seq        int64
	now        func() time.Time
}

// NewNode builds a Node with a random 10-bit node id (collisions across the small number of Cloud Run
// instances are astronomically unlikely, and a Firestore Create() AlreadyExists is the backstop —
// ADR-0003: "regenerate and retry once").
func NewNode() (*Node, error) {
	var b [2]byte
	if _, err := rand.Read(b[:]); err != nil {
		return nil, fmt.Errorf("snowflake: read random node id: %w", err)
	}
	node := int64(binary.BigEndian.Uint16(b[:])) & maxNode
	return &Node{node: node, now: time.Now}, nil
}

// Generate returns the next ID as a 19-digit zero-padded decimal string.
func (n *Node) Generate() string {
	return fmt.Sprintf("%019d", n.generateInt())
}

func (n *Node) generateInt() int64 {
	n.mu.Lock()
	defer n.mu.Unlock()

	now := n.millisSinceEpoch()
	switch {
	case now == n.lastMillis:
		n.seq = (n.seq + 1) & maxSeq
		if n.seq == 0 {
			// Sequence exhausted (>4096 ids this ms from this node): spin to the next millisecond.
			for now <= n.lastMillis {
				time.Sleep(100 * time.Microsecond)
				now = n.millisSinceEpoch()
			}
		}
	case now < n.lastMillis:
		// Clock moved backwards (NTP adjustment). Wait it out rather than risk a duplicate/out-of-order id.
		for now < n.lastMillis {
			time.Sleep(100 * time.Microsecond)
			now = n.millisSinceEpoch()
		}
		n.seq = 0
	default:
		n.seq = 0
	}
	n.lastMillis = now
	return (now << timeShift) | (n.node << nodeShift) | n.seq
}

func (n *Node) millisSinceEpoch() int64 {
	return n.now().UTC().UnixMilli() - epochMillis
}
