//
//  DVLiveDiagnostics.swift
//  DVLive
//
//  Единая точка входа headless-режимов приложения (без камеры и FireWire):
//
//    --list-audio-devices                      устройства CoreAudio
//    --audio-selftest [сек]                    тон 1 кГц (L) / 3 кГц (R) в приёмник
//    --dv-audio-selftest <файл.dv>             .dv → DVAudioExtractor → плеер, 25 к/с
//    --audio-render-selftest <файл.dv> --pcm-out <файл>
//                                              тот же граф офлайн-рендером
//    --dv-frame-selftest <файл.dv> --png <файл>
//                                              геометрия кадра: режим, растяжка, PNG
//

import Foundation

public enum DVLiveDiagnostics {

    public static func runHeadless(arguments: [String]) -> Int32? {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            let next = arguments[index + 1]
            return next.hasPrefix("--") ? nil : next
        }

        if let path = value("--dv-frame-selftest") {
            guard let png = value("--png") else {
                fputs("Использование: --dv-frame-selftest <файл.dv> --png <файл.png>\n", stderr)
                return 2
            }
            return DVFrameDebug.writeFrame(from: path, to: png)
        }

        return DVAudioDiagnostics.runAudioHeadless(arguments: arguments)
    }
}
