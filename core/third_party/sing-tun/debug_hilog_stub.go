//go:build !(openharmony && cgo)

package tun

// hlogRaw is a no-op everywhere except OHOS; see debug_hilog_ohos.go.
func hlogRaw(string) {}
