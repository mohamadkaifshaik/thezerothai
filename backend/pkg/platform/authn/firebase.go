package authn

import (
	"context"
	"fmt"
	"time"

	firebase "firebase.google.com/go/v4"
	"firebase.google.com/go/v4/appcheck"
	fbauth "firebase.google.com/go/v4/auth"
	"google.golang.org/api/option"
)

// firebaseIDTokenVerifier wraps the Firebase Admin Go SDK's *auth.Client. The SDK caches Google's
// public signing keys in-process and automatically verifies emulator-issued (unsigned) tokens when
// FIREBASE_AUTH_EMULATOR_HOST is set, so no branching is needed here for local dev.
type firebaseIDTokenVerifier struct {
	client *fbauth.Client
}

// NewIDTokenVerifier builds a verifier for the given project. ctx is only used for the initial client
// construction (cheap: no network call happens until the first VerifyIDToken).
func NewIDTokenVerifier(ctx context.Context, projectID string, opts ...option.ClientOption) (IDTokenVerifier, error) {
	app, err := firebase.NewApp(ctx, &firebase.Config{ProjectID: projectID}, opts...)
	if err != nil {
		return nil, fmt.Errorf("authn: init firebase app: %w", err)
	}
	client, err := app.Auth(ctx)
	if err != nil {
		return nil, fmt.Errorf("authn: init firebase auth client: %w", err)
	}
	return &firebaseIDTokenVerifier{client: client}, nil
}

func (v *firebaseIDTokenVerifier) VerifyIDToken(ctx context.Context, idToken string) (Claims, error) {
	tok, err := v.client.VerifyIDToken(ctx, idToken)
	if err != nil {
		return Claims{}, fmt.Errorf("authn: verify id token: %w", err)
	}
	claims := Claims{UID: tok.UID}
	if ev, ok := tok.Claims["email_verified"].(bool); ok {
		claims.EmailVerified = ev
	}
	if firebaseClaim, ok := tok.Claims["firebase"].(map[string]interface{}); ok {
		if provider, ok := firebaseClaim["sign_in_provider"].(string); ok {
			claims.SignInProvider = provider
		}
	}
	if authTime, ok := tok.Claims["auth_time"].(float64); ok {
		claims.AuthTime = time.Unix(int64(authTime), 0)
	}
	return claims, nil
}

// firebaseAppCheckVerifier wraps the Firebase Admin Go SDK's *appcheck.Client.
type firebaseAppCheckVerifier struct {
	client *appcheck.Client
}

// NewAppCheckVerifier builds an App Check verifier for the given project.
func NewAppCheckVerifier(ctx context.Context, projectID string, opts ...option.ClientOption) (AppCheckVerifier, error) {
	app, err := firebase.NewApp(ctx, &firebase.Config{ProjectID: projectID}, opts...)
	if err != nil {
		return nil, fmt.Errorf("authn: init firebase app: %w", err)
	}
	client, err := app.AppCheck(ctx)
	if err != nil {
		return nil, fmt.Errorf("authn: init app check client: %w", err)
	}
	return &firebaseAppCheckVerifier{client: client}, nil
}

func (v *firebaseAppCheckVerifier) VerifyToken(ctx context.Context, token string) error {
	_, err := v.client.VerifyToken(token)
	if err != nil {
		return fmt.Errorf("authn: verify app check token: %w", err)
	}
	return nil
}
