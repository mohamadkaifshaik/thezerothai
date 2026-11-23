package apiserver

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"time"

	"connectrpc.com/connect"

	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/billing/v1/billingv1connect"
	"github.com/dzeroth/dzeroth/backend/internal/billing"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/mw"
)

func registerBillingLifecycle(l *identity.Lifecycle, bindings *billing.FirestoreBindings) error {
	if err := l.RegisterEraser(identity.BeforeIdentity, bindings); err != nil {
		return err
	}
	return l.RegisterExportSection(bindings)
}

// Share the existing five-minute cron, preserving its response and 30 s limit.
// No production Scheduler/IAM change is required to recover accepted work.
func withBillingRecovery(inner http.Handler, step trendsStep, log *slog.Logger) http.Handler {
	return withBillingRecoveryClock(inner, step, log, time.Now)
}

func withBillingRecoveryClock(inner http.Handler, step trendsStep, log *slog.Logger, now func() time.Time) http.Handler {
	if step == nil {
		return inner
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		started := now()
		rec := &statusRecorder{header: http.Header{}}
		inner.ServeHTTP(rec, r)
		if r.Method == http.MethodPost {
			left := 28*time.Second - now().Sub(started)
			if left >= billing.RecoveryAttemptBudget {
				ctx, cancel := context.WithTimeout(r.Context(), min(left, 15*time.Second))
				runBillingRecovery(ctx, step, log)
				cancel()
			} else {
				log.WarnContext(r.Context(), "billing_webhook_recovery", "outcome", "skipped_deadline")
			}
		}
		rec.replay(w)
	})
}
func runBillingRecovery(ctx context.Context, step trendsStep, log *slog.Logger) {
	defer func() {
		if recover() != nil {
			log.ErrorContext(ctx, "billing_webhook_recovery", "outcome", "panic")
		}
	}()
	if err := step.Refresh(ctx); err != nil {
		log.WarnContext(ctx, "billing_webhook_recovery", "outcome", "retry_pending")
	} else {
		log.InfoContext(ctx, "billing_webhook_recovery", "outcome", "complete")
	}
}
func billingRecoveryHandler(step trendsStep, log *slog.Logger, projectID string) http.Handler {
	return mw.RecoverHTTP(log, projectID, "billing_webhook_recovery", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
		defer cancel()
		if err := step.Refresh(ctx); err != nil {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	}))
}

type billingModule struct {
	postLimit      func(context.Context, string) (int, error)
	publishArticle func(context.Context, string) error
	recover        trendsStep
}

func wireBilling(cfg config.Config, log *slog.Logger, routes *routeTable, billingBindings *billing.FirestoreBindings) (billingModule, error) {
	var m billingModule
	billingServer := billing.NewServer(nil, nil, nil)
	if cfg.BillingWebhook.PurchasesEnabled && (!cfg.BillingWebhook.Enabled || (cfg.Env != "dev" && cfg.Env != "prod") || cfg.AuthEmulator || cfg.BillingSandbox.Enabled) {
		return billingModule{}, fmt.Errorf("real purchase rollout requires dev/prod, configured webhooks, and no emulators")
	}
	if cfg.BillingWebhook.Enabled {
		if (cfg.Env != "dev" && cfg.Env != "prod") || cfg.AuthEmulator || cfg.BillingSandbox.Enabled {
			return billingModule{}, fmt.Errorf("production billing webhooks require dev/prod without emulators or sandbox checkout")
		}
		products := map[string]billing.Product{}
		for id, product := range cfg.BillingWebhook.Products {
			products[id] = billing.Product{Store: product.Store, Entitlement: product.Entitlement}
		}
		provider, e := billing.NewRevenueCatProvider(cfg.BillingWebhook.SecretAPIKey, products, nil)
		if e != nil {
			return billingModule{}, fmt.Errorf("billing webhook provider configuration invalid")
		}
		reconciler, e := billing.NewReconciler(billingBindings, provider, nil)
		if e != nil {
			return billingModule{}, fmt.Errorf("billing webhook reconciliation configuration invalid")
		}
		environment := billing.Production
		if cfg.BillingWebhook.Environment == "SANDBOX" && cfg.Env == "dev" {
			environment = billing.Sandbox
		} else if cfg.BillingWebhook.Environment != "" && cfg.BillingWebhook.Environment != "PRODUCTION" {
			return billingModule{}, fmt.Errorf("billing receipt environment invalid")
		}
		identities, e := billing.NewIdentityService(billingBindings, environment, nil)
		if e != nil {
			return billingModule{}, fmt.Errorf("production billing identity configuration invalid")
		}
		server := billing.NewServer(identities, billingBindings, reconciler)
		if cfg.BillingWebhook.PurchasesEnabled {
			server.EnableStorePurchases(products)
		}
		billingServer = server
		access := verifiedBillingAccess{bindings: billingBindings, verifier: reconciler, now: time.Now, environment: environment}
		m.postLimit = access.postTextLimit
		m.publishArticle = access.publishArticle
		processor, e := billing.NewWebhookProcessor(billingBindings, reconciler)
		if e != nil {
			return billingModule{}, e
		}
		processor.ReadOnly = cfg.Degraded == config.DegradedReadonly
		if e = routes.revenuecat(processor, cfg.BillingWebhook.Authorization, cfg.BillingWebhook.SigningSecret, cfg.BillingWebhook.AppIDs, environment); e != nil {
			return billingModule{}, fmt.Errorf("billing webhook authentication configuration invalid")
		}
		m.recover = processor
		routes.internal("/internal/cron/billing-webhooks", billingRecoveryHandler(processor, log, cfg.ProjectID))
	}
	// Without configured billing, new article publication remains unavailable.
	if cfg.BillingSandbox.Enabled {
		if cfg.Env != "local" || cfg.ProjectID != "demo-dzeroth-local" || !cfg.AuthEmulator {
			return billingModule{}, fmt.Errorf("billing sandbox requires local demo project and Auth emulator")
		}
		bindings := billingBindings
		provider, e := billing.NewRevenueCatProvider(cfg.BillingSandbox.SecretAPIKey,
			map[string]billing.Product{
				"plus_monthly": {Store: "test_store", Entitlement: billing.PlusEntitlement},
				"monthly":      {Store: "test_store", Entitlement: billing.ProEntitlement},
			}, nil)
		if e != nil {
			return billingModule{}, fmt.Errorf("billing provider configuration invalid")
		}
		identities, e := billing.NewIdentityService(bindings, billing.Sandbox, nil)
		if e != nil {
			return billingModule{}, fmt.Errorf("billing identity configuration invalid")
		}
		reconciler, e := billing.NewReconciler(bindings, provider, nil)
		if e != nil {
			return billingModule{}, fmt.Errorf("billing reconciliation configuration invalid")
		}
		server := billing.NewServer(identities, bindings, reconciler)
		access := verifiedBillingAccess{bindings: bindings, verifier: reconciler, now: time.Now, environment: billing.Sandbox}
		m.postLimit = access.postTextLimit
		m.publishArticle = access.publishArticle
		server.EnableSandboxPurchases()
		billingServer = server
	}
	// Read-only operation must neither advertise checkout nor write verification
	// metadata through a status read. Existing account reads remain protected.
	if cfg.Degraded == config.DegradedReadonly {
		billingServer = billing.NewServer(nil, billingBindings, nil)
	}
	routes.connect(func(o ...connect.HandlerOption) (string, http.Handler) {
		return billingv1connect.NewBillingServiceHandler(billingServer, o...)
	})
	return m, nil
}
