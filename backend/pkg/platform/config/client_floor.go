package config

import "fmt"

// clientFloorMax is the highest floor. It must equal pkg/platform/clientinfo.MaxLevel (config does not import that
// package; TestClientFloorMax_IsClientinfoMaxLevel pins the two together).
const clientFloorMax = 1000

// ClientFloorsConfig is the app version floor for messaging (plan 6 section 3.1): the lowest capability level each
// platform's build must send in its x-dz-client header to use direct messages and the key directory. Below it, GetMe
// hides the messaging family and lists messaging in features_needing_update, and every MessagingService and KeyService
// RPC answers FEATURE_DISABLED with update_required. A request with no header or an unknown platform is held to the
// highest of the three. Not a feature flag (no ceiling entry): plain operator ints, 0..1000, default 0 = no floor.
type ClientFloorsConfig struct {
	// Android is CLIENT_FLOOR_ANDROID (default 0).
	Android int
	// Web is CLIENT_FLOOR_WEB (default 0).
	Web int
	// IOS is CLIENT_FLOOR_IOS (default 0).
	IOS int
}

// loadClientFloors reads the three CLIENT_FLOOR_* keys; a value outside 0..1000 or not an integer fails startup.
func loadClientFloors() (ClientFloorsConfig, error) {
	var c ClientFloorsConfig
	for _, f := range []struct {
		dst *int
		key string
	}{
		{&c.Android, "CLIENT_FLOOR_ANDROID"},
		{&c.Web, "CLIENT_FLOOR_WEB"},
		{&c.IOS, "CLIENT_FLOOR_IOS"},
	} {
		n, err := getInt(f.key, 0)
		if err != nil {
			return ClientFloorsConfig{}, err
		}
		if n < 0 || n > clientFloorMax {
			return ClientFloorsConfig{}, fmt.Errorf("config: %s must be between 0 and %d (got %d)", f.key, clientFloorMax, n)
		}
		*f.dst = n
	}
	return c, nil
}
