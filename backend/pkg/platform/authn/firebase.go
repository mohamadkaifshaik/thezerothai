package authn

import (
	"context"
	"fmt"
	"sync"
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

// newAppCheckClient builds the SDK's App Check client. app.AppCheck fetches Google's signing keys (JWKS), so this
// is the one place that needs the network.
func newAppCheckClient(ctx context.Context, projectID string, opts ...option.ClientOption) (*appcheck.Client, error) {
	app, err := firebase.NewApp(ctx, &firebase.Config{ProjectID: projectID}, opts...)
	if err != nil {
		return nil, fmt.Errorf("authn: init firebase app: %w", err)
	}
	client, err := app.AppCheck(ctx)
	if err != nil {
		return nil, fmt.Errorf("authn: init app check client: %w", err)
	}
	return client, nil
}

// firebaseAppCheckVerifier wraps the Firebase Admin Go SDK's *appcheck.Client, built on first use: constructing
// the client fetches Google's signing keys, and a request that carries no token is rejected before the verifier
// is called, so a process (or a test) that never sees a token never needs the network. A failed build is not
// cached, so a transient outage heals on the next call. It fails closed: every error is returned to
// AppCheckInterceptor, which rejects the request in enforce mode exactly as it rejects an invalid token.
type firebaseAppCheckVerifier struct {
	build func(context.Context) (*appcheck.Client, error)

	mu     sync.Mutex
	client *appcheck.Client
}

// NewAppCheckVerifier returns an App Check verifier for the given project. It makes no network call; the client
// is built on the first VerifyToken. Use CheckAppCheck at process start to fail fast on a broken setup.
func NewAppCheckVerifier(_ context.Context, projectID string, opts ...option.ClientOption) (AppCheckVerifier, error) {
	return &firebaseAppCheckVerifier{build: func(ctx context.Context) (*appcheck.Client, error) {
		return newAppCheckClient(ctx, projectID, opts...)
	}}, nil
}

// CheckAppCheck builds the App Check client now and returns the error if it cannot, so cmd/api refuses to start
// with App Check unusable (the eager behaviour NewAppCheckVerifier had before it became lazy).
func CheckAppCheck(ctx context.Context, projectID string, opts ...option.ClientOption) error {
	_, err := newAppCheckClient(ctx, projectID, opts...)
	return err
}

func (v *firebaseAppCheckVerifier) get(ctx context.Context) (*appcheck.Client, error) {
	v.mu.Lock()
	defer v.mu.Unlock()
	if v.client != nil {
		return v.client, nil
	}
	// Detach from the first caller's context and never cancel it: the SDK hands this context to the goroutine
	// that refreshes Google's signing keys every 6 h, so cancelling it (when this request ends, or by a timeout)
	// would silently stop key refresh. The lock is held meanwhile, so concurrent first calls wait for one build
	// instead of racing; the SDK's own HTTP client bounds the fetch.
	c, err := v.build(context.WithoutCancel(ctx))
	if err != nil {
		return nil, err
	}
	v.client = c
	return c, nil
}

func (v *firebaseAppCheckVerifier) VerifyToken(ctx context.Context, token string) error {
	client, err := v.get(ctx)
	if err != nil {
		return err
	}
	if _, err := client.VerifyToken(token); err != nil {
		return fmt.Errorf("authn: verify app check token: %w", err)
	}
	return nil
}
