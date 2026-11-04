package apiserver

import (
	"cloud.google.com/go/firestore"
	"github.com/dzeroth/dzeroth/backend/internal/articles"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

func registerArticleLifecycle(l *identity.Lifecycle, client *firestore.Client) error {
	a := articles.NewLifecycle(client)
	if err := l.RegisterEraser(identity.BeforeIdentity, a); err != nil {
		return err
	}
	return l.RegisterExportSection(a)
}
