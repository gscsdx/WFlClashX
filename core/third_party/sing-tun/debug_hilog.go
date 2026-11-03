package tun

import "fmt"

// hlog formats a diagnostic line and hands it to the platform sink. Kept out of
// the cgo file because cgo's parser rejects a variadic "...any" parameter.
func hlog(format string, args ...any) {
	if len(args) == 0 {
		hlogRaw(format)
		return
	}
	hlogRaw(fmt.Sprintf(format, args...))
}
