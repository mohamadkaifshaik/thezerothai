// client_floor_wiring.go is the app version floor for messaging (plan 6 section 3.1, Task 3.B). The chain stamps the
// x-dz-client header into every request's context (clientinfo.Interceptor in chainInterceptors: one header read, no I/O);
// identity's GetMe, the MessagingService handler and the KeyService handler read it through their ClientFloor seams
// against these floors. With every floor 0 (the default) nothing changes for anyone.
package apiserver

import (
	"github.com/dzeroth/dzeroth/backend/pkg/platform/clientinfo"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
)

// clientFloors is CLIENT_FLOOR_ANDROID, CLIENT_FLOOR_WEB and CLIENT_FLOOR_IOS as the floors every module reads.
func clientFloors(cfg config.Config) clientinfo.Floors {
	return clientinfo.Floors{Android: cfg.ClientFloors.Android, Web: cfg.ClientFloors.Web, IOS: cfg.ClientFloors.IOS}
}
