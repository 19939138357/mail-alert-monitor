import AppKit
import Foundation
let lines = [
    "告警抽查邮件2026年11月7日3次",
    "发件人：report@example.com",
    "收件人：operator@example.com",
    "时间：2026年11月7日 11:40",
    "大小：3 KB",
    "确认码：063827",
    "本告警邮件为抽查邮件，请在15分钟内完成操作。",
    "设备：示例设备-21（192.0.2.21）",
    "文件名：report_20261107.csv",
    "最后更新时间：2026-11-07 11:39:05",
    "状态：异常",
    "最后一段：请核对设备状态并填写确认码。"
]
let image=NSImage(size:NSSize(width:1200,height:780))
image.lockFocus()
NSColor.white.setFill()
NSBezierPath(rect:CGRect(x:0,y:0,width:1200,height:780)).fill()
let style:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:29),.foregroundColor:NSColor.black]
for (i,line) in lines.enumerated() {
    (line as NSString).draw(at:NSPoint(x:30,y:720-i*58),withAttributes:style)
}
image.unlockFocus()
let bitmap=NSBitmapImageRep(data:image.tiffRepresentation!)!
try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
