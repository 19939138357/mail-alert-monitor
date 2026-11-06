package cn.mailmonitor.handset;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Bundle;
import android.net.nsd.NsdManager;
import android.text.InputFilter;
import android.text.method.DigitsKeyListener;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputMethodManager;
import java.util.ArrayList;
import java.util.List;
import android.os.Handler;
import android.os.Looper;
import android.text.InputType;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.widget.*;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.IOException;
import java.util.concurrent.Callable;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.function.Consumer;
import javax.net.ssl.SSLException;

public final class MainActivity extends Activity {
    private int BG, CARD, INK, MUTED, BRAND, WASH, DARK, WHITE, AMBER, BORDER, ON_DARK, ON_PRIMARY;

    private void loadPalette() {
        BG = getColor(R.color.monitor_bg);
        CARD = getColor(R.color.monitor_card);
        INK = getColor(R.color.monitor_ink);
        MUTED = getColor(R.color.monitor_muted);
        BRAND = getColor(R.color.monitor_brand);
        WASH = getColor(R.color.monitor_wash);
        DARK = getColor(R.color.monitor_dark);
        WHITE = getColor(R.color.monitor_white);
        AMBER = getColor(R.color.monitor_amber);
        BORDER = getColor(R.color.monitor_border);
        ON_DARK = getColor(R.color.monitor_on_dark);
        ON_PRIMARY = getColor(R.color.monitor_on_primary);
    }
    private static final int FULL = ViewGroup.LayoutParams.MATCH_PARENT, FIT = ViewGroup.LayoutParams.WRAP_CONTENT;
    private enum Page { HOME, SCREEN, PAIR }
    private Page page;
    private final ExecutorService work = Executors.newSingleThreadExecutor();
    private final Handler ui = new Handler(Looper.getMainLooper());
    private PairingStore store;
    private Pairing pairing;
    private MonitorApi api;
    private JSONObject status;
    private boolean busy, foreground;
    private long generation;
    private String notice = "", candidate = "";
    private boolean problem;
    private MonitorApi.Frame frame;
    private LinearLayout root, body;
    private ScrollView scroll;
    private TextView feedback;
    private FoxmailView image;
    private EditText edit, shortCode, addressBox;
    private TextView nearby;
    private Button chooseComputer;
    private boolean linkMode, manual;
    private List<LocalComputer> computers = new ArrayList<>();
    private String chosenEndpoint, draftCode = "", draftAddress = "";
    private boolean discoveryAvailable = true;
    private MacDiscovery discovery;
    private final Runnable poll = () -> {
        if (page == Page.HOME && foreground && !busy) refreshStatus();
    };

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        loadPalette();
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE);
        getWindow().setStatusBarColor(BG);
        getWindow().setNavigationBarColor(BG);
        boolean night = (getResources().getConfiguration().uiMode & android.content.res.Configuration.UI_MODE_NIGHT_MASK)
                == android.content.res.Configuration.UI_MODE_NIGHT_YES;
        int barIcons = night ? 0 : View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR | View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR;
        getWindow().getDecorView().setSystemUiVisibility(barIcons | View.SYSTEM_UI_FLAG_LAYOUT_STABLE |
                View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION);
        discovery = new MacDiscovery(getSystemService(NsdManager.class), ui, (entries, available) -> {
            computers = entries;
            discoveryAvailable = available;
            if (chosenEndpoint != null && selectedComputer() == null) chosenEndpoint = null;
            showNearby();
        });
        store = new PairingStore(this);
        try {
            pairing = store.load();
            if (pairing != null) api = new MonitorApi(pairing);
        } catch (Exception e) { setNote("手机上保存的配对已不可用，请使用 Mac 上的新配对码。", true); }
        page = api == null ? Page.PAIR : Page.HOME;
        readIntent(getIntent());
        render();
    }

    private void readIntent(Intent intent) {
        if (intent == null || !Intent.ACTION_VIEW.equals(intent.getAction()) || intent.getData() == null) return;
        String link = intent.getDataString();
        setIntent(new Intent());
        try {
            Pairing.parse(link);
            candidate = link;
            linkMode = true;
            page = Page.PAIR;
            setNote("确认链接来自自己的 Mac，再点「配对并连接」。", false);
        } catch (Exception e) { setNote("收到的配对链接无效。", true); }
    }

    @Override protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        if (busy) { toast("请等当前操作结束后重新打开配对链接。"); return; }
        if (!Intent.ACTION_VIEW.equals(intent.getAction())) return;
        readIntent(intent);
        render();
    }
    @Override protected void onResume() {
        super.onResume();
        foreground = true;
        updateDiscovery();
        if (page == Page.HOME && !busy) refreshStatus();
        if (page == Page.SCREEN && !busy) refreshFrame();
    }
    @Override protected void onPause() {
        super.onPause();
        foreground = false;
        updateDiscovery();
        ui.removeCallbacks(poll);
        if (page == Page.SCREEN) clearFrame();
    }
    @Override protected void onDestroy() {
        discovery.stop();
        generation++;
        ui.removeCallbacksAndMessages(null);
        work.shutdownNow();
        super.onDestroy();
    }
    @Override public void onBackPressed() {
        if (busy && page == Page.PAIR) return;
        if (page != Page.HOME && api != null) { if (!busy) go(Page.HOME); return; }
        super.onBackPressed();
    }

    private void go(Page next) {
        if (busy) return;
        page = next;
        ui.removeCallbacks(poll);
        clearFrame();
        candidate = ""; draftCode = ""; draftAddress = "";
        linkMode = false; manual = false; chosenEndpoint = null;
        setNote("", false);
        render();
        if (next == Page.HOME) refreshStatus();
        if (next == Page.SCREEN) refreshFrame();
    }

    private void render() {
        root = column();
        root.setBackgroundColor(BG);
        root.setOnApplyWindowInsetsListener((v, insets) -> {
            v.setPadding(insets.getSystemWindowInsetLeft(), insets.getSystemWindowInsetTop(),
                    insets.getSystemWindowInsetRight(), insets.getSystemWindowInsetBottom());
            return insets;
        });
        setContentView(root);
        body = column();
        body.setPadding(dp(20), dp(14), dp(20), dp(24));
        if (page == Page.SCREEN) {
            root.addView(body,new LinearLayout.LayoutParams(FULL,FULL));
        } else {
            scroll = new ScrollView(this);
            scroll.setFillViewport(true);
            scroll.addView(body);
            root.addView(scroll, new LinearLayout.LayoutParams(FULL,FULL));
        }
        LinearLayout header = row();
        body.addView(header);
        TextView heading = label(page == Page.HOME ? "监控机 1" : page == Page.SCREEN ? "Foxmail 画面" : "配对电脑", 28, INK,true);
        header.addView(heading,new LinearLayout.LayoutParams(0,FIT,1));
        if (page == Page.HOME) header.addView(chip("配对设置", () -> go(Page.PAIR)));
        else if (api != null) header.addView(chip("返回监控台", () -> go(Page.HOME)));

        feedback = label(notice,14,problem ? AMBER : MUTED,false);
        feedback.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
        feedback.setPadding(0,dp(8),0,dp(5));
        feedback.setVisibility(notice.isEmpty() ? View.GONE : View.VISIBLE);
        body.addView(feedback);
        if (page == Page.HOME) home();
        else if (page == Page.SCREEN) screen();
        else pairPage();
        root.requestApplyInsets();
        updateDiscovery();
    }

    private void home() {
        LinearLayout hero = panel(DARK,20);
        LinearLayout heading = row();
        hero.addView(heading);
        heading.addView(label("监控状态",14,ON_DARK,false),new LinearLayout.LayoutParams(0,FIT,1));
        if (status != null && status.has("frames"))
            heading.addView(label(status.optInt("frames") + " 次扫描",14,ON_DARK,false));
        String state = status == null ? "正在读取" : status.optString("monitorState","状态未知");
        if (problem) state = status == null ? "连接不可用" : "连接中断，显示上次记录";
        top(hero,label(state,24,WHITE,true),8);
        if (status != null) {
            String last = status.optString("lastScan","");
            if (!last.isEmpty()) top(hero,label("最近扫描  " + last,14,ON_DARK,false),8);
        }
        LinearLayout stats = row();
        top(body, stats, 12);
        metric(stats,"待处理",count("pending"),false);
        metric(stats,"待核对",count("uncertain"),true);
        LinearLayout actions = row();
        top(body, actions, 12);
        boolean scanning = status != null && status.optBoolean("running") && !problem;
        Button connect = button("连接监控机 1", !scanning, this::requestConnect);
        Button mailbox = button("打开 Foxmail", scanning, () -> go(Page.SCREEN));
        actions.addView(scanning ? mailbox : connect, new LinearLayout.LayoutParams(0,FIT,1));
        LinearLayout.LayoutParams other = new LinearLayout.LayoutParams(0,FIT,1);
        other.leftMargin = dp(10);
        actions.addView(scanning ? connect : mailbox,other);
        LinearLayout queue = panel(CARD,16);
        LinearLayout title = row();
        queue.addView(title);
        title.addView(label("推送记录",20,INK,true),new LinearLayout.LayoutParams(0,FIT,1));
        title.addView(chip("刷新", () -> refreshStatus()));
        JSONArray items = status == null ? null : status.optJSONArray("tickets");
        if (items == null || items.length() == 0) {
            top(queue,label(items == null ? "连接电脑后显示每封邮件的结果。" : "电脑当前没有推送记录。",15,MUTED,false),10);
            return;
        }
        for (int i=0; i<Math.min(items.length(),60); i++) {
            JSONObject item = items.optJSONObject(i);
            if (item == null) continue;
            View line = new View(this);
            line.setBackgroundColor(BORDER);
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(FULL,dp(1));
            lp.topMargin=dp(12); lp.bottomMargin=dp(10); queue.addView(line,lp);
            queue.addView(label(item.optString("subject","主题未取得"),16,INK,true));
            LinearLayout meta = row();
            top(queue,meta,6);
            meta.addView(label(item.optString("time",""),14,MUTED,false),new LinearLayout.LayoutParams(0,FIT,1));
            TextView stateLabel = label(item.optString("state",""),13,INK,false);
            stateLabel.setPadding(dp(9),dp(4),dp(9),dp(4));
            stateLabel.setBackground(shape(WASH,8,0));
            meta.addView(stateLabel);
        }
    }

    private String count(String key) {
        return status != null && !status.isNull(key) ? String.valueOf(status.optInt(key)) : "—";
    }

    private void metric(LinearLayout parent,String name,String value,boolean spaced) {
        LinearLayout cell=column();
        cell.setBackground(shape(CARD,16,BORDER));
        cell.setPadding(dp(16),dp(12),dp(16),dp(12));
        cell.addView(label(name,14,MUTED,false)); cell.addView(label(value,25,INK,true));
        LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(0,FIT,1);
        if(spaced) lp.leftMargin=dp(10);
        parent.addView(cell,lp);
    }

    private void requestConnect() {
        if (busy) return;
        new AlertDialog.Builder(this).setTitle("连接监控机 1？")
                .setMessage("Mac 会通过当前监控程序处理连接请求。")
                .setNegativeButton("取消",null).setPositiveButton("连接",(d,w) -> execute(
                        api::connect, message -> {
                            toast(message);
                            setNote(message,false);
                            refreshStatus();
                        }, true)).show();
    }

    private void refreshStatus() {
        if (page != Page.HOME || busy || api == null || !foreground) return;
        execute(api::status, result -> {
            int y = scroll.getScrollY();
            status = result;
            setNote("",false);
            render();
            scroll.post(() -> { if(page == Page.HOME) scroll.scrollTo(0,y); });
        },false);
    }

    private void pairPage() {
        if (pairing != null) {
            LinearLayout connected=panel(CARD,16);
            connected.addView(label("已配对电脑",14,MUTED,false));
            top(connected,label(pairing.origin.getAuthority(),18,INK,true),4);
        }
        LinearLayout form = panel(CARD,18);
        if (linkMode) {
            form.addView(label("Mac 配对链接",18,INK,true));
            edit = new EditText(this);
            edit.setSingleLine(true);
            edit.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD | InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS);
            edit.setImportantForAutofill(View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS);
            edit.setSaveEnabled(false);
            edit.setTextSize(16); edit.setTextColor(INK);
            edit.setHint("粘贴配对链接"); edit.setHintTextColor(MUTED); edit.setContentDescription("Mac 配对链接");
            edit.setText(candidate);
            top(form,edit,12);
            top(form,button("配对并连接",true,this::attemptLink),14);
            top(body,chip("使用六位数字", () -> switchPairMode(false)),10);
        } else {
            form.addView(label("输入六位配对码",21,INK,true));
            top(form,label("在 Mac 的「手机配对」窗口查看数字。",15,MUTED,false),6);
            shortCode = new EditText(this);
            shortCode.setSingleLine(true);
            shortCode.setKeyListener(DigitsKeyListener.getInstance("0123456789"));
            shortCode.setRawInputType(InputType.TYPE_CLASS_NUMBER);
            shortCode.setFilters(new InputFilter[]{new InputFilter.LengthFilter(6)});
            shortCode.setImportantForAutofill(View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS);
            shortCode.setSaveEnabled(false);
            shortCode.setTextSize(29);
            shortCode.setTypeface(Typeface.MONOSPACE);
            shortCode.setTextColor(INK);
            shortCode.setHintTextColor(MUTED);
            shortCode.setLetterSpacing(0.20f);
            shortCode.setHint("· · · · · ·");
            shortCode.setContentDescription("六位数字配对码");
            shortCode.setText(draftCode);
            shortCode.setSelection(shortCode.length());
            shortCode.setImeOptions(EditorInfo.IME_ACTION_DONE);
            shortCode.setOnEditorActionListener((v,id,event) -> {
                if (id == EditorInfo.IME_ACTION_DONE) { attemptCode(); return true; }
                return false;
            });
            top(form,shortCode,12);
            nearby = label("",14,MUTED,false);
            top(form,nearby,8);
            chooseComputer = chip("选择电脑", this::chooseNearby);
            top(form,chooseComputer,6);
            if (manual) {
                addressBox = new EditText(this);
                addressBox.setSingleLine(true);
                addressBox.setKeyListener(DigitsKeyListener.getInstance("0123456789."));
                addressBox.setRawInputType(InputType.TYPE_CLASS_PHONE);
                addressBox.setFilters(new InputFilter[]{new InputFilter.LengthFilter(15)});
                addressBox.setHint("Mac 配对窗口显示的 IP 地址");
                addressBox.setContentDescription("Mac 的私人 IPv4 地址");
                addressBox.setText(draftAddress);
                top(form,addressBox,6);
            }
            top(form,button("配对并连接",true,this::attemptCode),14);
            LinearLayout options = row();
            top(form, options, 8);
            options.addView(chip(manual ? "改为自动查找" : "手动填地址",this::toggleAddress));
            if (!manual) {
                LinearLayout.LayoutParams space = new LinearLayout.LayoutParams(FIT,FIT);
                space.leftMargin = dp(8);
                options.addView(chip("重新查找", () -> {
                    discovery.stop(); computers.clear(); chosenEndpoint = null;
                    discoveryAvailable = true; showNearby();
                    if (foreground) discovery.start();
                }),space);
            }
            top(body,chip("使用二维码或配对链接", () -> switchPairMode(true)),10);
            showNearby();
        }
        if (pairing != null) top(body,chip("移除此电脑",this::forget),10);
    }

    private void rememberPairForm() {
        if (linkMode && edit != null) candidate = edit.getText().toString();
        if (!linkMode && shortCode != null) draftCode = shortCode.getText().toString();
        if (!linkMode && manual && addressBox != null) draftAddress = addressBox.getText().toString();
    }

    private void switchPairMode(boolean useLink) {
        rememberPairForm();
        linkMode = useLink;
        setNote("", false);
        render();
    }

    private void toggleAddress() {
        rememberPairForm();
        manual = !manual;
        setNote("", false);
        render();
        if (manual) addressBox.requestFocus();
    }

    private void updateDiscovery() {
        if (foreground && page == Page.PAIR && !linkMode && !manual) {
            discovery.start();
        } else {
            discovery.stop();
            computers = new ArrayList<>();
            chosenEndpoint = null;
            discoveryAvailable = true;
            showNearby();
        }
    }

    private LocalComputer selectedComputer() {
        for (LocalComputer computer : computers) {
            if (computer.endpoint().equals(chosenEndpoint)) return computer;
        }
        return chosenEndpoint == null && computers.size() == 1 ? computers.get(0) : null;
    }

    private void showNearby() {
        if (page != Page.PAIR || linkMode || nearby == null || chooseComputer == null) return;
        LocalComputer current = selectedComputer();
        String message;
        if (manual) message = "填写 Mac 显示的局域网或 VPN 地址。";
        else if (current != null) message = "电脑  " + current.name + " · " + current.address;
        else if (computers.size() > 1) message = "找到多台电脑，请选择要配对的 Mac。";
        else if (!discoveryAvailable) message = "自动发现当前不可用，请手动填写电脑地址。";
        else message = "正在查找同一 Wi-Fi 的 Mac。通过手机流量连接时，可手动填写 VPN 地址。";
        nearby.setText(message);
        chooseComputer.setVisibility(!manual && computers.size() > 1 ? View.VISIBLE : View.GONE);
    }

    private void chooseNearby() {
        List<LocalComputer> list = new ArrayList<>(computers);
        String[] choices = new String[list.size()];
        for (int i = 0; i < choices.length; i++) {
            LocalComputer entry = list.get(i);
            choices[i] = entry.name + " · " + entry.address;
        }
        new AlertDialog.Builder(this).setTitle("选择 Mac").setItems(choices, (d,i) -> {
            chosenEndpoint = list.get(i).endpoint();
            if (selectedComputer() == null) {
                chosenEndpoint = null;
                setNote("这台电脑已离线，请重新选择。", true);
            }
            showNearby();
        }).show();
    }

    private void attemptCode() {
        if (busy) return;
        String code = shortCode.getText().toString();
        if (!code.matches("[0-9]{6}")) { setNote("请完整输入六位数字，包括开头的 0。",true); return; }
        LocalComputer computer = selectedComputer();
        if (!manual && computer == null) {
            if (computers.size() > 1) chooseNearby();
            else setNote("还没找到电脑。请在 Mac 开启手机连接，或点「手动填地址」。", true);
            return;
        }
        String address = manual ? addressBox.getText().toString().trim() : computer.address;
        if (!LocalComputer.privateIPv4(address)) { setNote("请填写 Mac 配对窗口中的局域网或 VPN IPv4 地址。",true); return; }
        getSystemService(InputMethodManager.class).hideSoftInputFromWindow(shortCode.getWindowToken(),0);
        Runnable exchange = () -> startPair(() -> CodeExchange.pair(address, LocalComputer.PORT, code));
        if (pairing == null) exchange.run();
        else confirmReplace(address, exchange);
    }

    private void attemptLink() {
        if (busy) return;
        String raw = edit.getText().toString().trim();
        Pairing proposed;
        try { proposed = Pairing.parse(raw); }
        catch (Exception e) { setNote("配对链接无效，请从 Mac 重新复制完整链接。",true); return; }
        confirmReplace(proposed.origin.getAuthority(), () -> startPair(() -> raw));
    }

    private void confirmReplace(String address, Runnable action) {
        new AlertDialog.Builder(this).setTitle(pairing == null ? "连接这台电脑？" : "替换已配对电脑？")
                .setMessage(address + "\n请确认地址来自你自己的 Mac。")
                .setNegativeButton("取消", null).setPositiveButton("确认配对", (d,w) -> action.run()).show();
    }

    private void startPair(Callable<String> exchange) {
        setNote("正在验证配对…",false);
        final boolean numeric = !linkMode;
        execute(() -> {
            String raw = exchange.call();
            Pairing confirmed = Pairing.parse(raw);
            MonitorApi client = new MonitorApi(confirmed);
            // A code exchange authenticates both peers. Save it before a separate status read can fail.
            if (!numeric) client.status();
            store.save(raw);
            return confirmed;
        }, confirmed -> {
            pairing = confirmed;
            try { api = new MonitorApi(confirmed); }
            catch(Exception e) { setNote("手机无法建立加密连接。",true); return; }
            candidate = ""; draftCode = ""; draftAddress = ""; manual = false; linkMode = false;
            status = null;
            go(Page.HOME);
        },false);
    }
    private void forget() {
        if(busy) return;
        new AlertDialog.Builder(this).setTitle("移除手机上的配对？")
                .setMessage("再次连接时，需要在 Mac 上获取新的配对码。").setNegativeButton("取消",null)
                .setPositiveButton("移除",(d,w) -> execute(() -> { store.clear(); return true; }, ignored -> {
                    api=null; pairing=null; status=null; candidate=""; draftCode=""; draftAddress="";
                    manual=false; linkMode=false; chosenEndpoint=null; clearFrame();
                    setNote("已移除配对。", false); render();
                },false)).show();
    }

    private void screen() {
        LinearLayout tools=row();
        top(body,tools,8);
        tools.addView(label("双指缩放 · 轻点已读邮件",14,MUTED,false),
                new LinearLayout.LayoutParams(0,FIT,1));
        tools.addView(chip("刷新画面",this::refreshFrame));
        image=new FoxmailView(this,this::tap);
        LinearLayout.LayoutParams canvas=new LinearLayout.LayoutParams(FULL,0,1);
        canvas.topMargin=dp(10);body.addView(image,canvas);
        image.setFrame(frame);
    }

    private void clearFrame() {
        frame=null;
        if(image!=null)image.setFrame(null);
    }

    private void refreshFrame() {
        if(busy || !foreground || page!=Page.SCREEN || api==null)return;
        clearFrame();
        setNote("正在读取 Foxmail 画面…",false);
        execute(api::frame, result -> {
            if(foreground && page==Page.SCREEN){
                frame=result;image.setFrame(frame);setNote("",false);
            }
        },false);
    }

    private void tap(String id,float x,float y) {
        if(busy || !foreground || frame==null || !id.equals(frame.id))return;
        clearFrame();setNote("正在向电脑提交点按…",false);
        execute(() -> { api.tap(id,x,y);return true; }, ok -> {
            if(foreground && page==Page.SCREEN)refreshFrame();
        },true);
    }

    /** Requests run serially. Never repeat a connect/tap after an uncertain result. */
    private <T> void execute(Callable<T> call, Consumer<T> success, boolean mutation) {
        if(busy) return;
        busy=true;
        long token=generation;
        ui.removeCallbacks(poll);
        work.execute(() -> {
            T result=null; Exception failed=null;
            try { result=call.call(); } catch(Exception e){ failed=e; }
            final T value=result;
            final Exception error=failed;
            ui.post(() -> {
                if(token!=generation || isFinishing() || isDestroyed())return;
                busy=false;
                if(error==null)success.accept(value);
                else {
                    if(page==Page.SCREEN)clearFrame();
                    String message=explain(error);
                    if(mutation && (error instanceof java.net.SocketException ||
                            error instanceof java.net.SocketTimeoutException || error instanceof java.io.EOFException))
                        message="提交结果尚未确认。请先刷新电脑状态或画面，再决定是否重试。";
                    if(page==Page.HOME && status!=null)message+=" 显示的是上次读取的记录。";
                    setNote(message,true);
                    if(page==Page.HOME)render();
                }
                if(!busy && foreground && page==Page.HOME) ui.postDelayed(poll,12000);
            });
        });
    }

    private String explain(Exception e) {
        if(e instanceof SSLException)return "电脑证书验证失败。请检查手机时间，并核对电脑上的配对链接。";
        if(e instanceof java.net.SocketTimeoutException || e instanceof java.net.SocketException ||
                e instanceof java.net.UnknownHostException)
            return "连不上 Mac。请确认电脑端已启动，手机能访问配对地址。";
        if(e instanceof IOException && e.getMessage()!=null && e.getMessage().matches(".*[\u4e00-\u9fff].*"))
            return e.getMessage();
        return "请求没有完成，请核对电脑端状态后刷新。";
    }

    private void setNote(String value,boolean error){
        notice=value;problem=error;
        if(feedback!=null) {
            feedback.setText(value);feedback.setTextColor(error?AMBER:MUTED);
            feedback.setVisibility(value.isEmpty()?View.GONE:View.VISIBLE);
        }
    }

    private LinearLayout column(){LinearLayout v=new LinearLayout(this);v.setOrientation(LinearLayout.VERTICAL);return v;}
    private LinearLayout row(){LinearLayout v=new LinearLayout(this);v.setGravity(Gravity.CENTER_VERTICAL);return v;}
    private int dp(float value){return Math.round(value*getResources().getDisplayMetrics().density);}
    private GradientDrawable shape(int color,int r,int stroke){
        GradientDrawable d=new GradientDrawable();d.setColor(color);d.setCornerRadius(dp(r));
        if(stroke!=0)d.setStroke(dp(1),stroke);return d;
    }
    private TextView label(String value,int size,int color,boolean bold){
        TextView t=new TextView(this);t.setText(value);t.setTextSize(size);t.setTextColor(color);
        t.setIncludeFontPadding(false);t.setLineSpacing(dp(3),1);
        if(bold)t.setTypeface(Typeface.create("sans-serif-medium",Typeface.NORMAL));
        return t;
    }
    private android.graphics.drawable.Drawable touchSurface(int fill, int radius, int stroke) {
        return new android.graphics.drawable.RippleDrawable(
                android.content.res.ColorStateList.valueOf((INK & 0x00ffffff) | 0x29000000),
                shape(fill,radius,stroke),null);
    }
    private Button button(String name,boolean primary,Runnable action){
        Button b=new Button(this);
        b.setText(name);b.setTextSize(16);b.setAllCaps(false);
        b.setTextColor(primary?ON_PRIMARY:BRAND);b.setBackground(touchSurface(primary?BRAND:WASH,12,0));
        b.setMinHeight(dp(48)); b.setMinimumHeight(dp(48));b.setPadding(dp(6),dp(9),dp(6),dp(9));
        b.setOnClickListener(v -> { if(!busy)action.run(); });
        return b;
    }
    private Button chip(String name,Runnable action){
        Button b=button(name,false,action);b.setTextSize(14);b.setBackground(touchSurface(BG,12,BORDER));
        b.setPadding(dp(12),dp(6),dp(12),dp(6));return b;
    }
    private LinearLayout panel(int color,int pad){
        LinearLayout c=column();c.setPadding(dp(pad),dp(pad),dp(pad),dp(pad));
        c.setBackground(shape(color,18,color==CARD?BORDER:0));top(body,c,14);return c;
    }
    private void top(LinearLayout parent,View child,int margin){
        LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(FULL,FIT);lp.topMargin=dp(margin);
        parent.addView(child,lp);
    }
    private void toast(String message){Toast.makeText(this,message,Toast.LENGTH_SHORT).show();}
}
