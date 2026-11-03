//go:build openharmony && cgo

package tun

/*
#cgo LDFLAGS: -lhilog_ndk.z
#include <stdlib.h>
#include <hilog/log.h>

// OH_LOG_Print is a variadic macro: cgo cannot call it directly, so wrap it.
static void clashx_hlog(const char *tag, const char *msg) {
  OH_LOG_Print(LOG_APP, LOG_INFO, 0, tag, "%{public}s", msg);
}
*/
import "C"

import "unsafe"

// hlogRaw prints one already-formatted line to OHOS hilog.
//
// The core already forwards its logrus output to the ArkTS host, but that path
// is a NAPI threadsafe callback executed on the extension's JS thread: once the
// app is backgrounded OHOS parks that thread, so every diagnostic disappears
// exactly when traffic from *other* apps is the thing under investigation.
// hilog has no such dependency.
func hlogRaw(msg string) {
	tag := C.CString("FlClashX-Tun")
	payload := C.CString(msg)
	defer C.free(unsafe.Pointer(tag))
	defer C.free(unsafe.Pointer(payload))
	C.clashx_hlog(tag, payload)
}
