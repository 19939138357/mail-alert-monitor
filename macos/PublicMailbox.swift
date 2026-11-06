import AppKit
import ScreenCaptureKit

/// Public builds bind to a personally selected Safari page. Persist only its digest.
/// A change of page, window, sheet, application or browser session closes the input gate.
@MainActor enum PublicMailbox {
    struct Page {
        let digest:String
        let host:String
        let viewport:CGRect
    }

    nonisolated static func identity(_ url:URL, title:String)->String? {
        MailboxApproval.identity(url, title: title)
    }

    static func inspect(_ selected:SCWindow)->Page? {
        guard AXIsProcessTrusted(), selected.windowLayer==0,
              selected.owningApplication?.bundleIdentifier==SystemPortal.browserID,
              let title=selected.title,let window=SafariDevice.window(),
              SafariDevice.attribute(window,kAXTitleAttribute) as? String==title,
              SafariDevice.rect(window)==selected.frame,
              SafariDevice.attribute(window,kAXMinimizedAttribute) as? Bool==false,
              (SafariDevice.attribute(window,"AXSheets") as? [AXUIElement] ?? []).isEmpty else{return nil}
        var pid:pid_t=0
        guard AXUIElementGetPid(window,&pid) == .success,pid==selected.owningApplication?.processID else{return nil}
        var pages:[AXUIElement]=[],stack=[window],address:String?,inspected=0
        while let node=stack.popLast() {
            inspected+=1
            guard inspected<=1600 else{return nil}
            if SafariDevice.attribute(node,kAXRoleAttribute) as? String=="AXWebArea" {
                pages.append(node)
                if pages.count>1{return nil}
            } else {
                if SafariDevice.attribute(node,kAXIdentifierAttribute) as? String=="WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD" {
                    address=SafariDevice.attribute(node,kAXValueAttribute) as? String
                }
                stack.append(contentsOf:SafariDevice.attribute(node,kAXChildrenAttribute) as? [AXUIElement] ?? [])
            }
        }
        guard let page=pages.first,let attr=SafariDevice.attribute(page,kAXURLAttribute),
              let raw=(attr as? URL)?.absoluteString ?? (attr as? String),
              let url=SafariDevice.resolvedURL(raw,address:address),
              let digest=identity(url,title:title),let host=url.host,let frame=SafariDevice.rect(page) else{return nil}
        let viewport=frame.intersection(selected.frame)
        guard viewport.width>250,viewport.height>180 else{return nil}
        return Page(digest:digest,host:host,viewport:viewport)
    }
}
