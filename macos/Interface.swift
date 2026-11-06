import SwiftUI
import AppKit

private enum MonitorPage: String, CaseIterable {
    case dashboard="监控总览", regions="识别区域", settings="通知与设置", activity="运行记录"
    var symbol:String {
        switch self {case .dashboard:return "square.grid.2x2";case .regions:return "viewfinder";case .settings:return "slider.horizontal.3";case .activity:return "clock.arrow.circlepath"}
    }
    var detail:String {
        switch self {
        case .dashboard:return "连接远程邮箱，查看实时运行状态"
        case .regions:return "预览画面，校准邮件列表与正文"
        case .settings:return "管理系统账号、微信通知与本机权限"
        case .activity:return "查看连接、识别和通知的实际结果"
        }
    }
}
private struct AppMark: View {
    var size:CGFloat=44
    var body:some View {
        Group {
            if let image=NSImage(named:"AppIcon") {Image(nsImage:image).resizable().interpolation(.high)}
            else {Image(systemName:"envelope.badge.fill").resizable().scaledToFit().foregroundStyle(.blue)}
        }.frame(width:size,height:size).accessibilityHidden(true)
    }
}
@MainActor private final class MonitorNavigation:ObservableObject {
    @Published var page:MonitorPage = .dashboard
}
private struct MonitorCard<Content:View>: View {
    @Environment(\.colorScheme) var scheme
    @ViewBuilder var content:Content
    var body:some View {
        VStack(alignment:.leading,spacing:10){content}.padding(20).frame(maxWidth:.infinity,alignment:.leading)
            .background(scheme == .dark ? Color(red:0.14,green:0.16,blue:0.20):.white,in:RoundedRectangle(cornerRadius:18))
            .overlay{RoundedRectangle(cornerRadius:18).strokeBorder(Color.primary.opacity(0.07))}
    }
}
struct MainView: View {
    @ObservedObject var m:Monitor
    @StateObject private var navigation=MonitorNavigation()
    @State private var choosingWindow=false
    @State private var helpShown=false
    private let accent=Color(red:0.03,green:0.40,blue:0.52)
    private var page:MonitorPage {get{navigation.page} nonmutating set{navigation.page=newValue}}
    @Environment(\.colorScheme) private var scheme
    private var editingLocked:Bool {m.running || m.openingSystem || m.busy || m.systemSaving || m.tokenSaving || m.unlockingNotifications}
    private var runLabel:String {
        if m.openingSystem{return "正在连接"}
        if m.running {
            if !m.notificationAvailability.canOpenMail{return m.notificationAvailability.title}
            if m.reconnecting{return m.portalNeedsUnlock ? "连接等待授权":"正在自动重连"}
            if m.uncertainCount>0{return "有通知结果待核对"}
            if m.status.contains("等待所选邮箱"){return "等待邮箱前台"}
            if m.status.contains("本轮未完成") || m.status.contains("请校准"){return "需要检查连接"}
            if m.transportPaused{return "通知通道待修复"}
            return "正在监控"
        }
        return m.offline ? "正在查看样本":(m.selection == 0 ? "等待选择邮箱":"邮箱已选择")
    }
    private var deliveryWarning:Bool {m.running && (m.notificationAvailability.requiresAttention || m.uncertainCount>0)}
    private var warningPage:MonitorPage {
        if m.notificationAvailability.canOpenMail{return .activity}
        if [.needsAuthorization,.authorizing].contains(m.notificationAvailability){return .dashboard}
        return .settings
    }
    private var runSymbol:String {deliveryWarning ? "exclamationmark.triangle.fill":(m.running ? "waveform.path.ecg":(m.openingSystem ? "arrow.triangle.2.circlepath":"power"))}
    private var startHint:String {
        if m.offline{return "当前是历史截图，连接实时邮箱后才能开始扫描。"}
        if m.selection==0{return "请选择 Safari 中显示远程 Foxmail 收件箱的窗口。"}
        if !m.screenAllowed{return "请先在“通知与设置”中开启屏幕录制。"}
        if m.settings.autoOpen && !m.accessibility{return "自动打开新邮件需要辅助功能权限。"}
        if m.busy{return "正在识别画面，请稍候。"}
        return "只打开未读邮件，逐页读取正文后通知；已读邮件不再处理。"
    }
    var body:some View {
        GeometryReader { geo in
        HStack(spacing:0) {
            sidebar(compact:geo.size.width < 910)
            VStack(spacing:0) {
                toolbar
                if deliveryWarning {
                    HStack(spacing:12) {
                        Image(systemName:"exclamationmark.triangle.fill")
                        VStack(alignment:.leading,spacing:4){Text(m.notificationWarningTitle).fontWeight(.semibold);Text(m.notificationWarningDetail).font(.caption).fixedSize(horizontal:false,vertical:true)}
                        Spacer(minLength:8)
                        Button("查看处理方法"){page = warningPage}
                        Button(m.notificationReminderMuted ? "已静音":"本次静音"){m.silenceNotificationReminder()}.disabled(m.notificationReminderMuted)
                    }.padding(14).foregroundStyle(.white).background(Color(red:0.70,green:0.12,blue:0.09))
                }
                ScrollView {
                    VStack(alignment:.leading,spacing:20) {
                        switch page {
                        case .dashboard:dashboard
                        case .regions:regions
                        case .settings:settings
                        case .activity:activity
                        }
                    }.padding(28).frame(maxWidth:1220).frame(maxWidth:.infinity)
                }
            }.background(scheme == .dark ? Color(nsColor:.windowBackgroundColor):Color(red:0.945,green:0.956,blue:0.975))
        }
        }.frame(minWidth:710,minHeight:520).tint(scheme == .dark ? Color(red:0.34,green:0.78,blue:0.87):accent)
        .sheet(isPresented:$choosingWindow) {
            VStack(alignment:.leading,spacing:18) {
                HStack { Text("选择邮箱窗口").font(.title2.bold());Spacer();Button("完成"){choosingWindow=false}.keyboardShortcut(.cancelAction) }
                if !m.screenAllowed {
                    Text("开启屏幕录制权限后，重新打开应用即可选择 Foxmail 窗口。").foregroundStyle(.secondary)
                    Button("打开屏幕录制设置"){m.requestScreen()}
                } else {
                    windowCard
                    Text(m.status).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                }
            }.padding(24).frame(width:510)
            .task{if m.screenAllowed{await m.refresh()}}
            .onChange(of:m.running){_,started in if started{choosingWindow=false}}
        }
        .sheet(isPresented:$helpShown) {
            VStack(alignment:.leading,spacing:14) {
                Text("开始使用").font(.title2.bold())
                Text("1. 在 Safari 中打开 HTTPS 远程 Foxmail 收件箱，按“是否已读”排序。")
                Text("2. 选择邮箱窗口，预览识别，并在“识别区域”框选列表和正文。")
                Text("3. 在“通知与设置”保存自己的 PushPlus Token，测试后开始扫描。")
                Text("安卓控制：将两个 Mac 应用放在同一文件夹，点“手机配对”，让手机连接相同的 Wi-Fi，然后输入电脑显示的六位码。")
                Link("打开完整使用说明",destination:URL(string:"https://github.com/19939138357/mail-alert-monitor#readme")!)
                HStack{Spacer();Button("完成"){helpShown=false}.keyboardShortcut(.defaultAction)}
            }.padding(26).frame(width:440)
        }
        .sheet(isPresented:$m.showSystemSettings,onDismiss:{m.systemPassword="";m.systemUsername=""}){accountSheet}
        .alert(m.notificationWarningTitle,isPresented:$m.showNotificationWarning) {
            Button("查看处理方法"){page = warningPage}
            Button("本次静音"){m.silenceNotificationReminder()}
        } message: {Text(m.notificationWarningDetail+" 未处理时每分钟以本机声音提醒一次；静音不会解除故障。")}
        .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)){_ in m.permissions()}
        .onChange(of:m.selection){_,_ in if !m.running && !m.openingSystem{m.preview=nil;m.mailReady=false;m.linesCount=0;m.offline=false;m.lastScan="尚未扫描"}}
        .onChange(of:m.settings.autoOpen){_,_ in persistOptions()}
        .onChange(of:m.settings.night){_,_ in persistOptions()}
        .onChange(of:m.settings.includeExistingUnread){_,_ in persistOptions()}
        .onChange(of:m.settings.browseEntireList){_,_ in persistOptions()}
        .task {
            if let image=NSImage(named:"AppIcon"){NSApplication.shared.applicationIconImage=image}
            if CommandLine.arguments.contains("--demo") {await sample()}
            else if m.screenAllowed {await m.refresh()}
        }
    }
    private func sidebar(compact:Bool)->some View {
        VStack(alignment:.leading,spacing:6) {
            HStack(spacing:8) {
                AppMark(size:38)
                if !compact {Text("邮件监控").font(.system(size:17,weight:.semibold))}
            }.padding(.top,22).padding(.bottom,25)
            ForEach(MonitorPage.allCases,id:\.self){item in
                Button{page=item}label:{
                    HStack(spacing:10) {
                        Image(systemName:item.symbol).font(.system(size:16,weight:.medium)).frame(width:20)
                        if !compact {Text(item.rawValue).font(.system(size:13,weight:page==item ? .semibold:.regular));Spacer()}
                    }.padding(.horizontal,11).frame(height:38)
                     .foregroundStyle(page==item ? Color.white:Color.primary)
                     .background(page==item ? accent:.clear,in:RoundedRectangle(cornerRadius:8))
                }.buttonStyle(.plain).accessibilityLabel(item.rawValue).help(item.rawValue)
                 .accessibilityAddTraits(page==item ? .isSelected:[])
            }
            Spacer()
            Divider()
            sidebarAction("手机配对",symbol:"iphone.gen3",compact:compact) {
                let peer=Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("手机配对.app")
                guard Bundle(url:peer)?.bundleIdentifier=="org.example.mailalertmonitor.phonepair" else {
                    m.note("未找到手机配对工具。请将安装包中的两个 App 放在同一文件夹。");page = .dashboard;return
                }
                NSWorkspace.shared.openApplication(at:peer,configuration:.init()){_,error in
                    if error != nil {Task{@MainActor in m.note("无法打开手机配对工具，请从安装包重新解压。");page = .dashboard}}
                }
            }
            sidebarAction("使用说明",symbol:"questionmark.circle",compact:compact){helpShown=true}
        }.padding(.horizontal,compact ? 9:13).padding(.bottom,14).frame(width:compact ? 62:162)
            .background(scheme == .dark ? Color(red:0.105,green:0.145,blue:0.16):Color(red:0.88,green:0.92,blue:0.93))
            .overlay(alignment:.trailing){Divider()}
    }
    private func sidebarAction(_ title:String,symbol:String,compact:Bool,action:@escaping ()->Void)->some View {
        Button(action:action){HStack(spacing:10){Image(systemName:symbol).frame(width:20)
            if !compact{Text(title);Spacer()}
        }.padding(.horizontal,11).frame(height:32)}
            .font(.callout).foregroundStyle(.secondary).buttonStyle(.plain).help(title).accessibilityLabel(title)
    }
    private var toolbar:some View {
        HStack(spacing:14) {
            VStack(alignment:.leading,spacing:5){Text(page.rawValue).font(.system(size:25,weight:.bold));Text(page == .dashboard ? "监控机 1":page.detail).font(.system(size:12)).foregroundStyle(.secondary)}
            Spacer(minLength:12)
            if m.openingSystem {
                ProgressView().controlSize(.small)
                Button("取消等待"){m.cancelConnection()}.controlSize(.large)
            } else if m.running {
                Button{m.stop()}label:{Label("停止监控",systemImage:"stop.fill")}.controlSize(.large).buttonStyle(.bordered)
            } else if !SystemPortal.isAdapted {
                Button {
                    if m.selection == 0 || m.offline {choosingWindow=true}
                    else {page = .dashboard;m.start()}
                } label:{Label(m.selection == 0 || m.offline ? "选择邮箱窗口":"开始监控",systemImage:m.selection == 0 || m.offline ? "macwindow":"play.fill")}
                    .controlSize(.large).buttonStyle(.borderedProminent)
                    .disabled(editingLocked || m.testInFlight || m.startupError != nil)
            } else {
                Button{page = .dashboard;m.connectSystem()}label:{Label("连接监控机 1",systemImage:"safari")}.controlSize(.large).buttonStyle(.borderedProminent)
                    .disabled(m.busy || m.systemSaving || m.tokenSaving || m.testInFlight || m.startupError != nil)
                    .help("从监控机 1 工具栏左侧浏览器按钮进入邮箱，识别成功后自动开始监控。")
            }
        }.padding(.horizontal,28).padding(.vertical,22).background(scheme == .dark ? Color(nsColor:.controlBackgroundColor):.white)
            .overlay(alignment:.bottom){Rectangle().fill(Color.primary.opacity(0.06)).frame(height:1)}
    }
    private var dashboard:some View {
        Group {
            statusPanel
            MonitorCard {
                HStack {
                    Label("最近邮件",systemImage:"tray").font(.headline)
                    Spacer()
                    Button("查看全部"){page = .activity}.buttonStyle(.borderless)
                }
                Divider()
                if m.inbox.tickets.isEmpty {
                    HStack(spacing:12) {
                        Image(systemName:"tray").font(.title2).foregroundStyle(.secondary)
                        VStack(alignment:.leading,spacing:4) {
                            Text("暂无邮件记录").font(.callout.bold())
                            Text("开始扫描后，新发现的未读邮件会显示在这里。").font(.callout).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical,8)
                }
                ForEach(Array(m.inbox.tickets.suffix(4).reversed()),id:\.id){ticket in
                    mailRow(ticket)
                    if ticket.id != m.inbox.tickets.suffix(4).first?.id {Divider()}
                }
            }
            previewCard(calibrating:false)
            windowCard
        }
    }
    private var statusPanel:some View {
        VStack(alignment:.leading,spacing:16) {
            HStack(alignment:.top,spacing:12) {
                Image(systemName:runSymbol).font(.title2).frame(width:42,height:42)
                    .background(.white.opacity(0.13),in:RoundedRectangle(cornerRadius:10))
                VStack(alignment:.leading,spacing:5) {
                    Text(runLabel).font(.system(size:23,weight:.semibold))
                    Text(m.running && !m.notificationAvailability.canOpenMail ? m.notificationAvailability.detail:m.status)
                        .font(.callout).foregroundStyle(.white.opacity(0.89)).fixedSize(horizontal:false,vertical:true)
                }
                Spacer()
                if m.openingSystem {ProgressView().controlSize(.small).tint(.white)}
            }
            Rectangle().fill(.white.opacity(0.24)).frame(height:1)
            HStack(spacing:0) {
                metric("实际扫描",value:m.frames,unit:"次")
                metric("待处理邮件",value:m.queuedCount,unit:"封")
                metric("结果待核对",value:m.uncertainCount,unit:"封")
            }
            if m.portalNeedsUnlock {
                Divider().overlay(.white.opacity(0.22))
                HStack{Text("完成一次系统账号授权，连接过期后才能自动登录。").font(.caption);Spacer();Button(m.unlockingPortal ? "等待授权…":"授权连接"){Task{await m.unlockPortal()}}.disabled(m.unlockingPortal).buttonStyle(.borderedProminent)}
            }
            if m.notificationNeedsUnlock {
                HStack(spacing:12){
                    Text("微信推送已暂停。未读只排队，暂不自动打开；授权后继续处理。").font(.caption)
                    Spacer()
                    if m.unlockingNotifications{ProgressView().tint(.white)}
                    else{Button("授权通知"){Task{await m.unlockNotifications()}}.buttonStyle(.borderedProminent)}
                }
            }
        }.padding(24).foregroundStyle(.white).frame(maxWidth:.infinity,alignment:.leading)
            .background(deliveryWarning ? Color(red:0.48,green:0.23,blue:0.13):Color(red:0.07,green:0.25,blue:0.31),in:RoundedRectangle(cornerRadius:15))
    }
    private func metric(_ title:String,value:Int,unit:String)->some View {
        VStack(alignment:.leading,spacing:3) {
            Text(title).font(.caption).foregroundStyle(.white.opacity(0.84))
            HStack(alignment:.firstTextBaseline,spacing:4) {
                Text(String(value)).font(.system(size:24,weight:.medium)).monospacedDigit()
                Text(unit).font(.caption).foregroundStyle(.white.opacity(0.8))
            }
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
    private func mailRow(_ ticket:InboxTicket)->some View {
        let color:Color
        let symbol:String
        switch ticket.state {
        case .accepted,.duplicate: color = .secondary;symbol = "checkmark.circle"
        case .rejected,.uncertain: color = .orange;symbol = "exclamationmark.circle.fill"
        default: color = scheme == .dark ? .cyan:accent;symbol = "envelope"
        }
        return HStack(alignment:.top,spacing:11) {
            Image(systemName:symbol).foregroundStyle(color).frame(width:18).padding(.top,2)
            VStack(alignment:.leading,spacing:4) {
                Text(ticket.content?.subject ?? ticket.subject).font(.system(size:13,weight:.semibold))
                    .textSelection(.enabled).lineLimit(2)
                Text(ticket.sender+" · "+(ticket.content?.sentAt ?? (ticket.day+" "+ticket.timeLabel)))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(ticket.receivedConfirmedAt != nil ? "本人已确认收到":ticket.state.label)
                .font(.caption).foregroundStyle(color)
        }.padding(.vertical,4)
    }
    private func previewCard(calibrating:Bool)->some View {
        MonitorCard {
            VStack(alignment:.leading,spacing:14) {
                HStack{
                    Label(m.offline ? "截图验证":"邮箱画面",systemImage:m.offline ? "photo":"display").font(.system(size:15,weight:.semibold))
                    Spacer();Text(m.lastScan).font(.system(size:11)).foregroundStyle(.secondary)
                    if !calibrating{Button("校准区域"){page = .regions}.buttonStyle(.borderless).disabled(m.running || m.openingSystem)}
                }
                if m.preview != nil {
                    CapturePreview(model:m).padding(12).frame(height:calibrating ? 390:300).background(Color(red:0.075,green:0.095,blue:0.145),in:RoundedRectangle(cornerRadius:12))
                } else {
                    VStack(spacing:12) {
                        Image(systemName:"macwindow.badge.plus").font(.system(size:40,weight:.light)).foregroundStyle(Color(red:0.38,green:0.66,blue:1))
                        Text("连接后，邮箱画面会显示在这里").font(.system(size:16,weight:.medium)).foregroundStyle(.white)
                        Text("先选择显示 Foxmail 的窗口，再点“预览识别”。").font(.system(size:12)).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.64)).lineSpacing(4)
                        Button("查看示例截图"){Task{await sample()}}.buttonStyle(.borderedProminent).disabled(editingLocked).padding(.top,2)
                    }.frame(maxWidth:.infinity).frame(height:calibrating ? 340:260).background(Color(red:0.075,green:0.095,blue:0.145),in:RoundedRectangle(cornerRadius:12))
                }
                HStack(spacing:14){Label("列表区域",systemImage:"square.dashed").foregroundStyle(.blue);Label("正文区域",systemImage:"square.dashed").foregroundStyle(.green);Spacer();if m.busy{ProgressView().controlSize(.mini);Text("正在识别").foregroundStyle(.secondary)}}.font(.system(size:11))
                Text(m.ocrSummary).font(.system(size:12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                if m.offline{Text("历史截图只用于验证，连接实时窗口后才能监控。").font(.caption).foregroundStyle(.orange);if !m.offlineDetails.isEmpty{Text(m.offlineDetails).font(.caption).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)}}
            }
        }
    }
    private var windowCard:some View {
        MonitorCard {
            VStack(alignment:.leading,spacing:14) {
                HStack{Label("手动选择窗口",systemImage:"macwindow").font(.system(size:15,weight:.semibold));Spacer();Button("刷新窗口"){Task{await m.refresh()}}.disabled(editingLocked)}
                Picker("目标窗口",selection:$m.selection){Text("请选择邮箱窗口").tag(UInt32(0));ForEach(m.windows,id:\.windowID){w in Text(m.label(w)).tag(w.windowID)}}.disabled(editingLocked).frame(maxWidth:.infinity)
                HStack{
                    Button{Task{await m.previewOnce()}}label:{Label("预览识别",systemImage:"viewfinder")}.disabled(editingLocked || m.selection==0)
                    Button{m.start()}label:{Label("开始扫描",systemImage:"play.fill")}.buttonStyle(.borderedProminent).disabled(editingLocked || m.selection==0 || m.offline || m.testInFlight || m.startupError != nil)
                    Spacer();Button("导入截图"){Task{await m.importScreenshot()}}.disabled(editingLocked)
                }
                Text(startHint).font(.system(size:12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
        }
    }
    private var regions:some View {
        Group {
            MonitorCard {
                VStack(alignment:.leading,spacing:14){
                    HStack{Text("识别范围").font(.headline);Spacer();Picker("拖选区域",selection:$m.regionMode){Text("查看").tag(0);Text("邮件列表").tag(1);Text("邮件正文").tag(2)}.pickerStyle(.segmented).frame(width:310).disabled(editingLocked)}
                    Text(m.offline ? "选择“邮件列表”并在图片上拖选，再点“验证选区”。需包含左侧未读小蓝点、发件人和主题。":"选择“邮件列表”或“邮件正文”，在下方画面上拖出范围，松手即保存。列表需包含左侧未读小蓝点、发件人、主题和时间；正文需包含邮件头和内容。").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    HStack{Button("示例截图"){Task{await sample()}};Button("导入截图"){Task{await m.importScreenshot()}};if m.offline{Button("验证选区"){Task{await m.verifyOfflineRegion()}}.buttonStyle(.borderedProminent)};Spacer()}.disabled(editingLocked)
                }
            }
            previewCard(calibrating:true)
            windowCard
        }
    }
    private var settings:some View {
        Group {
            MonitorCard {
                VStack(alignment:.leading,spacing:14){
                    HStack{settingIcon("envelope.badge");VStack(alignment:.leading,spacing:4){Text("逐封新邮件通知").font(.headline);Text("所有发件人与主题都参与监控，每封邮件单独排队。").font(.callout).foregroundStyle(.secondary)}}
                    Toggle("启动时也通知已有未读邮件",isOn:$m.settings.includeExistingUnread).disabled(editingLocked)
                    Text("只处理未读邮件，已读邮件不再巡视。").font(.callout)
                    Text("先保存队列，再点击未读邮件、逐页读取正文，最后发送实际内容。读取不完整时保留等待，不发送空提示。请将 Foxmail 按“是否已读”排序、收起“已读”组，并保持远程邮箱连接。发送结果不明确时不会自动重发。").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                }
            }
            if SystemPortal.isAdapted { MonitorCard {
                HStack(alignment:.top,spacing:16){settingIcon("person.crop.circle.badge.checkmark");VStack(alignment:.leading,spacing:8){Text("系统账号").font(.headline);Text(m.hasSystemCredentials ? "已安全保存在本机，可用于一键连接。":"首次连接前，请填写系统用户名与口令。").font(.callout).foregroundStyle(.secondary);Text("仅用于 portal.example.com:9978").font(.caption).foregroundStyle(.secondary)};Spacer();Button(m.hasSystemCredentials ? "管理账号":"设置账号"){m.systemError="";m.showSystemSettings=true}.disabled(editingLocked)}
                if m.portalNeedsUnlock {
                    Divider()
                    HStack{Text("系统账号需要本机授权，授权后会自动继续重连。").font(.callout);Spacer();Button(m.unlockingPortal ? "等待授权…":"授权连接"){Task{await m.unlockPortal()}}.disabled(m.unlockingPortal)}
                }
            }
            }
            MonitorCard {
                VStack(alignment:.leading,spacing:16) {
                    HStack{settingIcon("bell.badge");VStack(alignment:.leading,spacing:4){Text("微信提醒").font(.headline);Text(m.hasToken ? "推送通道已配置，手机收件需实际核对。":"保存 PushPlus Token 后，可将新邮件提醒推送到微信。").font(.callout).foregroundStyle(.secondary)};Spacer()}
                    SecureField(m.hasToken ? "输入新 Token 可替换当前配置":"输入 PushPlus Token",text:$m.token).textFieldStyle(.roundedBorder).disabled(editingLocked || m.testInFlight)
                    HStack{Button(m.tokenSaving ? "保存中…":"保存 Token"){Task{await m.saveToken()}}.buttonStyle(.borderedProminent).disabled(m.token.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || editingLocked || m.testInFlight);Button(m.testInFlight ? "发送中…":"测试微信"){Task{await m.testPush()}}.disabled(!m.hasToken || editingLocked || m.testInFlight);Spacer();Text("测试会发送一条真实通知").font(.caption).foregroundStyle(.secondary)}
                    Divider();Toggle("夜间告警标记",isOn:$m.settings.night).disabled(editingLocked || m.testInFlight)
                    Text("夜间响铃沿用手机上的安卓响铃助手。Token 保存在 macOS 钥匙串。").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                }
            }
            MonitorCard {
                VStack(alignment:.leading,spacing:16){
                    Text("本机权限与行为").font(.headline)
                    permissionRow("屏幕录制",detail:"读取你选择的邮箱画面，在本机完成中文识别。",allowed:m.screenAllowed,action:m.requestScreen)
                    Divider()
                    permissionRow("辅助功能",detail:"点击监控机 1 浏览器入口，以及自动打开新邮件。",allowed:m.accessibility,action:m.requestAccessibility)
                    Divider();Toggle("自动打开新邮件",isOn:$m.settings.autoOpen).disabled(editingLocked)
                    Text(SystemPortal.isAdapted ? "远程会话中断时自动重连。鼠标键盘空闲后开始操作。":"请让所选邮箱保持可见。程序会等鼠标和键盘空闲后再打开未读邮件。").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    Button("重新检查权限"){m.permissions();m.note(m.screenAllowed && m.accessibility ? "本机录屏和辅助功能权限均可用。":"权限尚未齐全，请在系统设置中添加当前应用后重开。")}.disabled(editingLocked)
                }
            }
            MonitorCard{Label(m.status,systemImage:"info.circle").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
        }
    }
    private var activity:some View {
        Group {
            MonitorCard {HStack{Image(systemName:runSymbol).foregroundStyle(.blue);VStack(alignment:.leading,spacing:5){Text(runLabel).font(.headline);Text(m.status).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)};Spacer();Text("\(m.frames) 次实际扫描").font(.caption).monospacedDigit()}}
            if m.uncertainCount>0 {
                MonitorCard {
                    VStack(alignment:.leading,spacing:14) {
                        Text("待核对的历史通知").font(.headline)
                        Text("当前推送可用时，其他邮件继续处理。下面的旧结果需要逐条核对手机收件，程序不会重复补发。").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                        ForEach(m.inbox.tickets.filter{$0.state == .uncertain && $0.receivedConfirmedAt==nil},id:\.id){ticket in
                            VStack(alignment:.leading,spacing:6) {
                                Text(ticket.content?.subject ?? ticket.subject).font(.system(size:13,weight:.medium))
                                Text(ticket.content?.sentAt ?? (ticket.day+" "+ticket.timeLabel)).font(.caption).foregroundStyle(.secondary)
                                Text(ticket.deliveryReport?.reason ?? "旧版未保存具体失败原因；原发送结果保持待核对。").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                                Button("我已在手机收到这条通知"){m.confirmInboxReceived(ticket.id)}.disabled(ticket.content==nil)
                            }.padding(.vertical,5)
                        }
                    }
                }
            }
            MonitorCard {
                VStack(alignment:.leading,spacing:12){
                    HStack{Text("通知队列").font(.headline);Spacer();Text("待处理 \(m.queuedCount) · 待核对 \(m.uncertainCount)").font(.caption).foregroundStyle(.secondary)}
                    if m.inbox.tickets.isEmpty{Text("扫描到未读邮件后，逐封处理结果会显示在这里。").font(.callout).foregroundStyle(.secondary)}
                    ForEach(Array(m.inbox.tickets.suffix(60).reversed()),id:\.id){ticket in
                        mailRow(ticket)
                    }
                    Text("服务受理后请核对手机。待核对表示发送中断或超时，可能已送达；修复 Token 后仅重试明确被拒绝的通知。").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                }
            }
            MonitorCard {
                VStack(alignment:.leading,spacing:16){
                    HStack{Text("本次运行记录").font(.headline);Spacer();Text("最新在上").font(.caption).foregroundStyle(.secondary)}
                    if m.log.isEmpty{Text("尚无操作记录。连接或预览后，结果会显示在这里。").foregroundStyle(.secondary).padding(.vertical,30)}
                    ForEach(Array(m.log.reversed().enumerated()),id:\.offset){_,line in
                        HStack(alignment:.top,spacing:12){Circle().fill(Color.blue.opacity(0.7)).frame(width:6,height:6).padding(.top,5);Text(line).font(.system(size:12)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).fixedSize(horizontal:false,vertical:true)}.padding(.vertical,5)
                        Divider()
                    }
                    Text("日志只记录运行状态；不会记录口令、Token 或确认码。").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
    private func settingIcon(_ symbol:String)->some View {Image(systemName:symbol).font(.system(size:20)).foregroundStyle(.blue).frame(width:42,height:42).background(Color.blue.opacity(0.09),in:RoundedRectangle(cornerRadius:11))}
    private func permissionRow(_ title:String,detail:String,allowed:Bool,action:@escaping ()->Void)->some View {
        HStack(spacing:12){Image(systemName:allowed ? "checkmark.circle.fill":"exclamationmark.circle.fill").font(.title3).foregroundStyle(allowed ? .green:.orange);VStack(alignment:.leading,spacing:4){Text(title).font(.system(size:13,weight:.medium));Text(detail).font(.caption).foregroundStyle(.secondary)};Spacer();Text(allowed ? "已开启":"待授权").font(.caption).foregroundStyle(.secondary);Button(allowed ? "查看设置":"开启权限",action:action).disabled(editingLocked)}
    }
    private var accountSheet:some View {
        VStack(alignment:.leading,spacing:18){
            HStack(spacing:12){AppMark(size:48);VStack(alignment:.leading,spacing:5){Text("连接系统账号").font(.title2.bold());Text("监控机 1 · 一键进入邮箱").font(.callout).foregroundStyle(.secondary)}}
            Text("账号和口令仅保存在本机钥匙串，用于指定系统登录。").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            VStack(alignment:.leading,spacing:7){Text("用户名").font(.caption);TextField("系统用户名",text:$m.systemUsername).textFieldStyle(.roundedBorder)}
            VStack(alignment:.leading,spacing:7){Text("口令").font(.caption);SecureField("系统口令",text:$m.systemPassword).textFieldStyle(.roundedBorder)}
            Text("首次使用需允许本软件控制 Safari。动态验证码或证书警告请在浏览器中本人处理。").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            if !m.systemError.isEmpty{Label(m.systemError,systemImage:"exclamationmark.circle").font(.callout).foregroundStyle(.red)}
            HStack{Button("取消"){m.showSystemSettings=false}.disabled(m.systemSaving);Spacer();if m.systemSaving{ProgressView().controlSize(.small)};Button(m.systemSaving ? "正在保存…":"保存并连接"){Task{await m.saveSystemCredentials()}}.buttonStyle(.borderedProminent).disabled(m.systemSaving || m.systemUsername.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || m.systemPassword.isEmpty)}
        }.padding(28).frame(width:440).interactiveDismissDisabled(m.systemSaving)
    }
    private func sample() async {
        guard let url=Bundle.main.url(forResource:"MailSample",withExtension:"png") else{m.note("示例截图未安装，请使用导入截图。");return}
        await m.importScreenshot(url)
    }
    private func persistOptions(){guard !m.running else{return};do{try m.save()}catch{m.note("设置保存失败："+error.localizedDescription)}}
}
