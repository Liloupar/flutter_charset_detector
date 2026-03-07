#if os(iOS)
    import Flutter
#elseif os(macOS)
    import FlutterMacOS
#endif
import UniversalDetector2
import Foundation
import CoreFoundation

public class SwiftFlutterCharsetDetectorPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        #if os(iOS)
            let messenger = registrar.messenger()
        #else
            let messenger = registrar.messenger
        #endif
        let channel = FlutterMethodChannel(name: "flutter_charset_detector", binaryMessenger: messenger)
        let instance = SwiftFlutterCharsetDetectorPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "autoDecode":
            handleAutoDecode(call, result)
        case "detect":
            handleDetect(call, result)
        default:
            result(FlutterError(code: "UnsupportedMethod", message: "\(call.method) is not supported", details: nil))
        }
    }

    func handleAutoDecode(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String:Any?] else {
            result(FlutterError(code: "MissingArgs", message: "Required arguments missing", details: "\(call.method) requires 'data'"))
            return
        }
        guard let data = args["data"] as? FlutterStandardTypedData else {
            result(FlutterError(code: "MissingArg", message: "Required argument missing", details: "\(call.method) requires 'data'"))
            return
        }
        // Elsewhere in the plugin we use the term "charset" instead of
        // "encoding", but for consistency with iOS APIs we use the term in a
        // limited capacity here
        guard let encodingName = UniversalDetector.encodingAsString(with: data.data) else {
            result(FlutterError(code: "DetectionFailed", message: "The charset could not be detected", details: nil))
            return
        }
        let encoding = CFStringConvertIANACharSetNameToEncoding(encodingName as CFString)
        guard encoding != kCFStringEncodingInvalidId else {
            result(FlutterError(code: "UnsupportedCharset", message: "The detected charset \(encodingName) is not supported.", details: nil))
            return
        }
        let nsEncoding = CFStringConvertEncodingToNSStringEncoding(encoding)
        var decoded: NSString?

        // 针对 UTF-8 的容错
        if decoded == nil && encoding == CFStringBuiltInEncodings.UTF8.rawValue {
            decoded = String(decoding: data.data, as: UTF8.self) as NSString
        }
        if decoded == nil {
            print("The data could not be decoded, Detected charset: \(encodingName)")
            if encodingName == "GB18030" {
                // 尝试修复 GB18030 编码
                let correctedData = dataByHealingGB18030Stream(data: data.data)
                decoded = NSString(data: correctedData, encoding: nsEncoding)
                if decoded == nil {
                    print("The data could not be fix, Detected charset: \(encodingName)")
                }
            }
        }
        if decoded == nil {
            result(FlutterError(code: "DecodingFailed", message: "The data could not be decoded", details: "Detected charset: \(encodingName)"))
            return
        }
        result([
            "charset": encodingName,
            "string": decoded
        ])
    }

    func handleDetect(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String:Any?] else {
            result(FlutterError(code: "MissingArgs", message: "Required arguments missing", details: "\(call.method) requires 'data'"))
            return
        }
        guard let data = args["data"] as? FlutterStandardTypedData else {
            result(FlutterError(code: "MissingArg", message: "Required argument missing", details: "\(call.method) requires 'data'"))
            return
        }
        // Elsewhere in the plugin we use the term "charset" instead of
        // "encoding", but for consistency with iOS APIs we use the term in a
        // limited capacity here
        guard let encodingName = UniversalDetector.encodingAsString(with: data.data) else {
            result(FlutterError(code: "DetectionFailed", message: "The charset could not be detected", details: nil))
            return
        }
        result(encodingName);
    }
    
    /*
     GB18030(兼容GB2312)编码验证与校正
     
     字节结构
     单字节，其值从0到0x7F。
     双字节，第一个字节的值从0x81到0xFE，第二个字节的值从0x40到0xFE（不包括0x7F）。
     四字节，第一个字节的值从0x81到0xFE，第二个字节的值从0x30到0x39，第三个字节从0x81到0xFE，第四个字节从0x30到0x39。
     因为网页 GB2312是双字节编码,所以我仅实现了GB18030单字节和双字节编码的验证与校正
     
     https://zh.wikipedia.org/wiki/GB_18030
     https://zh.wikipedia.org/wiki/GB_2312
     */
    func replaceInvalidGB18030Charset(data: Data) -> Data {
        var result = data
        let replacement: [UInt8] = [65, 65, 65, 65] // 'A','A','A','A' in ASCII
        var loc = 0
        
        while loc < result.count {
            let buffer = result[loc]
            
            if buffer == 0xFF {
                // 非法字符 0xFF
                result.replaceSubrange(loc..<loc+1, with: replacement[0...0])
                loc += 1
            } else if (buffer & 0x80) == 0 {
                // 单字节 ASCII 码
                loc += 1
            } else {
                // 大于 0x80 的双字节或者四字节, 要根据下一位判断
                loc += 1
                if loc >= result.count {
                    break
                }
                
                let nextBuffer = result[loc]
                
                if nextBuffer != 0xFF && ((nextBuffer & 0x40) == 0x40 || (nextBuffer & 0x80) == 0x80) {
                    // 双字节
                    loc += 1
                } else {
                    // 回退第一位
                    loc -= 1
                    result.replaceSubrange(loc..<loc+1, with: replacement[0...0])
                    loc += 1
                }
            }
        }
        
        return result
    }
    
    
    func dataByHealingGB18030Stream(data: Data) -> Data {
        guard data.count > 0 else { return data }
        
        let replacementCharacter = "?"
        let enc = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        
        // 使用 autoreleasepool 来管理内存
        return autoreleasepool { () -> Data in
            let replacementCharacterData = replacementCharacter.data(using: String.Encoding(rawValue: enc))!
            
            let resultData = NSMutableData(capacity: data.count)!
            let bytes = [UInt8](data)
            
            let bufferMaxSize = 1024
            var buffer = [UInt8](repeating: 0, count: bufferMaxSize)
            var bufferIndex = 0
            var byteIndex = 0
            var invalidByte = false
            
            func flushBuffer() {
                if bufferIndex > 0 {
                    resultData.append(&buffer, length: bufferIndex)
                    bufferIndex = 0
                }
            }
            
            func checkBuffer() {
                if (bufferIndex + 5) >= bufferMaxSize {
                    resultData.append(&buffer, length: bufferIndex)
                    bufferIndex = 0
                }
            }
            
            while byteIndex < data.count {
                let byte = bytes[byteIndex]
                
                if byte >= 0 && byte <= 0x7f {
                    checkBuffer()
                    buffer[bufferIndex] = byte
                    bufferIndex += 1
                } else if byte >= 0x81 && byte <= 0xfe {
                    if byteIndex + 1 >= data.count {
                        flushBuffer()
                        return resultData as Data
                    }
                    
                    let byte2 = bytes[byteIndex + 1]
                    if byte2 >= 0x40 && byte2 <= 0xfe && byte2 != 0x7f {
                        let tuple: [UInt8] = [byte, byte2]
                        if let cfstr = CFStringCreateWithBytes(kCFAllocatorDefault, tuple, 2, CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue), false) {
                            //                    CFRelease(cfstr)
                            checkBuffer()
                            buffer[bufferIndex] = byte
                            buffer[bufferIndex + 1] = byte2
                            bufferIndex += 2
                            byteIndex += 1
                        } else {
                            invalidByte = true
                        }
                    } else if byte2 >= 0x30 && byte2 <= 0x39 {
                        if byteIndex + 3 >= data.count {
                            flushBuffer()
                            return resultData as Data
                        }
                        
                        let byte3 = bytes[byteIndex + 2]
                        
                        if byte3 >= 0x81 && byte3 <= 0xfe {
                            let byte4 = bytes[byteIndex + 3]
                            
                            if byte4 >= 0x30 && byte4 <= 0x39 {
                                let tuple: [UInt8] = [byte, byte2, byte3, byte4]
                                if let cfstr = CFStringCreateWithBytes(kCFAllocatorDefault, tuple, 4, CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue), false) {
                                    //                            CFRelease(cfstr)
                                    checkBuffer()
                                    buffer[bufferIndex] = byte
                                    buffer[bufferIndex + 1] = byte2
                                    buffer[bufferIndex + 2] = byte3
                                    buffer[bufferIndex + 3] = byte4
                                    bufferIndex += 4
                                    byteIndex += 3
                                } else {
                                    invalidByte = true
                                }
                            } else {
                                invalidByte = true
                            }
                        } else {
                            invalidByte = true
                        }
                    } else {
                        invalidByte = true
                    }
                    
                    if invalidByte {
                        invalidByte = false
                        flushBuffer()
                        resultData.append(replacementCharacterData)
                    }
                }
                byteIndex += 1
            }
            
            flushBuffer()
            return resultData as Data
        }
    }
    
}
