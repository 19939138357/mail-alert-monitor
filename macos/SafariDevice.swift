import AppKit
import ApplicationServices

// Match the actual device table, then use the first browser icon in its tools cell.
// The table layout was verified in Safari; no stored session URL or fixed screen position.
@MainActor enum SafariDevice {
    enum State { case remote, devices, login, other }
    static var rememberedPortal:(AXUIElement,AXUIElement)?
    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,name as CFString,&result) == .success else{return nil}
        return result
    }
    static func text(_ element: AXUIElement) -> String {
        [kAXValueAttribute,kAXTitleAttribute,kAXDescriptionAttribute].compactMap{attribute(element,$0) as? String}.first(where:{!$0.isEmpty}) ?? ""
    }
    static func children(_ element: AXUIElement) -> [AXUIElement] {
        let children=attribute(element,kAXChildrenAttribute) as? [AXUIElement] ?? []
        let rows=attribute(element,kAXRowsAttribute) as? [AXUIElement] ?? []
        return children+rows.filter{row in !children.contains{CFEqual($0,row)}}
    }
    static func nodes(_ root: AXUIElement) -> [AXUIElement] {
        var stack=[root], result:[AXUIElement]=[]
        while let item=stack.popLast(),result.count<4000 {
            if result.contains(where:{CFEqual($0,item)}){continue}
            result.append(item);stack.append(contentsOf:children(item).reversed())
        }
        return result
    }
    static func contains(_ cell: AXUIElement,_ expected:String) -> Bool {
        nodes(cell).contains{ text($0).trimmingCharacters(in:.whitespacesAndNewlines)==expected }
    }
    static func window() -> AXUIElement? {
        guard let app=NSRunningApplication.runningApplications(withBundleIdentifier:SystemPortal.browserID).first else{return nil}
        return attribute(AXUIElementCreateApplication(app.processIdentifier),kAXFocusedWindowAttribute) as! AXUIElement?
    }
    static func restoreRemoteTab() -> Bool {
        guard AXIsProcessTrusted(),NSWorkspace.shared.frontmostApplication?.bundleIdentifier==SystemPortal.browserID,
              let app=NSRunningApplication.runningApplications(withBundleIdentifier:SystemPortal.browserID).first,
              let windows=attribute(AXUIElementCreateApplication(app.processIdentifier),kAXWindowsAttribute) as? [AXUIElement] else{return false}
        let matches=windows.flatMap{w in nodes(w).filter{item in
            let identifier=attribute(item,kAXIdentifierAttribute) as? String ?? ""
            return identifier.hasPrefix("TabBarTab?") && text(item)=="administrator@192.0.2.11"
        }.map{(w,$0)}}
        guard matches.count==1,let (w,tab)=matches.first else{return false}
        var actions:CFArray?
        guard AXUIElementCopyActionNames(tab,&actions) == .success,
              (actions as? [String])?.contains(kAXPressAction)==true else{return false}
        if attribute(w,kAXMinimizedAttribute) as? Bool == true {
            guard AXUIElementSetAttributeValue(w,kAXMinimizedAttribute as CFString,kCFBooleanFalse) == .success else{return false}
        }
        _=AXUIElementPerformAction(w,kAXRaiseAction as CFString)
        guard AXUIElementPerformAction(tab,kAXPressAction as CFString) == .success else{return false}
        return state() == .remote // Verify the full origin/route after pressing.
    }
    static func restorePortalTab() -> Bool {
        guard AXIsProcessTrusted(),NSWorkspace.shared.frontmostApplication?.bundleIdentifier==SystemPortal.browserID,
              let app=NSRunningApplication.runningApplications(withBundleIdentifier:SystemPortal.browserID).first,
              let windows=attribute(AXUIElementCreateApplication(app.processIdentifier),kAXWindowsAttribute) as? [AXUIElement] else{return false}
        if let (w,tab)=rememberedPortal {
            _=AXUIElementSetAttributeValue(w,kAXMinimizedAttribute as CFString,kCFBooleanFalse)
            _=AXUIElementPerformAction(w,kAXRaiseAction as CFString)
            if AXUIElementPerformAction(tab,kAXPressAction as CFString) == .success,isCurrentPortalAddress(){return true}
            rememberedPortal=nil
        }
        for w in windows {
            let tabs=nodes(w).filter{item in
                (attribute(item,kAXIdentifierAttribute) as? String ?? "").hasPrefix("TabBarTab?") && text(item)=="示例远程监控系统"
            }
            for tab in tabs {
                _=AXUIElementSetAttributeValue(w,kAXMinimizedAttribute as CFString,kCFBooleanFalse)
                _=AXUIElementPerformAction(w,kAXRaiseAction as CFString)
                if AXUIElementPerformAction(tab,kAXPressAction as CFString) == .success,
                   isCurrentPortalAddress(){rememberedPortal=(w,tab);return true}
            }
        }
        return false
    }
    static func restoreDeviceTab()->Bool {
        guard inputIdle(),NSWorkspace.shared.frontmostApplication?.bundleIdentifier==SystemPortal.browserID,
              let app=NSRunningApplication.runningApplications(withBundleIdentifier:SystemPortal.browserID).first,
              let windows=attribute(AXUIElementCreateApplication(app.processIdentifier),kAXWindowsAttribute) as? [AXUIElement] else{return false}
        for w in windows {
            for tab in nodes(w).filter({
                (attribute($0,kAXIdentifierAttribute) as? String ?? "").hasPrefix("TabBarTab?") && text($0)=="示例远程监控系统"
            }) {
                _=AXUIElementSetAttributeValue(w,kAXMinimizedAttribute as CFString,kCFBooleanFalse)
                _=AXUIElementPerformAction(w,kAXRaiseAction as CFString)
                if AXUIElementPerformAction(tab,kAXPressAction as CFString) == .success,state() == .devices {
                    rememberedPortal=(w,tab);return true
                }
            }
        }
        return false
    }
    static func isCurrentPortalAddress()->Bool {
        guard let w=window(),let field=nodes(w).first(where:{attribute($0,kAXIdentifierAttribute) as? String == "WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD"}),
              let raw=attribute(field,kAXValueAttribute) as? String,let u=URLComponents(string:raw) else{return false}
        return u.scheme=="https" && u.host=="portal.example.com" && u.port==9978 && u.user==nil && u.password==nil && u.percentEncodedPath=="/admin.php" &&
            u.queryItems?.filter{$0.name=="controller"}.count==1 && u.queryItems?.contains{$0.name=="controller" && $0.value=="admin_index"} == true
    }
    static func rememberPortal() {
        guard isCurrentPortalAddress(),let w=window(),let tab=nodes(w).first(where:{
            let identifier=attribute($0,kAXIdentifierAttribute) as? String ?? ""
            return identifier.hasPrefix("TabBarTab?") && identifier.contains("isActive=true")
        }) else{return}
        rememberedPortal=(w,tab)
    }
    static func reloadPortal()->Bool {
        guard inputIdle(),isCurrentPortalAddress(),let w=window(),let button=nodes(w).first(where:{attribute($0,kAXIdentifierAttribute) as? String=="ReloadButton"}) else{return false}
        return AXUIElementPerformAction(button,kAXPressAction as CFString) == .success
    }
    static func reconnectButtons(enabledOnly:Bool=true)->[AXUIElement] {
        guard state() == .remote,let w=window() else{return []}
        return nodes(w).filter{item in
            attribute(item,kAXRoleAttribute) as? String == kAXButtonRole &&
            ReconnectPolicy.isReconnectButtonLabel(text(item)) &&
            (!enabledOnly || attribute(item,kAXEnabledAttribute) as? Bool != false) &&
            rect(item).map{$0.width>5 && $0.height>5 && (rect(w)?.intersects($0) ?? false)} == true
        }
    }
    static func interrupted()->Bool {
        guard state() == .remote,let w=window() else{return false}
        if !reconnectButtons(enabledOnly:false).isEmpty{return true}
        // Guacamole's visible dialog/status headings, independent of whether
        // the reconnect button is enabled. Apache translations en.json/zh.json.
        let headings:Set<String>=["已断开连接","连接出错","您的连接已断开。","disconnected","connection error","you have been disconnected."]
        return nodes(w).contains{item in
            let role=attribute(item,kAXRoleAttribute) as? String ?? ""
            return ["AXStaticText","AXHeading"].contains(role) && headings.contains(text(item).trimmingCharacters(in:.whitespacesAndNewlines).lowercased()) &&
                rect(item).map{$0.width>0 && $0.height>0 && (rect(w)?.intersects($0) ?? false)} == true
        }
    }
    static func pressReconnect()->Bool {
        guard inputIdle(),NSWorkspace.shared.frontmostApplication?.bundleIdentifier==SystemPortal.browserID else{return false}
        let buttons=reconnectButtons()
        guard buttons.count==1,let button=buttons.first else{return false}
        return AXUIElementPerformAction(button,kAXPressAction as CFString) == .success
    }
    static func inputIdle()->Bool {
        let front=NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        return AXIsProcessTrusted() && !["com.apple.SecurityAgent","com.apple.loginwindow","com.apple.systempreferences","com.apple.LocalAuthenticationRemoteService"].contains(front) &&
            CGEventSource.secondsSinceLastEventType(.combinedSessionState,eventType:CGEventType(rawValue:UInt32.max)!)>2 &&
            CGEventSource.flagsState(.combinedSessionState).intersection([.maskShift,.maskControl,.maskAlternate,.maskCommand]).isEmpty &&
            !CGEventSource.buttonState(.combinedSessionState,button:.left) && !CGEventSource.buttonState(.combinedSessionState,button:.right)
    }
    static func state() -> State {
        guard let w=window() else{return .other}
        let all=nodes(w)
        let address=all.first{attribute($0,kAXIdentifierAttribute) as? String == "WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD"}.flatMap{attribute($0,kAXValueAttribute) as? String}
        for item in all where attribute(item,kAXRoleAttribute) as? String == "AXWebArea" {
            guard let raw=attribute(item,kAXURLAttribute) else{continue}
            let value=(raw as? URL)?.absoluteString ?? (raw as? String)
            let url=value.flatMap{resolvedURL($0,address:address)}
            guard let u=url,u.scheme=="https",u.host=="portal.example.com",u.port==9978,u.user==nil,u.password==nil else{continue}
            if isRemoteURL(u,title:text(w)) {return .remote}
            if u.path=="/admin.php",let query=URLComponents(url:u,resolvingAgainstBaseURL:false)?.queryItems,
               query.filter({$0.name=="controller"}).count==1,query.contains(where:{$0.name=="controller" && $0.value=="admin_index"}),
               query.filter({$0.name=="action"}).count==1,query.contains(where:{$0.name=="action" && $0.value=="login"}) {return .login}
            if u.path=="/admin.php",let query=URLComponents(url:u,resolvingAgainstBaseURL:false)?.queryItems,
               query.contains(where:{$0.name=="controller" && $0.value=="admin_index"}),
               query.contains(where:{$0.name=="action" && $0.value=="main"}) {return .devices}
        }
        return .other
    }
    nonisolated static func resolvedURL(_ web:String,address:String?)->URL? {
        if let url=URL(string:web),["https","http"].contains(url.scheme ?? ""){return url}
        // Safari may expose AXWebArea URL without its scheme. Confirm the full
        // address-bar URL against that exact web area; never guess HTTPS.
        guard let address,let url=URL(string:address),url.scheme=="https",url.user==nil,url.password==nil,
              address.hasPrefix("https://"),String(address.dropFirst(8))==web else{return nil}
        return url
    }
    nonisolated static func isRemoteURL(_ url:URL,title:String)->Bool {
        // URL.path removes the trailing slash. URLComponents retains the exact
        // portal route, avoiding both false login attempts and sibling routes.
        guard url.scheme=="https",url.host=="portal.example.com",url.port==9978,
              url.user==nil,url.password==nil,
              URLComponents(url:url,resolvingAgainstBaseURL:false)?.percentEncodedPath=="/baoleiji/" else{return false}
        return title.contains("administrator@192.0.2.11")
    }
    static func rect(_ element: AXUIElement) -> CGRect? {
        guard let pv=attribute(element,kAXPositionAttribute),let sv=attribute(element,kAXSizeAttribute),
              CFGetTypeID(pv)==AXValueGetTypeID(),CFGetTypeID(sv)==AXValueGetTypeID() else{return nil}
        var p=CGPoint.zero,s=CGSize.zero
        guard AXValueGetValue(pv as! AXValue,.cgPoint,&p),AXValueGetValue(sv as! AXValue,.cgSize,&s) else{return nil}
        return CGRect(origin:p,size:s)
    }
    struct BrowserGeometry:Decodable {
        let x:Double,y:Double,width:Double,height:Double,centerX:Double,centerY:Double,viewportWidth:Double,viewportHeight:Double
        var valid:Bool { [x,y,width,height,centerX,centerY,viewportWidth,viewportHeight].allSatisfy{$0.isFinite} && viewportWidth>=300 && viewportHeight>=150 && viewportWidth<=20000 && viewportHeight<=20000 && width>0 && height>0 && centerX>0 && centerX<viewportWidth && centerY>0 && centerY<viewportHeight && abs(centerX-x-width/2)<0.1 && abs(centerY-y-height/2)<0.1 }
    }
    static var browserPointIssue="界面未就绪"
    static func browserPoint(_ raw:String)->(point:CGPoint,window:AXUIElement,web:AXUIElement)? {
        browserPointIssue="界面未就绪"
        guard inputIdle(),NSWorkspace.shared.frontmostApplication?.bundleIdentifier==SystemPortal.browserID,
              state() == .devices,let data=raw.data(using:.utf8),let g=try? JSONDecoder().decode(BrowserGeometry.self,from:data),g.valid,
              let w=window(),let wr=rect(w),let field=nodes(w).first(where:{attribute($0,kAXIdentifierAttribute) as? String=="WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD"}),
              let address=attribute(field,kAXValueAttribute) as? String,let expected=URL(string:address) else{return nil}
        let matches=nodes(w).filter{node in
            guard attribute(node,kAXRoleAttribute) as? String=="AXWebArea",let raw=attribute(node,kAXURLAttribute) else{return false}
            let value=(raw as? URL)?.absoluteString ?? (raw as? String)
            return value.flatMap{resolvedURL($0,address:address)}==expected
        }
        browserPointIssue="顶层网页区域 \(matches.count) 个"
        guard matches.count==1,let web=matches.first,let full=rect(web),full.width>100,full.height>100 else{return nil}
        // AXWebArea may describe the complete scrollable document. Its parent
        // scroll area provides the visible viewport used by DOM client rects.
        var frames:[CGRect]=[full],ancestor=attribute(web,kAXParentAttribute) as! AXUIElement?
        for _ in 0..<12 {
            guard let node=ancestor else{break}
            if attribute(node,kAXRoleAttribute) as? String=="AXScrollArea",let frame=rect(node){frames.append(frame.intersection(wr))}
            ancestor=attribute(node,kAXParentAttribute) as! AXUIElement?
        }
        browserPointIssue="网页视口 \(Int(full.width))×\(Int(full.height)) / \(Int(g.viewportWidth))×\(Int(g.viewportHeight))"
        guard let r=frames.first(where:{r in
            let scale=r.width/g.viewportWidth
            return !r.isNull && scale>=0.25 && scale<=4 && abs(r.height-g.viewportHeight*scale)<=4
        }) else{return nil}
        let scale=r.width/g.viewportWidth
        let point=CGPoint(x:r.minX+g.centerX*scale,y:r.minY+g.centerY*scale)
        guard wr.contains(point),r.contains(point),let app=NSRunningApplication.runningApplications(withBundleIdentifier:SystemPortal.browserID).first else{return nil}
        browserPointIssue="图标被其他窗口遮挡"
        var hit:AXUIElement?,pid:pid_t=0
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),Float(point.x),Float(point.y),&hit) == .success,
              let h=hit,AXUIElementGetPid(h,&pid) == .success,pid==app.processIdentifier else{return nil}
        browserPointIssue="图标命中区域不属于目标网页"
        var node:AXUIElement?=h
        for _ in 0..<30 {
            guard let current=node else{return nil}
            if CFEqual(current,web){return (point,w,web)}
            node=attribute(current,kAXParentAttribute) as! AXUIElement?
        }
        return nil
    }
    static func clickBrowser(valid:()->Bool = {true}) async throws {
        guard valid(),inputIdle(),NSWorkspace.shared.frontmostApplication?.bundleIdentifier==SystemPortal.browserID,
              state() == .devices,let w=window(),let windowRect=rect(w) else{throw failure("请将系统设备列表放到 Safari 前台。")}
        let rows=nodes(w).filter{attribute($0,kAXRoleAttribute) as? String==kAXRowRole}
        let matches=rows.filter { element in
            guard attribute(element,kAXRoleAttribute) as? String==kAXRowRole else{return false}
            let cells=children(element).filter{attribute($0,kAXRoleAttribute) as? String==kAXCellRole}
            return cells.count==9 && contains(cells[1],"监控机-1") && contains(cells[2],"192.0.2.11")
                && contains(cells[5],"administrator") && contains(cells[6],"RDP")
        }
        guard matches.count==1,let row=matches.first else{throw failure("设备表格核对未通过（\(rows.count) 行、\(matches.count) 个匹配），未点击。")}
        let cells=children(row).filter{attribute($0,kAXRoleAttribute) as? String==kAXCellRole}
        guard let tools=cells.last,let r=rect(tools),r.width>=65,r.height>=20,
              windowRect.contains(CGPoint(x:r.minX+13,y:r.midY)) else{throw failure("监控机 1 浏览器入口不在可见窗口内，请恢复设备列表。")}
        // Browser icon is 13 points from the tools cell's left edge in this portal.
        let point=CGPoint(x:r.minX+13,y:r.midY)
        var hit:AXUIElement?;var pid:pid_t=0
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),Float(point.x),Float(point.y),&hit) == .success,
              let hit,AXUIElementGetPid(hit,&pid) == .success,
              pid==NSRunningApplication.runningApplications(withBundleIdentifier:SystemPortal.browserID).first?.processIdentifier else{throw failure("入口被其它窗口遮挡，等待恢复。")}
        let move=CGEvent(mouseEventSource:nil,mouseType:.mouseMoved,mouseCursorPosition:point,mouseButton:.left)
        move?.flags=[];move?.post(tap:.cghidEventTap)
        try await Task.sleep(nanoseconds:150_000_000)
        guard valid(),NSWorkspace.shared.frontmostApplication?.bundleIdentifier==SystemPortal.browserID,
              [.keyDown,.leftMouseDown,.rightMouseDown].allSatisfy({CGEventSource.secondsSinceLastEventType(.combinedSessionState,eventType:$0)>0.2}),
              CGEventSource.flagsState(.combinedSessionState).intersection([.maskShift,.maskControl,.maskAlternate,.maskCommand]).isEmpty,
              !CGEventSource.buttonState(.combinedSessionState,button:.left),!CGEventSource.buttonState(.combinedSessionState,button:.right),
              state() == .devices,let current=window(),CFEqual(w,current),rect(tools)==r else{throw failure("窗口或输入状态改变，保留等待。")}
        guard let down=CGEvent(mouseEventSource:nil,mouseType:.leftMouseDown,mouseCursorPosition:point,mouseButton:.left),
              let up=CGEvent(mouseEventSource:nil,mouseType:.leftMouseUp,mouseCursorPosition:point,mouseButton:.left) else{throw failure("无法点击浏览器入口。")}
        down.flags=[];up.flags=[];down.post(tap:.cghidEventTap);up.post(tap:.cghidEventTap)
    }
}
