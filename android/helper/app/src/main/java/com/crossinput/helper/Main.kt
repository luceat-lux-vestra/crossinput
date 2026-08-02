package com.crossinput.helper

import android.os.Looper

/**
 * Android helper 진입점.
 * 실행: adb shell app_process -cp /data/local/tmp/crossinput-helper.apk / com.crossinput.helper.Main
 *
 * 스켈레톤 — CXI 프로토콜 루프는 Phase 2에서 구현.
 */
object Main {
    @JvmStatic
    fun main(vararg args: String) {
        Looper.prepare()

        // TODO(B-01): CXI 헤더 파싱 루프 (stdin)
        // TODO(B-02): DisplayManager display discovery + DISPLAY_LIST 전송
        // TODO(B-03): UHID 생성/주입 (/dev/uhid)
        // TODO(B-04): SELECT_DISPLAY 라우팅

        Looper.loop()
    }
}
